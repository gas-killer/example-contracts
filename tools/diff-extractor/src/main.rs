//! gk-diff-extractor — produce the Gas Killer diff `(StateUpdateType[], bytes[])` for a tx or a
//! simulated call. The op universe matches the production analyzer exactly: STORE, CALL, LOG0-4
//! (CREATE/CREATE2/SELFDESTRUCT are not representable and are surfaced as skipped, same as the analyzer).
//!
//!   gk-diff-extractor <TX_HASH>                          — trace a mined tx (debug_traceTransaction)
//!   gk-diff-extractor --call     <FROM> <TO> <CD> [BLK]  — structLogs path (debug_traceCall) — O(steps)
//!   gk-diff-extractor --prestate <FROM> <TO> <CD> [BLK]  — prestate fast-path; REFUSES if not eligible
//!   gk-diff-extractor --auto     <FROM> <TO> <CD> [BLK]  — HYBRID (recommended): prestate when provably
//!                                                          safe, else structLogs fallback
//!
//! ## Why a hybrid
//!
//! The structLogs path ("the other version", `compute_state_updates`) builds a *replay script*:
//! STORE/LOG/CALL at "target depth" (the consumer), made transparent through DELEGATECALL/CALLCODE; a
//! regular CALL becomes a CALL op whose internals re-execute on replay; cross-contract storage is
//! reproduced by that replay, not extracted. It is fully general but O(execution steps), so it times out
//! on heavy-compute functions (e.g. OnchainLife.step = 16.8M gas).
//!
//! The prestate path is O(changed slots): prestateTracer(diffMode) gives the consumer's NET storage diff
//! (→ STORE) and callTracer(withLog) gives the events (→ LOG). It is far cheaper, but a NET diff cannot
//! separate the consumer's top-level writes from writes induced by a sub-CALL, so it is only SOUND when
//! the consumer makes no state-affecting regular CALL, no CREATE/SELFDESTRUCT, and touches only its own
//! storage. `--auto` checks exactly that (cheaply, from the two tracer outputs) and dispatches: the fast
//! path for the heavy self-compute sweet spot, the proven structLogs path for everything else. It never
//! emits an unsound diff.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use alloy_eips::BlockId;
use alloy_primitives::{Address, B256, Bytes, FixedBytes, TxKind};
use alloy_provider::ext::DebugApi;
use alloy_provider::{Provider, ProviderBuilder};
use alloy_rpc_types_eth::{TransactionInput, TransactionRequest};
use alloy_rpc_types_trace::geth::{
    CallConfig, CallFrame, CallLogFrame, DiffMode, GethDebugTracingCallOptions, GethDebugTracingOptions,
    GethTrace, PreStateConfig, PreStateFrame,
};
use anyhow::bail;
use gas_analyzer_rs::core::get_trace_from_call;
use gas_analyzer_rs::{compute_state_updates, encode_state_updates_to_abi, get_tx_trace, IStateUpdateTypes, StateUpdate};

/// StateTracker's ERC-7201 counter slot — dropped from the diff (verifyAndUpdate's own trackState
/// manages it), so the diff is portable across contracts in differing transition state. Overridable via
/// GK_TRACKER_SLOT if a future SDK changes the ERC-7201 namespace.
const STATE_TRACKER_SLOT: &str = "0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf";

/// Result of the eligibility check: either the prestate fast-path is sound, or we must fall back.
enum Eligibility {
    Eligible,
    Fallback(String),
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let rpc = std::env::var("RPC_URL").unwrap_or_else(|_| "http://localhost:8545".to_string());
    let provider = ProviderBuilder::new().connect_http(rpc.parse()?);

    let updates: Vec<StateUpdate> = match args.get(1).map(String::as_str) {
        Some("--auto") => {
            let (from, to, data, block) = parse_call_args(&args)?;
            let tx = make_tx(from, to, data);
            let diff = prestate_diff(&provider, tx.clone(), block).await?;
            let frame = call_frame(&provider, tx.clone(), block).await?;
            match classify(&frame, &diff, to) {
                Eligibility::Eligible => {
                    eprintln!("mode: prestate fast-path (eligible — pure consumer-storage compute)");
                    build_updates_from_prestate(to, &diff, &frame)
                }
                Eligibility::Fallback(reason) => {
                    eprintln!("mode: structLogs fallback — {reason}");
                    let trace = get_trace_from_call(&provider, tx, block).await?;
                    strip_and_compute(trace)?
                }
            }
        }
        Some("--prestate") => {
            let (from, to, data, block) = parse_call_args(&args)?;
            let tx = make_tx(from, to, data);
            let diff = prestate_diff(&provider, tx.clone(), block).await?;
            let frame = call_frame(&provider, tx, block).await?;
            // Force prestate, but REFUSE rather than emit an unsound diff when it can't represent the call.
            if let Eligibility::Fallback(reason) = classify(&frame, &diff, to) {
                bail!("--prestate cannot soundly represent this call: {reason}. Use --auto or --call.");
            }
            eprintln!("mode: prestate (eligible)");
            build_updates_from_prestate(to, &diff, &frame)
        }
        Some("--call") => {
            let (from, to, data, block) = parse_call_args(&args)?;
            let trace = get_trace_from_call(&provider, make_tx(from, to, data), block).await?;
            strip_and_compute(trace)?
        }
        _ => {
            let tx_hash: FixedBytes<32> = args
                .get(1)
                .expect("usage: <tx_hash> | --call|--prestate|--auto <from> <to> <calldata> [block]")
                .parse()?;
            let trace = get_tx_trace(&provider, tx_hash).await?;
            strip_and_compute(trace)?
        }
    };

    // Shared tail: drop the SDK tracker slot, print the decoded ops (stderr), emit the hex (stdout).
    let tracker: FixedBytes<32> =
        std::env::var("GK_TRACKER_SLOT").unwrap_or_else(|_| STATE_TRACKER_SLOT.to_string()).parse()?;
    let updates = drop_tracker_slot(updates, tracker);

    eprintln!("extracted {} state updates", updates.len());
    for u in &updates {
        eprintln!("  {u:?}");
    }
    println!("0x{}", hex::encode(encode_state_updates_to_abi(&updates).as_ref()));
    Ok(())
}

// ---------------------------------------------------------------------------------------------------
// Tracer fetching
// ---------------------------------------------------------------------------------------------------

/// prestateTracer in diffMode → pre/post storage per touched account (O(changed slots)).
async fn prestate_diff<P: Provider + DebugApi>(
    provider: &P,
    tx: TransactionRequest,
    block: BlockId,
) -> anyhow::Result<DiffMode> {
    let opts = GethDebugTracingCallOptions {
        tracing_options: GethDebugTracingOptions::prestate_tracer(PreStateConfig {
            diff_mode: Some(true),
            disable_code: Some(true),
            ..Default::default()
        }),
        ..Default::default()
    };
    match provider.debug_trace_call(tx, block, opts).await? {
        GethTrace::PreStateTracer(PreStateFrame::Diff(d)) => Ok(d),
        other => bail!("expected prestate diff frame, got {other:?}"),
    }
}

/// callTracer with logs → the call tree + events (O(calls+logs)).
async fn call_frame<P: Provider + DebugApi>(
    provider: &P,
    tx: TransactionRequest,
    block: BlockId,
) -> anyhow::Result<CallFrame> {
    let opts = GethDebugTracingCallOptions {
        tracing_options: GethDebugTracingOptions::call_tracer(CallConfig::default().with_log()),
        ..Default::default()
    };
    match provider.debug_trace_call(tx, block, opts).await? {
        GethTrace::CallTracer(f) => Ok(f),
        other => bail!("expected call frame, got {other:?}"),
    }
}

/// `--call`/`--prestate`/`--auto` argument layout: [mode, from, to, calldata, (block)].
fn parse_call_args(args: &[String]) -> anyhow::Result<(Address, Address, Bytes, BlockId)> {
    let from: Address = args.get(2).expect("usage: <mode> <from> <to> <calldata> [block]").parse()?;
    let to: Address = args.get(3).expect("missing <to>").parse()?;
    let data = Bytes::from(hex::decode(args.get(4).expect("missing <calldata>").trim_start_matches("0x"))?);
    let block = match args.get(5) {
        Some(b) => BlockId::number(b.parse::<u64>()?),
        None => BlockId::latest(),
    };
    Ok((from, to, data, block))
}

fn make_tx(from: Address, to: Address, data: Bytes) -> TransactionRequest {
    let mut tx = TransactionRequest::default();
    tx.from = Some(from);
    tx.to = Some(TxKind::Call(to));
    tx.input = TransactionInput::new(data);
    tx
}

/// struct-log path: normalize anvil's 0x-prefixed memory, run the analyzer's extractor, warn on any
/// opcode it had to skip (CREATE/CREATE2/SELFDESTRUCT — not representable as a StateUpdate).
fn strip_and_compute(mut trace: alloy_rpc_types_trace::geth::DefaultFrame) -> anyhow::Result<Vec<StateUpdate>> {
    for log in trace.struct_logs.iter_mut() {
        if let Some(memory) = log.memory.as_mut() {
            for word in memory.iter_mut() {
                if let Some(stripped) = word.strip_prefix("0x") {
                    *word = stripped.to_string();
                }
            }
        }
    }
    let (updates, skipped, _call_gas) = compute_state_updates(trace)?;
    warn_skipped(&skipped);
    Ok(updates)
}

fn warn_skipped(skipped: &HashSet<String>) {
    if !skipped.is_empty() {
        eprintln!("warning: skipped non-representable opcodes (no StateUpdate variant exists): {skipped:?}");
    }
}

// ---------------------------------------------------------------------------------------------------
// Eligibility — can the prestate fast-path SOUNDLY reconstruct the diff?
// ---------------------------------------------------------------------------------------------------

/// Mirror `compute_state_updates`'s model to decide whether the cheap prestate path is sound. The
/// consumer's frame is "target depth"; DELEGATECALL/CALLCODE are transparent (same storage context).
/// We must fall back to structLogs if the consumer:
///   * touches a non-consumer account's storage (only CALL replay can reproduce that), or
///   * makes a regular CALL at target depth (becomes a CALL op whose internals re-execute — a net
///     storage diff cannot separate those from top-level writes), or
///   * does CREATE/CREATE2/SELFDESTRUCT (not representable; the analyzer skips them too).
/// STATICCALL is read-only and ignored.
fn classify(frame: &CallFrame, diff: &DiffMode, consumer: Address) -> Eligibility {
    let mut accounts: BTreeSet<Address> = BTreeSet::new();
    accounts.extend(diff.pre.keys().copied());
    accounts.extend(diff.post.keys().copied());
    for a in accounts {
        if a != consumer && account_storage_changed(diff, a) {
            return Eligibility::Fallback(format!("non-consumer account {a} changed storage (needs CALL replay)"));
        }
    }
    if let Some(reason) = scan_target_depth(frame) {
        return Eligibility::Fallback(reason);
    }
    Eligibility::Eligible
}

/// Walk the target-depth context (root + DELEGATECALL/CALLCODE descendants) for a frame type that
/// forces the structLogs fallback. Returns the first disqualifying reason, if any.
fn scan_target_depth(frame: &CallFrame) -> Option<String> {
    for c in &frame.calls {
        match c.typ.as_str() {
            "CALL" => return Some(format!("regular CALL to {:?} at target depth (needs CALL replay)", c.to)),
            "CREATE" | "CREATE2" => {
                return Some(format!("{} at target depth (contract creation is not representable)", c.typ))
            }
            "SELFDESTRUCT" => return Some("SELFDESTRUCT at target depth (not representable)".into()),
            "DELEGATECALL" | "CALLCODE" => {
                if let Some(r) = scan_target_depth(c) {
                    return Some(r);
                }
            }
            "STATICCALL" => {} // read-only — cannot change state, safely ignored
            other => return Some(format!("unhandled call frame type {other:?}")),
        }
    }
    None
}

/// True iff `addr`'s storage actually changed between pre and post (ignores balance/nonce-only deltas).
fn account_storage_changed(diff: &DiffMode, addr: Address) -> bool {
    let empty = BTreeMap::new();
    let pre = diff.pre.get(&addr).map(|a| &a.storage).unwrap_or(&empty);
    let post = diff.post.get(&addr).map(|a| &a.storage).unwrap_or(&empty);
    let mut keys: BTreeSet<B256> = BTreeSet::new();
    keys.extend(pre.keys().copied());
    keys.extend(post.keys().copied());
    keys.into_iter()
        .any(|k| pre.get(&k).copied().unwrap_or(B256::ZERO) != post.get(&k).copied().unwrap_or(B256::ZERO))
}

// ---------------------------------------------------------------------------------------------------
// Prestate assembly (only reached when eligible)
// ---------------------------------------------------------------------------------------------------

/// Build `Vec<StateUpdate>` from a prestate diff (consumer storage → STORE) + a call frame (events →
/// LOGn). Storage is emitted slot-sorted (deterministic); logs in execution order.
fn build_updates_from_prestate(consumer: Address, diff: &DiffMode, frame: &CallFrame) -> Vec<StateUpdate> {
    let mut updates = Vec::new();
    let empty = BTreeMap::new();
    let pre = diff.pre.get(&consumer).map(|a| &a.storage).unwrap_or(&empty);
    let post = diff.post.get(&consumer).map(|a| &a.storage).unwrap_or(&empty);

    // Union of touched slots; emit a STORE wherever the value actually changed (covers zeroing).
    let mut slots: BTreeSet<B256> = BTreeSet::new();
    slots.extend(pre.keys().copied());
    slots.extend(post.keys().copied());
    for slot in slots {
        let old = pre.get(&slot).copied().unwrap_or(B256::ZERO);
        let new = post.get(&slot).copied().unwrap_or(B256::ZERO);
        if old != new {
            updates.push(StateUpdate::Store(IStateUpdateTypes::Store { slot, value: new }));
        }
    }

    for lg in ordered_target_depth_logs(frame) {
        updates.push(log_to_update(lg));
    }
    updates
}

/// Collect the logs in the consumer's storage context — the root frame plus DELEGATECALL/CALLCODE
/// descendants (transparent), EXCLUDING regular CALL (those re-emit on replay) and STATICCALL
/// (read-only) — in TRUE EMISSION ORDER. Ordering uses each log's `position` (= how many of the frame's
/// sub-calls had run when it was emitted) to interleave a frame's own logs with its delegatecall
/// children, then, if every log also carries a global `index`, that authoritative order is applied on
/// top. This reproduces the structLogs path's execution order even when the consumer emits a log,
/// delegatecalls a library that emits a log, then emits another log.
fn ordered_target_depth_logs(frame: &CallFrame) -> Vec<&CallLogFrame> {
    let mut logs: Vec<&CallLogFrame> = Vec::new();
    collect_target_depth_logs(frame, &mut logs);
    if logs.len() > 1 && logs.iter().all(|l| l.index.is_some()) {
        logs.sort_by_key(|l| l.index.unwrap()); // global truth; stable, so it never worsens position order
    }
    logs
}

/// Interleave `frame`'s own logs with its sub-calls by `position`: a log with position `p` was emitted
/// after `p` sub-calls, so it belongs immediately before sub-call `p`. We recurse only into transparent
/// DELEGATECALL/CALLCODE children (their logs hit the consumer's context); STATICCALL/regular-CALL
/// children are excluded but still advance the position counter.
fn collect_target_depth_logs<'a>(frame: &'a CallFrame, out: &mut Vec<&'a CallLogFrame>) {
    let mut logs: Vec<&CallLogFrame> = frame.logs.iter().collect();
    logs.sort_by_key(|l| l.position.unwrap_or(0)); // stable → preserves vector order within a position
    let mut li = 0;
    for (call_idx, c) in frame.calls.iter().enumerate() {
        while li < logs.len() && (logs[li].position.unwrap_or(0) as usize) <= call_idx {
            out.push(logs[li]);
            li += 1;
        }
        if c.typ == "DELEGATECALL" || c.typ == "CALLCODE" {
            collect_target_depth_logs(c, out);
        }
    }
    while li < logs.len() {
        out.push(logs[li]);
        li += 1;
    }
}

/// Map a call-frame log to the matching LOG0..LOG4 StateUpdate by topic count.
fn log_to_update(log: &CallLogFrame) -> StateUpdate {
    let topics = log.topics.clone().unwrap_or_default();
    let data = log.data.clone().unwrap_or_default();
    match topics.len() {
        0 => StateUpdate::Log0(IStateUpdateTypes::Log0 { data }),
        1 => StateUpdate::Log1(IStateUpdateTypes::Log1 { data, topic1: topics[0] }),
        2 => StateUpdate::Log2(IStateUpdateTypes::Log2 { data, topic1: topics[0], topic2: topics[1] }),
        3 => StateUpdate::Log3(IStateUpdateTypes::Log3 {
            data,
            topic1: topics[0],
            topic2: topics[1],
            topic3: topics[2],
        }),
        _ => StateUpdate::Log4(IStateUpdateTypes::Log4 {
            data,
            topic1: topics[0],
            topic2: topics[1],
            topic3: topics[2],
            topic4: topics[3],
        }),
    }
}

/// Drop the SDK's ERC-7201 tracker STORE — `verifyAndUpdate`'s own `trackState` manages that counter,
/// so leaving it in the diff would double-write it (and make the diff non-portable across contracts in
/// differing transition state).
fn drop_tracker_slot(updates: Vec<StateUpdate>, tracker: FixedBytes<32>) -> Vec<StateUpdate> {
    updates.into_iter().filter(|u| !matches!(u, StateUpdate::Store(s) if s.slot == tracker)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_rpc_types_trace::geth::AccountState;

    fn b256(byte: u8) -> B256 {
        B256::repeat_byte(byte)
    }

    fn acct(storage: &[(B256, B256)]) -> AccountState {
        AccountState { storage: storage.iter().copied().collect(), ..Default::default() }
    }

    fn frame(typ: &str, logs: Vec<CallLogFrame>, calls: Vec<CallFrame>) -> CallFrame {
        CallFrame { typ: typ.to_string(), logs, calls, ..Default::default() }
    }

    fn log(topics: &[B256], data: u8) -> CallLogFrame {
        CallLogFrame {
            topics: Some(topics.to_vec()),
            data: Some(Bytes::from(vec![data])),
            ..Default::default()
        }
    }

    fn log_idx(topics: &[B256], data: u8, index: u64) -> CallLogFrame {
        CallLogFrame { index: Some(index), ..log(topics, data) }
    }

    fn log_pos(topics: &[B256], data: u8, position: u64) -> CallLogFrame {
        CallLogFrame { position: Some(position), ..log(topics, data) }
    }

    fn stores(updates: &[StateUpdate]) -> Vec<(B256, B256)> {
        updates
            .iter()
            .filter_map(|u| match u {
                StateUpdate::Store(s) => Some((s.slot, s.value)),
                _ => None,
            })
            .collect()
    }

    fn log1_topics(updates: &[StateUpdate]) -> Vec<B256> {
        updates
            .iter()
            .filter_map(|u| match u {
                StateUpdate::Log1(l) => Some(l.topic1),
                _ => None,
            })
            .collect()
    }

    fn is_eligible(e: Eligibility) -> bool {
        matches!(e, Eligibility::Eligible)
    }

    const CONSUMER: Address = Address::repeat_byte(0xAA);

    // ---- build_updates_from_prestate: storage diffing ------------------------------------------

    #[test]
    fn store_emitted_for_changed_slot() {
        let mut diff = DiffMode::default();
        diff.pre.insert(CONSUMER, acct(&[(b256(1), b256(0x11))]));
        diff.post.insert(CONSUMER, acct(&[(b256(1), b256(0x22))]));
        let u = build_updates_from_prestate(CONSUMER, &diff, &frame("CALL", vec![], vec![]));
        assert_eq!(stores(&u), vec![(b256(1), b256(0x22))]);
    }

    #[test]
    fn zeroing_emits_store_to_zero_whether_post_holds_zero_or_omits_key() {
        let mut a = DiffMode::default();
        a.pre.insert(CONSUMER, acct(&[(b256(7), b256(0x99))]));
        a.post.insert(CONSUMER, acct(&[(b256(7), B256::ZERO)]));
        let mut b = DiffMode::default();
        b.pre.insert(CONSUMER, acct(&[(b256(7), b256(0x99))]));
        b.post.insert(CONSUMER, acct(&[]));
        for diff in [a, b] {
            let u = build_updates_from_prestate(CONSUMER, &diff, &frame("CALL", vec![], vec![]));
            assert_eq!(stores(&u), vec![(b256(7), B256::ZERO)], "zeroing must emit STORE(slot, 0)");
        }
    }

    #[test]
    fn net_zero_slot_is_omitted() {
        let mut diff = DiffMode::default();
        diff.pre.insert(CONSUMER, acct(&[(b256(3), b256(0x55))]));
        diff.post.insert(CONSUMER, acct(&[(b256(3), b256(0x55))]));
        let u = build_updates_from_prestate(CONSUMER, &diff, &frame("CALL", vec![], vec![]));
        assert!(stores(&u).is_empty(), "pre == post must produce no STORE");
    }

    #[test]
    fn empty_diff_and_empty_frame_produce_empty_updates() {
        let u = build_updates_from_prestate(CONSUMER, &DiffMode::default(), &frame("CALL", vec![], vec![]));
        assert!(u.is_empty());
    }

    #[test]
    fn only_consumer_storage_becomes_stores() {
        let other = Address::repeat_byte(0xBB);
        let mut diff = DiffMode::default();
        diff.post.insert(CONSUMER, acct(&[(b256(1), b256(0x11))]));
        diff.post.insert(other, acct(&[(b256(2), b256(0x22))]));
        let u = build_updates_from_prestate(CONSUMER, &diff, &frame("CALL", vec![], vec![]));
        assert_eq!(stores(&u), vec![(b256(1), b256(0x11))], "non-consumer storage must be excluded");
    }

    // ---- log collection: target-depth context, ordering ---------------------------------------

    #[test]
    fn topic_count_maps_to_log0_through_log4() {
        let f = frame(
            "CALL",
            vec![
                log(&[], 0),
                log(&[b256(1)], 1),
                log(&[b256(1), b256(2)], 2),
                log(&[b256(1), b256(2), b256(3)], 3),
                log(&[b256(1), b256(2), b256(3), b256(4)], 4),
            ],
            vec![],
        );
        let u: Vec<StateUpdate> = ordered_target_depth_logs(&f).into_iter().map(log_to_update).collect();
        assert!(matches!(u[0], StateUpdate::Log0(_)));
        assert!(matches!(u[1], StateUpdate::Log1(_)));
        assert!(matches!(u[2], StateUpdate::Log2(_)));
        assert!(matches!(u[3], StateUpdate::Log3(_)));
        assert!(matches!(u[4], StateUpdate::Log4(_)));
        if let StateUpdate::Log3(l) = &u[3] {
            assert_eq!((l.topic1, l.topic2, l.topic3), (b256(1), b256(2), b256(3)));
        } else {
            panic!("expected Log3");
        }
    }

    #[test]
    fn delegatecall_logs_included_staticcall_and_regular_call_excluded() {
        let f = frame(
            "CALL",
            vec![log(&[b256(0xA1)], 1)], // consumer's own log → included
            vec![
                frame("DELEGATECALL", vec![log(&[b256(0xDE)], 1)], vec![]), // transparent → included
                frame("STATICCALL", vec![log(&[b256(0x5A)], 1)], vec![]),   // read-only → excluded
                frame("CALL", vec![log(&[b256(0xC1)], 1)], vec![]),         // re-executes on replay → excluded
            ],
        );
        let u: Vec<StateUpdate> = ordered_target_depth_logs(&f).into_iter().map(log_to_update).collect();
        assert_eq!(
            log1_topics(&u),
            vec![b256(0xA1), b256(0xDE)],
            "only consumer + delegatecall logs belong in the diff"
        );
    }

    #[test]
    fn logs_sorted_by_global_index() {
        // Parent emits AFTER its delegatecall child (index 3 vs 1) — must be reordered by index.
        let f = frame(
            "CALL",
            vec![log_idx(&[b256(0x03)], 1, 3)],
            vec![frame("DELEGATECALL", vec![log_idx(&[b256(0x01)], 1, 1)], vec![])],
        );
        let u: Vec<StateUpdate> = ordered_target_depth_logs(&f).into_iter().map(log_to_update).collect();
        assert_eq!(log1_topics(&u), vec![b256(0x01), b256(0x03)], "logs must be in global execution order");
    }

    #[test]
    fn logs_interleaved_by_position_without_global_index() {
        // The audit's case: consumer emits A, DELEGATECALLs a lib that emits C, then emits B — with NO
        // global `index` (only `position`). True order is [A, C, B]; naive DFS would give [A, B, C].
        // A is at position 0 (before the sub-call), B at position 1 (after it); C lives in the child.
        let f = frame(
            "CALL",
            vec![log_pos(&[b256(0xAA)], 1, 0), log_pos(&[b256(0xBB)], 1, 1)],
            vec![frame("DELEGATECALL", vec![log(&[b256(0xCC)], 1)], vec![])],
        );
        let u: Vec<StateUpdate> = ordered_target_depth_logs(&f).into_iter().map(log_to_update).collect();
        assert_eq!(
            log1_topics(&u),
            vec![b256(0xAA), b256(0xCC), b256(0xBB)],
            "position must interleave delegatecall logs in emission order even without a global index"
        );
    }

    // ---- classify: prestate-eligibility -------------------------------------------------------

    fn diff_consumer_only() -> DiffMode {
        let mut d = DiffMode::default();
        d.pre.insert(CONSUMER, acct(&[(b256(1), b256(0x00))]));
        d.post.insert(CONSUMER, acct(&[(b256(1), b256(0x01))]));
        d
    }

    #[test]
    fn eligible_pure_self_compute_with_staticcall_and_delegatecall() {
        let f = frame(
            "CALL",
            vec![log(&[b256(1)], 1)],
            vec![
                frame("STATICCALL", vec![], vec![]),
                frame("DELEGATECALL", vec![log(&[b256(2)], 1)], vec![]),
            ],
        );
        assert!(is_eligible(classify(&f, &diff_consumer_only(), CONSUMER)));
    }

    #[test]
    fn fallback_on_regular_call() {
        let f = frame("CALL", vec![], vec![frame("CALL", vec![], vec![])]);
        assert!(!is_eligible(classify(&f, &diff_consumer_only(), CONSUMER)));
    }

    #[test]
    fn fallback_on_create() {
        let f = frame("CALL", vec![], vec![frame("CREATE", vec![], vec![])]);
        assert!(!is_eligible(classify(&f, &diff_consumer_only(), CONSUMER)));
    }

    #[test]
    fn fallback_on_regular_call_nested_in_delegatecall() {
        // A delegatecall library that itself makes a regular CALL is still at target depth.
        let f = frame(
            "CALL",
            vec![],
            vec![frame("DELEGATECALL", vec![], vec![frame("CALL", vec![], vec![])])],
        );
        assert!(!is_eligible(classify(&f, &diff_consumer_only(), CONSUMER)));
    }

    #[test]
    fn fallback_on_cross_contract_storage() {
        let other = Address::repeat_byte(0xBB);
        let mut diff = diff_consumer_only();
        diff.pre.insert(other, acct(&[(b256(9), b256(0x00))]));
        diff.post.insert(other, acct(&[(b256(9), b256(0x07))]));
        let f = frame("CALL", vec![], vec![]); // call tree clean, but prestate shows a second account changed
        assert!(!is_eligible(classify(&f, &diff, CONSUMER)));
    }

    #[test]
    fn balance_only_change_of_other_account_does_not_force_fallback() {
        // A plain ETH transfer touches the recipient's balance but not its storage — still eligible.
        let other = Address::repeat_byte(0xBB);
        let mut diff = diff_consumer_only();
        diff.post.insert(other, AccountState { ..Default::default() }); // no storage delta
        let f = frame("CALL", vec![], vec![]);
        assert!(is_eligible(classify(&f, &diff, CONSUMER)));
    }

    // ---- drop_tracker_slot --------------------------------------------------------------------

    #[test]
    fn tracker_store_is_dropped_others_kept() {
        let tracker: FixedBytes<32> = STATE_TRACKER_SLOT.parse().unwrap();
        let updates = vec![
            StateUpdate::Store(IStateUpdateTypes::Store { slot: tracker, value: b256(0x99) }),
            StateUpdate::Store(IStateUpdateTypes::Store { slot: b256(1), value: b256(0x11) }),
            StateUpdate::Log1(IStateUpdateTypes::Log1 { data: Bytes::new(), topic1: b256(2) }),
        ];
        let kept = drop_tracker_slot(updates, tracker);
        assert_eq!(stores(&kept), vec![(b256(1), b256(0x11))], "only the tracker STORE is removed");
        assert_eq!(kept.len(), 2, "non-tracker ops are preserved");
    }
}
