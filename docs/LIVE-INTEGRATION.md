# Live integration — driving a state transition via the hosted Gas Killer aggregator

A hosted aggregator runs the whole off-chain pipeline for a deployed consumer, so you don't build or run
operators yourself: it simulates the call, computes the storage diff, and has the operator quorum sign it.

> **This document was rewritten after two breaking upstream changes, both re-verified against the
> deployed testnet.** Older instructions (a shared `INGRESS_PASSWORD`, and an aggregator that broadcasts
> `verifyAndUpdate` for you) are **no longer correct**. See [What changed](#what-changed).

## The flow

```
your client ──POST /tasks──▶ testnet.gaskiller.xyz     (/trigger is a deprecated alias)
                                │  simulate call at block_height (from from_address)
                                │  analyzer → storage diff (StateUpdateType[],bytes[])
                                │  operator quorum signs sha256(transitionIndex,target,selector,diff)
                                ▼
                       202 {"task_id":"…","status":"queued"}

your client ──GET /tasks/{id}──▶  poll until {"status":"ready","payload":{…}}
                                          payload = {to, data, value, chain_id,
                                                     estimated_gas, valid_until_block}
                                ▼
              YOU sign and send that transaction  →  verifyAndUpdate(...) lands on your consumer
```

The aggregator **renders** a ready-to-sign payload; **the caller submits it**. The payload expires roughly
50 blocks (~10 minutes) after rendering, so submit promptly.

## Auth

`Authorization: Bearer $GK_API_KEY` — a **per-client API key**, minted by the operators.

The old shared `INGRESS_PASSWORD` bearer token is retired. Verified against the live service: it now
returns `401 {"error":{"code":"UNAUTHORIZED","message":"Unauthorized"}}` — byte-identical to sending no
credential at all, or a bogus key. Ask the Gas Killer operators for a key; never commit it.

## Request body

```json
{
  "body": {
    "target_address":   "0x… consumer contract (must be a deployed Gas Killer consumer)",
    "from_address":     "0x… simulated caller (matters only for access-controlled fns)",
    "call_data":        [/* u8 bytes of the tracked-function calldata: selector + abi-encoded args */],
    "transition_index": null,        // null => aggregator auto-pulls the next index
    "value":            "0x0",
    "block_height":     11382990     // block to simulate the call at
  }
}
```

## Responses

Errors use a structured envelope with stable machine-readable codes:
`{"error":{"code":"…","message":"…"}}`.

| Status | Meaning |
|---|---|
| `202` | accepted — `{"task_id":"…","status":"queued"}`; poll `GET /tasks/{task_id}` |
| `401` `UNAUTHORIZED` | missing/invalid API key (this is what the retired shared password now returns) |
| `409` `PAYLOAD_EXPIRED` | the rendered payload aged out of its validity window — re-trigger |
| `422` `INVALID_REQUEST` | malformed body |
| `429` `RATE_LIMITED` | per-API-key rate limit; honor `Retry-After` |
| `503` `QUEUE_FULL` | ingress backpressure; retry shortly |

## Client: `script/live/gk-trigger.sh`

Builds the calldata with `cast`, posts the task, polls until ready, and (with `GK_SUBMIT_KEY`) submits the
rendered payload — otherwise it prints the exact `cast send` for you to run.

```bash
export GK_API_KEY=<your key>

# render + submit automatically
GK_SUBMIT_KEY=0x<funded-sepolia-key> ./script/live/gk-trigger.sh \
  $GUARDED_VAULT "settle(address[],int256[])" "[$A,$B]" "[-200,200]" --watch

# render only (prints the payload to submit yourself)
./script/live/gk-trigger.sh $LIFE "step(uint32)" 1 --watch
```

Env knobs: `GK_API_KEY`, `GK_SUBMIT_KEY`, `GK_BASE_URL`, `GK_FROM`, `GK_RPC`, `GK_BLOCK`,
`GK_TRANSITION_INDEX` (see the script header). The client checks HTTP status and surfaces `.error.code`,
so an auth or rate-limit failure aborts loudly instead of polling forever.

## Wiring our examples to the live AVS

A consumer is "served" when it's deployed on a watched chain **and** wired to the AVS BLSSignatureChecker
the operators are registered with. The live Sepolia stack:

| Component | Address (Sepolia, 11155111) |
|---|---|
| AVS / ServiceManager | `0x2015983cDd409B1838F4C1cCa9085c946C5A9F81` |
| BLSSignatureChecker | `0x22FfcFD8cCCb2e70dbd6FE1DAf951080595E02f2` |
| RegistryCoordinator | `0x7aA89B1CBC571a1c6F7E6B262E06e614104Fb56d` |
| StakeRegistry | `0xac89f540a78313aE126fd95cc9e1eb82503b824A` |

```bash
AVS_ADDRESS=0x2015983cDd409B1838F4C1cCa9085c946C5A9F81 \
SIG_CHECKER_ADDRESS=0x22FfcFD8cCCb2e70dbd6FE1DAf951080595E02f2 \
  forge script script/DeployGuardedVault.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PK --broadcast
```

The fork test `test/live/SepoliaLive.t.sol` proves our contracts wire to (and are gated by) the real
on-chain checker.

## What changed

1. **Auth.** Shared `INGRESS_PASSWORD` → per-client API key. The old token now `401`s.
2. **Submission.** The aggregator used to broadcast `verifyAndUpdate` itself; upstream it now renders a
   payload for the caller to submit (service commit `947901e`, "serve user-executable payload … instead of
   broadcasting"). The broadcast paths still exist but are reserved for a future auto-execute /
   account-abstraction tier.
3. **Errors.** `{"success":…,"message":…}` → `{"error":{"code":…,"message":…}}`, plus new `429`/`503`.

**Deployment state at time of writing:** the hosted testnet is **mid-migration** — it already serves the
new error envelope and the new per-key auth, but does not yet expose `/tasks` (nginx `404`s it), so
`gk-trigger.sh` falls back to the deprecated `/trigger` alias. It also still runs **BLS**, not the newer
Schnorr path that exists upstream.

## Status — what is and isn't verified

- ✅ **Diff extraction and on-chain application are proven** for both examples: the real analyzer extracts
  the diff and the real SDK applies it via `verifyAndUpdate`, reproducing naive state and events
  byte-for-byte (`script/e2e/run-prestate-e2e.sh`, local anvil, mocked quorum).
- ✅ **On-chain wiring** to the real Sepolia checker is fork-tested.
- ⚠️ **No end-to-end run through the hosted service is currently reproducible**, because the credential
  documented previously is retired and we hold no replacement API key. Earlier rounds *did* land under the
  old broadcasting model (e.g. `stateTransitionCount` 0 → 1 on GuardedVault), but those runs predate both
  changes above and should not be presented as reproducible today.
