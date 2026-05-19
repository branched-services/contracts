# Chore: Add FLAG_DATA support to the Weiroll VM dispatcher

## Summary

Add a new flag bit (`FLAG_DATA = 0x20`) on `FLAG_CT_VALUECALL` so a Weiroll command can issue a value-bearing call whose calldata is taken verbatim from a state slot, instead of being built from `selector + ABI-encoded args` by `CommandBuilder.buildInputs`. The state slot's `bytes` content is used as the entire calldata payload. When the slot holds empty bytes, the call ships with zero-byte calldata -- the only way to invoke a target's `receive()` without falling through to a `fallback()`. The dispatcher branch is otherwise unchanged: the ETH value path, the slippage/output layer, and every existing call type all keep their behavior.

The change is purely additive to `src/weiroll/VM.sol`. Because `ExecutionProxy` is non-upgradeable and inherits `VM` directly, recompilation produces new bytecode that must be redeployed under a fresh CREATE3 salt namespace; rotation lands in this same chore. The encoder repo (`github.com/branched-services/go-weiroll`) gains a `FlagData` constant, a `Call.WithRawCalldata(Value)` builder, and a `Planner.AddRawCall(target, value, data)` contract-free shortcut, then ships as `v0.3.1`.

## Background

The vendored Weiroll VM at `src/weiroll/VM.sol` already carries three corrections over canonical `weiroll/weiroll`: the extended-command index uses `++i` (pre-increment) rather than `i++` so the dispatcher reads Word 2 correctly (`VM.sol:41-48`); the `DELEGATECALL` branch was removed and now reverts with `"Invalid calltype"` (`VM.sol:90-92`); and `FLAG_EXTENDED_COMMAND = 0x40` / `FLAG_TUPLE_RETURN = 0x80` follow the README and `weiroll.js` rather than canonical-main's inverted constants (`VM.sol:15-16`). The only remaining dispatcher gap is `FLAG_DATA`.

Without `FLAG_DATA`, every value-bearing call goes through `state.buildInputs(bytes4(command), bytes32(uint256(indices << 8) | IDX_END_OF_ARGS))` (`VM.sol:84-88`), which prepends a 4-byte selector to whatever args resolve from the indices. There is no way to encode a true zero-byte calldata. As a result, any target that has `receive() external payable` but no `fallback()` reverts when called from a Weiroll recipe -- the 4-byte selector arrives at `fallback()` (which doesn't exist) instead of `receive()`. descry's upcoming `helpers.SendNativeEth` (descry v0.1.0) needs to forward ETH to receive-only contracts, so the dispatcher gap blocks the release.

## Glossary

- **`indices`** = the 32-byte word that follows the command word. For short commands it's reconstructed as `bytes32(uint256(command << 40) | SHORT_COMMAND_FILL)` (`VM.sol:50`); for extended commands it's read from `commands[++i]` (`VM.sol:46-48`). Each byte is a state-slot index or a sentinel (`IDX_END_OF_ARGS`, `IDX_USE_STATE`).
- **`FLAG_CT_VALUECALL`** = `0x03`, the call-type bits that route to `address.call{value: ...}(callData)` (`VM.sol:13`, dispatcher at `VM.sol:73-89`).
- **State slot** = entry in the `bytes[] memory state` array threaded through `_execute`. For VALUECALL, byte 0 of `indices` selects the slot that holds the 32-byte ETH value; the remaining bytes feed `buildInputs` today and will host the raw-calldata-slot byte under `FLAG_DATA`.
- **`IDX_VALUE_MASK`** = `0x7f` (`CommandBuilder.sol:7`). Strips the high "is-dynamic" bit so a planner-tagged slot ref resolves to a clean slot index.
- **`Call` / `Planner`** = the `*go-weiroll` builder API. `Call` is the per-command builder (`call.go:19-28`); `Planner` is the top-level recipe assembler (`planner.go:42-50`).

## Scope

### In Scope

- `src/weiroll/VM.sol`: add `FLAG_DATA = 0x20`; split the `FLAG_CT_VALUECALL` branch on `flags & FLAG_DATA`.
- Forge tests (Receive-only mock + helper + five new tests under `ExecutionProxy.t.sol`).
- CREATE3 salt rotation `executionproxy.v2` -> `.v3` and broadcast across chains 1, 8453, 11155111, 84532. Registry + verification.
- `go-weiroll` encoder release: `FlagData` constant, `Call.WithRawCalldata`, `Planner.AddRawCall`, tests, annotated tag `v0.3.1`.

### Out of Scope

- descry-side adoption of `FLAG_DATA` (e.g., `helpers.SendNativeEth` rewrite) -- follow-up.
- Any other VM dispatcher change (DELEGATECALL reinstatement, alternative call types, flag bits beyond 0x20).
- Router-side address bookkeeping. The Router contract (`0xED79938d…14B41`) is unaffected: it forwards into ExecutionProxy by address read from its constructor; the address bump is downstream of Router redeploy in any environment that uses it together. (No pinned consumers exist today, so this is a forward-only concern.)

## Requirements

### Functional Requirements

1. **FR-1: `FLAG_DATA` constant.**
   - `src/weiroll/VM.sol` defines `uint256 constant FLAG_DATA = 0x20;` alongside the existing flag constants.
   - Bit 5 is unused in the current dispatcher (call-type bits 0-1, extended bit 6, tuple-return bit 7) -- `0x20` is the only sensible position.
   - **Acceptance:** `forge build` clean; `grep -nE 'FLAG_DATA *= *0x20' src/weiroll/VM.sol` returns one hit.

2. **FR-2: Raw-calldata dispatch under VALUECALL.**
   - Inside the `FLAG_CT_VALUECALL` branch, after the value extraction, the dispatcher branches on `flags & FLAG_DATA`:
     - If set: `bytes memory callData = state[uint8(bytes1(indices << 8)) & CommandBuilder.IDX_VALUE_MASK];`. The selector in `bytes4(command)` is ignored. The state slot may hold zero bytes (`receive()` invocation) or arbitrary bytes (a verbatim payload). The slot is not required to be a multiple of 32 -- it's a raw calldata blob, not an ABI-encoded argument.
     - If clear: existing path -- `state.buildInputs(bytes4(command), bytes32(uint256(indices << 8) | CommandBuilder.IDX_END_OF_ARGS))`.
   - A single `address(uint160(uint256(command))).call{value: calleth}(callData);` call site handles both paths.
   - **Acceptance:** `test_FlagData_EmptyCalldata_TriggersReceive` and `test_FlagData_ArbitraryCalldata_PassesVerbatim` both pass (see FR-5).

3. **FR-3: Backwards compatibility.**
   - Every existing test in `test/ExecutionProxy.t.sol` and `test/WeirollTestHelper.t.sol` passes unchanged after the VM edit. No existing recipe shape is reinterpreted.
   - The unmodified VALUECALL path -- demonstrated by `test_ExecutePath_WithWETHWrap` and `buildValueCallNoArgs` (`test/helpers/WeirollTestHelper.sol:146-156`) -- is a strict subset of the FR-2 branch (`FLAG_DATA == 0`).
   - **Acceptance:** `forge test` is green pre- and post- VM edit on the full suite, not just the FlagData tests.

4. **FR-4: `FLAG_DATA` on non-VALUECALL call types is ignored.**
   - The dispatcher tests `flags & FLAG_CT_MASK` (`VM.sol:53, 63, 73`) before any FLAG_DATA inspection. A command emitted with `FLAG_DATA | FLAG_CT_CALL` runs through the standard CALL path, ignoring the 0x20 bit. Calls with `FLAG_CT_DELEGATECALL` (0x00) still hit the `revert("Invalid calltype")` clause regardless of FLAG_DATA.
   - Reverting on an unhandled flag combination would add a free DoS surface without improving safety (the bit can only be set by a recipe author, who already controls the calldata).
   - **Acceptance:** `test_FlagData_NonVALUECALL_FlagIgnored` (a `FLAG_CT_CALL | FLAG_DATA` command behaves identically to plain CALL).

5. **FR-5: Forge tests cover the FLAG_DATA matrix.**
   - `test/mocks/ReceiveOnlyTarget.sol` (new): `receive() external payable { calls++; totalReceived += msg.value; }`, no `fallback()`, public state getters.
   - `test/helpers/WeirollTestHelper.sol`: add `FLAG_DATA` constant export and `buildValueCallWithRawData(address target, bytes4 selector, uint8 valueSlot, uint8 dataSlot)` that builds a short command with `flags = FLAG_CT_VALUECALL | FLAG_DATA` and indices `[valueSlot, dataSlot, 0xff, 0xff, 0xff, 0xff]`.
   - Five tests in `test/ExecutionProxy.t.sol` (new `FlagData` group):
     1. `test_FlagData_EmptyCalldata_TriggersReceive` -- value=0.1 ETH, data slot=`""`. Asserts `target.calls() == 1`, `target.totalReceived() == 0.1 ether`, `address(target).balance == 0.1 ether`.
     2. `test_FlagData_ArbitraryCalldata_PassesVerbatim` -- value=0, data slot=`abi.encodeWithSelector(IMockSink.recordPayload.selector, hex"deadbeef")`. Asserts the sink emits an event with `bytes` matching the data slot byte-for-byte.
     3. `test_FlagData_ZeroValue_Succeeds` -- value=0, data slot=`""`. Asserts `target.calls() == 1`, target balance unchanged.
     4. `test_FlagData_BackwardsCompat_VALUECALL_Unchanged` -- replays the WETH deposit shape from `test_ExecutePath_WithWETHWrap` using `buildWethDepositCommand` (no FLAG_DATA bit). Asserts post-state matches the legacy expectation.
     5. `test_FlagData_NonVALUECALL_FlagIgnored` -- crafts a `FLAG_CT_CALL | FLAG_DATA` command targeting `MockERC20.mint`. Asserts the mint succeeds (i.e., the 0x20 bit was ignored on the CALL path).
   - **Acceptance:** `forge test -vvv --match-test FlagData` -- five passing tests; total suite count rises by exactly five.

6. **FR-6: Salt rotation `executionproxy.v2 -> .v3`.**
   - `script/DeployCreate3.s.sol:52`: pinned constant becomes `"infrared.contracts.executionproxy.v3"`.
   - `deploy.sh:208-214`: registry-salt branch matches the new namespace string.
   - `./deploy.sh preview <chain-id>` returns the same new ExecutionProxy address across chains 1, 8453, 11155111, 84532 (CREATE3 invariant) and differs from `0xEd06BFe3F04B09f90996850129c5312A335dfbDe`.
   - `./deploy.sh deploy <chain-id>` updates `deployments/<chain-id>.json` for each chain. `./deploy.sh verify <chain-id>` flips `verified: true`.
   - Per the `290bc00` precedent (evidence files for abandoned addresses are deleted rather than retained -- git history serves the audit trail), no new evidence file is added. The `deployments/*.json` registries capture the current state.
   - **Acceptance:** Predicted address is identical on the four chains; broadcast logs show successful CREATE3 deploys; explorer verification succeeds; `deployments/*.json` reflects the new address and salt.

7. **FR-7: `go-weiroll` v0.3.1 surface.**
   - `encoder.go`: `FlagData CallFlags = 0x20`. No change to `Encode` / `EncodeExtended` (they already write `flags` verbatim into byte 4).
   - `call.go`:
     - `Call` gains an unexported `rawCalldata Value` field.
     - `Call.WithRawCalldata(data Value) *Call`:
       - Returns a new `Call` via the existing `clone()` pattern.
       - Validates that `data.Type()` is dynamic `bytes`.
       - Sets `newCall.flags = (newCall.flags &^ FlagCallTypeMask) | FlagCallWithValue | FlagData`. (Switches to VALUECALL if the caller didn't already.)
       - Defaults `newCall.value = big.NewInt(0)` when nil (so the same builder can express receive-with-zero-ETH).
       - Stores `newCall.rawCalldata = data`.
     - `clone()` copies the new field.
   - `planner.go`:
     - The arg-slot resolution path detects `c.flags & FlagData != 0`; resolves the raw calldata's state slot via `stateManager.getSlotsForValue`; resolves the value slot; emits a standard (non-extended) command with indices `[valueSlot, calldataSlot, 0xff, 0xff, 0xff, 0xff]`.
     - `Planner.AddRawCall(target common.Address, value, data Value) *ReturnValue`: builds an inline `Call` with empty `abi.Method` (selector is zero, no args), flags `FlagCallWithValue | FlagData`, value, and data. Delegates to `Add`. Documents that the returned `*ReturnValue` is non-functional unless the caller pairs it with `RawReturn()`.
   - Tests cover: encoder flag-byte golden (`0x23`), `Call.WithRawCalldata` immutability + type validation, planner golden bytes (both empty and arbitrary calldata literals; one chained `*ReturnValue` source), `Planner.AddRawCall` golden.
   - Annotated tag `v0.3.1` only after `go test ./...` is green and the contracts rotation has landed (so any fork harness that imports the encoder can also call the new on-chain dispatcher).
   - **Acceptance:** All new Go tests pass; `git describe --tags` shows `v0.3.1`; the tag is annotated (`git tag -l --format='%(objecttype)' v0.3.1` returns `tag`).

### Non-Functional Requirements

- **Security:** No new attack surface vs. the current dispatcher. A recipe author can already emit `FLAG_CT_CALL` with arbitrary calldata; `FLAG_DATA` extends the same capability to the value-bearing path. ExecutionProxy is reentrancy-guarded (inherits `ReentrancyGuard`); slippage is enforced on the output side, unaffected by calldata shape.
- **Gas:** The added branch on `flags & FLAG_DATA` is a constant-time check against an already-loaded local. No measurable impact on the unmodified VALUECALL path.
- **Compatibility:** Recipes encoded against pre-FLAG_DATA bytecode still run on the new ExecutionProxy unchanged (FR-3). Recipes that opt into FLAG_DATA only run on the rotated ExecutionProxy (FR-6) -- by design.

## Behavior Specification

### Happy Path (receive-only ETH forward via FLAG_DATA)

1. Off-chain: planner builds a recipe with one command. Value state slot holds `abi.encode(uint256(1e17))` (0.1 ETH). Calldata state slot holds `[]byte{}` (empty bytes).
2. Off-chain: encoder emits `commands = [bytes32(command_word)]` with flag byte = `FlagCallWithValue | FlagData = 0x23`, indices `[valueSlot, calldataSlot, 0xff, 0xff, 0xff, 0xff]`, return slot `0xff`, target = ReceiveOnlyTarget address.
3. EOA calls `ExecutionProxy.executePath(commands, state)` with `msg.value = 0.1 ether`.
4. VM dispatcher reads `command`, decodes `flags = 0x23`, takes the short-command branch (`flags & FLAG_EXTENDED_COMMAND == 0`).
5. Call type bits route to `FLAG_CT_VALUECALL`; value extraction reads `state[valueSlot]` -> `calleth = 1e17`.
6. FLAG_DATA branch reads `callData = state[calldataSlot] = []` (length 0).
7. `target.call{value: calleth}("")` -- target's `receive()` runs, increments `calls`, accumulates `totalReceived`.
8. Dispatcher proceeds to next command (none). Returns updated `state`.

### Error Handling

| Error Condition | Expected Behavior |
| --- | --- |
| Value state slot holds non-32-byte data | `_execute` reverts with `"_execute: value call has no value indicated."` (unchanged from current VALUECALL path; `VM.sol:76`). |
| Calldata state slot index points to an out-of-bounds slot | Solidity bounds check reverts with panic `0x32` -- standard array-out-of-bounds. No behavior change vs. existing argument-resolution paths. |
| Target reverts on the raw payload (e.g., calls a missing function) | `success == false`; dispatcher hits the `ExecutionFailed` revert at `VM.sol:100-104`, surfacing the inner revert message when present. |
| `FLAG_DATA` set on `FLAG_CT_DELEGATECALL` | Falls through to `revert("Invalid calltype")` (`VM.sol:91`). No change vs. plain DELEGATECALL. |
| `FLAG_DATA` set on `FLAG_CT_CALL` or `FLAG_CT_STATICCALL` | The bit is ignored; the standard CALL/STATICCALL path runs (FR-4). |

### Edge Cases

| Case | Expected Behavior |
| --- | --- |
| Empty bytes in the calldata slot | Zero-byte call. Target's `receive()` runs if present; otherwise the call reverts (target's choice, not the VM's). |
| Calldata slot of arbitrary non-multiple-of-32 length | Payload passes through verbatim. `buildInputs` is bypassed, so the dynamic-state `length % 32 == 0` requirement at `CommandBuilder.sol:36` does not apply on this path. |
| Calldata slot indexed with high bit set (`0x80 | slot`) | Planner-tagged dynamic ref. `& IDX_VALUE_MASK` strips the bit -- slot resolves cleanly. |
| Tuple-return on a FLAG_DATA command | `FLAG_TUPLE_RETURN` interacts with `outdata` after the call, independently of how `callData` was sourced. Returns work the same way as on plain VALUECALL. |
| Zero ETH value with FLAG_DATA | Value slot holds `abi.encode(uint256(0))`; the call is a plain CALL semantically but goes through the VALUECALL+FLAG_DATA dispatcher path. Useful for "no ABI binding, just send these bytes" calls. |

## Technical Context

### Affected Apps

- **`/home/johnayoung/code/contracts`** -- VM, deploy infra, tests. Primary changes here.
- **`/home/johnayoung/code/go-weiroll`** -- encoder/planner library. Released as v0.3.1.

### Integration Points

- **descry (downstream consumer)** -- `helpers.SendNativeEth` (and any future receive-only target action) will adopt `FLAG_DATA` after this chore lands. Not modified here.
- **`script/DeployCreate3.s.sol`** -- pinned-namespace constant at line 52 is the single edit site for the salt rotation.
- **`deploy.sh`** -- registry generation reads the same string at lines 208-214.

### Relevant Existing Code

- `src/weiroll/VM.sol:10-16` -- flag constants block; `FLAG_DATA` lands here.
- `src/weiroll/VM.sol:73-89` -- the `FLAG_CT_VALUECALL` branch to be split.
- `src/weiroll/CommandBuilder.sol:6-9` -- `IDX_*` constants; `IDX_VALUE_MASK` is referenced from the new branch.
- `src/ExecutionProxy.sol` -- inherits VM; recompiles automatically.
- `test/ExecutionProxy.t.sol:212-242` -- `test_ExecutePath_WithWETHWrap` is the existing VALUECALL reference path FR-3 preserves.
- `test/helpers/WeirollTestHelper.sol:146-156` -- `buildValueCallNoArgs`; the new `buildValueCallWithRawData` helper sits alongside.
- `script/DeployCreate3.s.sol:52` -- the pinned namespace string `"infrared.contracts.executionproxy.v2"`.
- `deploy.sh:208-214` -- the conditional that bypasses `SALT_VERSION` for ExecutionProxy.
- `deployments/{1,8453,11155111,84532}.json` -- existing v2 registry rows; will be overwritten by `deploy.sh deploy` after rotation.
- `go-weiroll/encoder.go:37-58` -- existing `CallFlags` constants; `FlagData` lands here.
- `go-weiroll/call.go:19-28, 127-164` -- `Call` struct and existing builder methods (`WithValue`, `Static`, `RawReturn`); `WithRawCalldata` matches their immutable-clone pattern.
- `go-weiroll/planner.go:42-50, 389-411` -- `Planner.Add` and `buildArgSlots`; the FLAG_DATA branch lives where arg slots are resolved.
- `go-weiroll/state.go` -- `stateManager.getSlotsForValue` already handles dynamic-bytes literals and `*ReturnValue` with `bytes` ABI type; no structural change needed.

### Files to Add

| Path | Purpose |
| --- | --- |
| `.workflow/specs/00001-CHORE-vm-flag-data.md` | This spec. |
| `test/mocks/ReceiveOnlyTarget.sol` | `receive()`-only target with a `calls()` counter and `totalReceived()` accumulator. |

### Files to Modify

| Path | Change |
| --- | --- |
| `src/weiroll/VM.sol` | Add `FLAG_DATA = 0x20` constant (alongside line 16); split the VALUECALL branch (lines 73-89) per FR-2. |
| `test/helpers/WeirollTestHelper.sol` | Add `uint8 internal constant FLAG_DATA = 0x20;` and `buildValueCallWithRawData(...)` helper. |
| `test/ExecutionProxy.t.sol` | Append the FlagData test group (five tests, FR-5). |
| `script/DeployCreate3.s.sol` | Bump pinned-namespace constant at line 52 to `"infrared.contracts.executionproxy.v3"`. |
| `deploy.sh` | Update the registry-salt branch (lines 208-214) to match `.v3`. |
| `deployments/{1,8453,11155111,84532}.json` | Regenerated by `deploy.sh deploy`; reviewed for the new address + salt. |
| `go-weiroll/encoder.go` | Add `FlagData CallFlags = 0x20`. |
| `go-weiroll/call.go` | Add `rawCalldata Value` field, `WithRawCalldata` method, update `clone()`. |
| `go-weiroll/planner.go` | Detect `FlagData` in arg-slot resolution; emit `[valueSlot, calldataSlot, 0xff, ...]` layout; add `AddRawCall`. |
| `go-weiroll/{encoder,call,planner}_test.go` | New tests per FR-7 acceptance. |

## Decisions Log

| Decision | Choice | Rationale |
| --- | --- | --- |
| Bit position for FLAG_DATA | `0x20` (bit 5) | Only unused bit between call-type (0-1) and extended (6) / tuple-return (7). |
| Behavior on non-VALUECALL call types with FLAG_DATA set | Ignore the bit | Reverting adds a free DoS surface without improving safety. Recipe authors already control calldata via plain CALL; FLAG_DATA on the wrong type changes nothing. Matches audited reference impl. |
| Selector handling under FLAG_DATA | Ignored (taken verbatim from state slot) | The whole point is verbatim calldata. Allowing the encoder to still write a selector but have it ignored keeps the encoder generic and avoids a special "no-selector" command shape. |
| State slot byte position | Byte 1 of `indices` (immediately after the value slot) | Keeps the value slot at byte 0 (unchanged) and leaves bytes 2-5 for forward compatibility (padded `0xff`). |
| Calldata slot length constraints | None -- raw bytes, any length, including zero | The slot bypasses `buildInputs`; the dynamic-state `length % 32 == 0` rule (`CommandBuilder.sol:36`) does not apply. Empty bytes is a valid value (triggers `receive()`). |
| ExecutionProxy address strategy | Rotate pinned namespace `v2 -> v3`; new same-on-all-chains address | CREATE3 is idempotent; the v2 slot cannot be reused without SELFDESTRUCT (which ExecutionProxy lacks and which EIP-6780 closes anyway). No pinned consumers exist yet, so rotation is contained. |
| Rotation cadence | One contract this chore (ExecutionProxy only) | Other contracts (Router, helpers) keep their `v1` salt -- their bytecode hasn't changed. The pinned-namespace branch in `deploy.sh:208-214` already isolates ExecutionProxy from `SALT_VERSION`. |
| go-weiroll API shape | Both `Call.WithRawCalldata` (contract-bound) and `Planner.AddRawCall` (contract-free) | Contract-bound mirrors existing `WithValue` / `Static` / `RawReturn` builder pattern. Contract-free is a shortcut for receive-only targets where there is no ABI to bind -- avoids requiring a synthetic `abi.Method`. |
| go-weiroll version bump | `v0.3.1` (patch) | Pre-1.0, additive API + no behavior change to existing flows = patch per `go-weiroll/CLAUDE.md` release rules. |

## Lineage

- **Plan source:** `/home/johnayoung/.claude/plans/goal-add-flag-data-harmonic-sutherland.md` (passed in via `/define`).
- **Research:** Direct verification of `src/weiroll/VM.sol:10-117` and `src/weiroll/CommandBuilder.sol:6-9` for the three pre-existing corrections (++i, no DELEGATECALL, README-camp flag constants). FLAG_DATA bit-position and semantics derived from the dispatcher's existing layout (bits 0-1 = call type, bit 6 = extended, bit 7 = tuple return; bit 5 is the only unused position).
- **Predecessor commits:**
  - `14d59ab fix(weiroll): vendor patched VM with extended-command + dispatcher fixes` -- the in-tree VM with the three corrections this chore extends.
  - `81158eb chore(deployments): redeploy ExecutionProxy v2 across all four chains` -- precedent for the rotation pattern.
  - `fb15405 fix(deploy): pin ExecutionProxy salt in registry + auto-generate Safe bundle` -- introduced the pinned-namespace branch this chore edits.

## Open Questions

- **descry adoption timing.** descry v0.1.0 needs FLAG_DATA reachable. This chore lands the dispatcher + encoder; descry-side adoption is the next task. If descry is released before the rotated ExecutionProxy address is broadcast on a given chain, descry-built recipes targeting receive-only contracts will revert on that chain. Surface in descry's release notes so the rollout is observed.
- **Router compatibility on rotation.** The Router contract holds the ExecutionProxy address in immutable state (constructor injection). Bumping ExecutionProxy means existing Router deployments still forward to the old address. Out of scope here, but flag for the descry team so they know which Router address pairs with which ExecutionProxy.
- **CREATE3 idempotency surprise.** Confirm via `./deploy.sh preview` on every chain that the predicted v3 address really is same-on-all-chains (the factory is consistent at `0x9fBB3DF7…`, but a forked chain or one with a different factory deployment would silently diverge). Captured as the verification gate in FR-6.

## Next Steps

Run `/task 00001-CHORE-vm-flag-data` to generate the implementation task file. Then execute Steps 2-5 from the plan file in order: VM edit -> Forge tests -> rotation prep (pause for confirmation before broadcast) -> go-weiroll release.
