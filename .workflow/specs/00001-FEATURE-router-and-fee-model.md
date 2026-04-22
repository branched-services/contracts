# Feature: Router Contract and Fee Model Overhaul

## Summary

Introduce a dedicated `Router` contract that holds user ERC20 approvals and delegates execution to a separately-deployed, owner-upgradeable executor (a refactored `ExecutionProxy`). The Router owns the entire fee model: a caller-supplied **protocol fee** on inputs (capped on-chain), an optional **partner fee** on either input or output token (also capped), and **positive slippage** capture via balance-diff accounting between `outputQuote` and executed output. Closely mirrors Odos Router V3 for pull+delegate + balance-diff accounting; follows 0x for per-call fee bps in calldata with an immutable on-chain cap.

## Background

Current state: `ExecutionProxy` is a monolithic contract that (a) holds user approvals, (b) executes Weiroll programs, (c) verifies slippage via `OutputSpec.minAmount`, and (d) charges a fee on the output token with an EIP-712 signed fee voucher for per-call overrides. This pre-MVP contract has no mainnet deployment, so there is no live user migration.

The refactor adopts the Router/executor split that both 0x and Odos use in production:

- Users approve the Router once. Upgrading the executor does not force re-approval.
- Fee logic is centralized at the boundary where the user's funds enter and exit the system, making it the single place to audit for economic correctness.
- Positive-slippage capture becomes a native revenue stream (Odos confirmed this is meaningful).

The input decisions from the originating ticket fixed the top-level strategy (flat admin-configurable protocol fee on inputs, partner fee with on-chain cap, Odos-style positive-slippage capture with per-swap pass-through flag). This spec resolves the ~20 sub-decisions those leave open.

## Scope

### In Scope

- New `Router.sol` contract holding user ERC20 approvals and native ETH entry.
- Refactor of `ExecutionProxy.sol` to a pure Weiroll VM executor (no fees, no slippage, no EIP-712).
- `swap()` entry point: single input, single output.
- `swapMulti()` entry point: multi input, multi output (atomic N-to-M with duplicate-token checks and pro-rata fee distribution).
- **Protocol fee**: caller-supplied `protocolFeeBps` in calldata, applied to input amount, capped on-chain at `MAX_PROTOCOL_FEE_BPS = 200`.
- **Partner fee**: caller-supplied `partnerFeeBps`, `partnerRecipient`, and `partnerFeeOnOutput` (bool) in calldata. Applied to either input (pre-executor) or output (post-balance-diff, post-slippage-cap). Capped on-chain at `MAX_PARTNER_FEE_BPS = 200`. 100% to partner — Infrared takes no split.
- **Positive slippage capture**: Router snapshots buy-token balance pre/post executor call, caps at `outputQuote`, retains excess. Per-swap `bool passPositiveSlippageToUser` flag disables capping and forwards the full amount to the user.
- **Fee custody**: all protocol fees, retained slippage, and partner fees (when paid upfront) accumulate in the Router. `transferRouterFunds(address[] tokens, uint256[] amounts, address dest)` and `swapRouterFunds(...)` sweep funds, gated to owner or a separate **Liquidator** role.
- **Access control**: `Ownable2Step` owner + separate `liquidator` address set by owner. Owner can pause/unpause the Router (emergency only; all swap entry points revert when paused). No timelock at launch.
- **Native ETH**: `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` sentinel; `msg.value == inputAmount` when input is native; `.call{value}` for native output.
- **Executor registry**: single owner-set `executor` address via two-step pattern (`setPendingExecutor` + `acceptExecutor`). Router calls `IExecutor.executePath(bytes commands, bytes[] state)`.
- **Cross-chain**: CREATE3 same-address deploy on all supported chains via existing factory `0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf`.
- Forge unit + fuzz + invariant tests and a single external audit before mainnet.

### Out of Scope

- **Permit2 integration**: deferred; ship ERC20-approve-to-Router path only at launch.
- **Post-swap hooks** (Odos `swapWithHook`): deferred.
- **Compact calldata** (Odos `swapCompact` with Yul decoder + address list): deferred.
- **EIP-712 signed fee vouchers** (currently in ExecutionProxy): retired entirely.
- **Off-chain user-plan registry**: plan-based fee discrimination lives in the quoting backend (bps is baked into calldata). No on-chain plan allowlist.
- **Partner registry / allowlist**: partners are identified only by the recipient address the caller supplies. No on-chain partner whitelist.
- **Partner share of positive slippage**: 100% of captured slippage goes to Infrared.
- **Timelock on owner actions**: deferred; can be added post-audit if desired.
- **Signed outputQuote voucher** to prevent positive-slippage bypass: accepted leak, matching Odos/0x practice.
- **ERC721 executor registry** (0x-style per-feature deployer): overkill for a single executor.
- **User migration from existing ExecutionProxy**: none — pre-MVP, nothing deployed.

## Requirements

### Functional Requirements

1. **FR-1 (Single Swap Entry Point)**: Router exposes `swap(SwapParams params)` that pulls input, applies fees, calls executor, enforces slippage, transfers output.
   - Acceptance: `test/Router.t.sol::testSwapERC20ToERC20()` passes. User receives >= `outputMin` and <= `outputQuote` + any uncapped passthrough.

2. **FR-2 (Multi-Swap Entry Point)**: Router exposes `swapMulti(MultiSwapParams params)` for N inputs and M outputs atomically.
   - Acceptance: pairwise duplicate-token scan rejects same-token in inputs or outputs; pro-rata fee distribution correct on all inputs and outputs.

3. **FR-3 (Protocol Fee)**: `protocolFeeBps <= MAX_PROTOCOL_FEE_BPS` (200). `protocolFeeAmount = inputAmount * protocolFeeBps / 10_000`. Deducted from `inputAmount` before forwarding remainder to executor; stays in Router.
   - Acceptance: `protocolFeeBps > 200` reverts with `ProtocolFeeExceedsCap`. Balance-diff assertion: `routerProtocolFeeHoldings += protocolFeeAmount`.

4. **FR-4 (Partner Fee — Input Denominated)**: When `partnerFeeOnOutput == false`, `partnerFeeAmount = inputAmount * partnerFeeBps / 10_000` deducted from input, transferred to `partnerRecipient` at the same step as protocol fee deduction (before executor call).
   - Acceptance: Partner recipient balance increases by `partnerFeeAmount`; remaining forwarded amount = `inputAmount - protocolFeeAmount - partnerFeeAmount`. Caps checked independently — each bps must be `<= 200`.

5. **FR-5 (Partner Fee — Output Denominated)**: When `partnerFeeOnOutput == true`, `partnerFeeAmount = amountOutForUser * partnerFeeBps / 10_000` deducted from the post-slippage-cap amount, transferred to `partnerRecipient` before the final user transfer.
   - Acceptance: User receives `amountOutForUser - partnerFeeAmount`; if this is `< outputMin`, tx reverts.

6. **FR-6 (Positive Slippage Capture)**: `amountOut = buyTokenBalanceAfter - buyTokenBalanceBefore`. If `amountOut > outputQuote` and `passPositiveSlippageToUser == false`, user receives `outputQuote` and Router retains `amountOut - outputQuote`. If flag is true, user receives `amountOut` (still subject to `outputMin`).
   - Acceptance: `test/Router.t.sol::testPositiveSlippageCapped()` verifies Router balance increases by surplus when flag off; `testPositiveSlippagePassThrough()` verifies user receives full amount when flag on.

7. **FR-7 (Slippage Floor)**: Router reverts with `SlippageExceeded` when the final post-fee amount sent to the user falls below `outputMin`.
   - Acceptance: fuzz test on `(amountOut, protocolBps, partnerBps, outputMin)` demonstrates no silent short-payment.

8. **FR-8 (Input-Output Integrity Checks)**: Router reverts when `inputToken == outputToken`. In `swapMulti`, Router reverts on any duplicate within inputs array, any duplicate within outputs array, and on any intersection between inputs and outputs.
   - Acceptance: Dedicated revert tests for each case; error types distinct.

9. **FR-9 (Quote Validity)**: Router reverts when `outputMin > outputQuote` or `outputMin == 0` or `outputQuote == 0` or `inputAmount == 0`.
   - Acceptance: Each invariant triggers a named revert.

10. **FR-10 (Executor Resolution)**: Router reads `executor` from its own storage (single address, owner-set via two-step pattern) and calls `IExecutor.executePath(commands, state)`. Router passes the remaining input tokens to the executor address before the call (Odos pattern).
    - Acceptance: Owner calls `setPendingExecutor(newAddr)` then `acceptExecutor()`; swaps issued after the accept use the new executor; swaps issued in-between are not affected.

11. **FR-11 (Executor Is Pure VM)**: `ExecutionProxy.sol` is refactored to contain only: inherit Weiroll `VM`, expose `executePath(bytes32[] commands, bytes[] state)`, and `receive()`/`fallback()` for ETH. No `Ownable`, no fee state, no slippage check, no EIP-712, no `ReentrancyGuard` (guard is at Router).
    - Acceptance: Contract bytecode under a specified size threshold; no storage variables; no admin functions.

12. **FR-12 (Native ETH Support)**: Router accepts native ETH when `inputToken == NATIVE_ETH_SENTINEL`, requires `msg.value == inputAmount`. Output ETH transferred via `.call{value}` with full gas forwarding (to support multisig receivers). `NATIVE_ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`.
    - Acceptance: ETH-in-to-ERC20-out and ERC20-to-ETH-out swaps work; fee math identical for native.

13. **FR-13 (Fee Custody and Sweep)**: Protocol fees, retained positive slippage, and any upfront-paid partner fees (only if partner recipient is the Router — not expected in practice) accumulate in Router. `transferRouterFunds(address[] tokens, uint256[] amounts, address dest)` and `swapRouterFunds(...)` callable only by `owner` or `liquidator`.
    - Acceptance: Sweep functions revert for other callers; accept zero-length arrays; handle both ERC20 and native ETH.

14. **FR-14 (Access Control)**: `Ownable2Step` for owner. Separate `liquidator` address, set by owner. Owner can `pause()` / `unpause()`; while paused, all swap entry points revert.
    - Acceptance: Pause blocks all swaps; liquidator cannot call config functions; owner can update liquidator.

15. **FR-15 (Balance-Diff Accounting Tolerates Weird Tokens)**: Router measures input pulled and output produced via balance deltas rather than trusting declared amounts. Fee-on-transfer tokens reduce the effective post-pull amount; Router uses that reduced amount for fee and forwarding math. Rebasing tokens are accounted for via the post-executor snapshot.
    - Acceptance: Adversarial-token mocks from existing `test/mocks/` (fee-on-transfer, rebasing) exercised in Router tests.

16. **FR-16 (Reentrancy Guard)**: Router swap entry points are `nonReentrant`. ExecutionProxy is *not* reentrant-guarded (balance-diff at Router is the defense).
    - Acceptance: reentrant-token mock cannot drain Router; a swap callback attempting to re-enter `swap()` reverts.

17. **FR-17 (Swap Event)**: Router emits a `Swap` event per call with `(sender, inputToken, inputAmount, outputToken, amountOut, amountToUser, protocolFee, partnerFee, positiveSlippageCaptured, partnerRecipient)`.
    - Acceptance: Event parameters are sufficient to reconstruct fee attribution off-chain.

### Non-Functional Requirements

- **Security**: Single external audit (Zellic / Spearbit / Halborn tier) completed before mainnet deploy. Forge unit + property-based fuzz + invariant tests. Invariant: `sumOfUserReceived + protocolFeesAccrued + partnerFeesPaid + positiveSlippageRetained == aggregateBalanceDiffOfExecutor`.
- **Upgrade path**: Users re-approve zero times after launch. Executor upgrades are a single `setPendingExecutor` + `acceptExecutor` by owner multisig.
- **Gas**: No hard budget committed in this spec; compact calldata deferred. Expect ~30-50k gas overhead per swap vs. calling the executor directly (one `transferFrom`, one balance snapshot pair, one fee transfer when partner fee is set).
- **Multi-chain deploy**: CREATE3 same-address on Ethereum (1), Base (8453), Sepolia (11155111), Base Sepolia (84532); future chains as added. Native-ETH handling works identically across all EVM-equivalent chains (relies only on core `msg.value` + `.call{value}` opcodes).
- **Solidity**: `0.8.24`, optimizer 200 runs. BUSL-1.1 license (matches current repo).
- **Operational**: Owner is a multisig from day one. Liquidator is a hot wallet for routine sweeps.

## Behavior Specification

### Happy Path — Single Swap (ERC20 in, ERC20 out)

1. Off-chain: backend assembles `SwapParams { inputToken, inputAmount, outputToken, outputQuote, outputMin, recipient, protocolFeeBps, partnerFeeBps, partnerRecipient, partnerFeeOnOutput, passPositiveSlippageToUser, weirollCommands, weirollState }` and returns to the caller along with the Router address.
2. User approves `Router` for `inputAmount` of `inputToken` (one-time; persists).
3. User calls `Router.swap(params)`:
   1. Router validates: `inputAmount > 0`, `outputQuote > 0`, `0 < outputMin <= outputQuote`, `inputToken != outputToken`, `protocolFeeBps <= 200`, `partnerFeeBps <= 200`, not paused.
   2. Router `transferFrom(user, Router, inputAmount)` and measures `pulled = balanceAfter - balanceBefore` (handles fee-on-transfer).
   3. Router computes `protocolFeeAmount = pulled * protocolFeeBps / 10_000`.
   4. If `!partnerFeeOnOutput`: `partnerFeeAmount = pulled * partnerFeeBps / 10_000`; transfer `partnerFeeAmount` to `partnerRecipient`.
   5. Forward `forwardAmount = pulled - protocolFeeAmount - (partnerFeeOnOutput ? 0 : partnerFeeAmount)` to `executor` address.
   6. Snapshot `outputBalanceBefore = outputToken.balanceOf(Router)`.
   7. Router calls `IExecutor(executor).executePath(weirollCommands, weirollState)`.
   8. `amountOut = outputToken.balanceOf(Router) - outputBalanceBefore`.
   9. If `!passPositiveSlippageToUser && amountOut > outputQuote`: retain `amountOut - outputQuote` in Router; set `amountOut = outputQuote`.
   10. If `partnerFeeOnOutput`: `partnerFeeAmount = amountOut * partnerFeeBps / 10_000`; transfer to `partnerRecipient`; `amountOut -= partnerFeeAmount`.
   11. Require `amountOut >= outputMin`; else revert `SlippageExceeded`.
   12. Transfer `amountOut` of `outputToken` to `recipient`.
   13. Emit `Swap(...)`.
4. User holds `amountOut` of `outputToken`. Protocol fee + (any) retained slippage sit in Router, swept later by owner or liquidator.

### Happy Path — Native ETH in

Same as above except: step 2 is skipped (no approval for ETH); step 3a additionally requires `msg.value == inputAmount`; step 3b becomes a no-op (Router already holds the ETH via `payable`); fee deductions operate on `pulled = inputAmount`; forwarding uses `executor.call{value: forwardAmount}(abi.encodeCall(IExecutor.executePath, (commands, state)))`.

### Happy Path — Native ETH out

Same as step 3 except: balance snapshots use `address(this).balance`; final transfer uses `recipient.call{value: amountOut}("")` with `revert("ETHTransferFailed")` on failure.

### Error Handling

| Error Condition                                                  | Expected Behavior                                |
| ---------------------------------------------------------------- | ------------------------------------------------ |
| `inputAmount == 0`                                               | revert `ZeroInputAmount`                         |
| `outputQuote == 0`                                               | revert `ZeroOutputQuote`                         |
| `outputMin == 0`                                                 | revert `ZeroOutputMin`                           |
| `outputMin > outputQuote`                                        | revert `InvalidSlippageBounds`                   |
| `inputToken == outputToken`                                      | revert `SelfSwap`                                |
| `protocolFeeBps > 200`                                           | revert `ProtocolFeeExceedsCap(bps)`              |
| `partnerFeeBps > 200`                                            | revert `PartnerFeeExceedsCap(bps)`               |
| `partnerFeeBps > 0 && partnerRecipient == address(0)`            | revert `InvalidPartnerRecipient`                 |
| Native ETH input with `msg.value != inputAmount`                 | revert `ETHValueMismatch`                        |
| Final `amountOut < outputMin`                                    | revert `SlippageExceeded(outputToken, got, min)` |
| Paused state                                                     | revert `Paused`                                  |
| ETH transfer to recipient or partner fails                       | revert `ETHTransferFailed`                       |
| Non-owner calls `setPendingExecutor` / `pause` / etc             | revert `Unauthorized` (Ownable2Step revert)      |
| Non-(owner OR liquidator) calls `transferRouterFunds`            | revert `Unauthorized`                            |
| MultiSwap: duplicate token in inputs or outputs                  | revert `DuplicateToken(token)`                   |
| MultiSwap: any input token appears in outputs array              | revert `InputOutputIntersection(token)`          |
| Executor call reverts (OOG, explicit revert)                     | bubble up (no catch)                             |
| `transferFrom` returns false or reverts                          | bubble up via `SafeERC20`                        |

### Edge Cases

| Case                                                                             | Expected Behavior                                                                                                                                                       |
| -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Fee-on-transfer input token (e.g. 1% burn)                                       | `pulled < inputAmount`; Router uses `pulled` for fee math and forwards `pulled - fees`. `outputMin` still enforced against executor result; revert if insufficient.     |
| Rebasing token between pre- and post-executor snapshots                          | Balance-diff captures actual produced amount. Positive rebase inflates `amountOut`; cap at `outputQuote` still applies.                                                 |
| `protocolFeeBps == 0` and `partnerFeeBps == 0`                                   | Full `pulled` forwarded to executor. No fee transfers emitted; `protocolFee = partnerFee = 0` in event.                                                                 |
| `passPositiveSlippageToUser == true` and `amountOut > outputQuote`                | User receives full `amountOut`; Router retains nothing from this swap. Partner fee (if on output) still applies to the full `amountOut`.                                |
| `amountOut == outputQuote` exactly                                               | No surplus to cap. Downstream logic identical to either flag setting.                                                                                                    |
| Protocol fee + partner fee both on input, sum of bps approaches 400              | Allowed; each capped at 200 independently. Worst case user pays 4% combined. Documented as intentional.                                                                 |
| Caller sets `outputQuote` artificially high to avoid capping                     | Accepted leak; Router cannot tell an "honest" quote from an inflated one. Revenue depends on API-controlled calldata. `outputMin` still enforced.                        |
| Caller sets `passPositiveSlippageToUser = true`                                  | Accepted leak; caller receives full execution upside. Documented; not prevented on-chain.                                                                                |
| ExecutionProxy reverts mid-execution                                             | Whole tx reverts; user loses no tokens (atomic); approval remains intact.                                                                                               |
| Reentrant token calls `Router.swap()` during executor callback                   | `nonReentrant` on Router swap entry reverts.                                                                                                                             |
| Executor is updated between the API quoting the swap and the user submitting it | Swap executes against the new executor. If the new executor can still produce the same output for the same path, works fine. API should re-assemble on executor change. |
| `partnerFeeOnOutput == true` and executor produces exactly `outputMin`           | Partner fee eats into output; final user amount < outputMin; tx reverts. Backend must size quotes accounting for partner fee.                                           |
| Multi-swap with partial output token produced (one of M outputs at zero)         | Output-specific `outputMin` for each output individually enforced; if any output < its min, whole tx reverts.                                                           |

## Technical Context

### Affected Apps

- `contracts/`: primary codebase. New `src/Router.sol`; refactored `src/ExecutionProxy.sol` (gutted to pure VM); new interface `src/interfaces/IExecutor.sol`; updated deploy script `deploy.sh` + new `script/DeployRouter.s.sol`.
- `infrared/` (Go API server in sister repo): backend must assemble new `SwapParams` payload with `protocolFeeBps`, `partnerFeeBps`, etc. Not in scope for this spec but a downstream dependency.
- `www/` (frontend): approval target changes from current `ExecutionProxy` address to the new `Router` address. Display-only downstream change.

### Integration Points

- **CREATE3 factory** (`0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf`): used for deterministic multi-chain Router deploy.
- **Weiroll VM** (`@weiroll/VM.sol`): retained inside `ExecutionProxy` as the execution engine.
- **OpenZeppelin**: `Ownable2Step`, `ReentrancyGuard`, `SafeERC20`, `Pausable`.
- **Backend quoting engine**: sole honest source of `outputQuote` and fee bps. Implicit trust assumption documented in spec.

### Relevant Existing Code

- `src/ExecutionProxy.sol`: current combined fee+executor contract. Reference for Weiroll VM integration, native-ETH handling patterns (`NATIVE_ETH` sentinel, `_getBalance`, `_getBalanceBefore`), and fee-math shape. To be drastically reduced in scope.
- `test/mocks/`: adversarial tokens (fee-on-transfer, rebasing, callback, false-returning), MockDEX, reentrancy attacker. Reusable directly.
- `test/WeirollTestHelper.t.sol` + `test/helpers/WeirollTestHelper.sol`: existing encoding/state-array helpers. Reusable.
- `test/ExecutionProxy.t.sol`: existing test suite — tests around fee logic will be moved to `test/Router.t.sol`; tests around Weiroll execution stay with the executor.
- `docs/internal/odos-architecture.md`, `docs/internal/odos-fees.md`: authoritative references for the adopted patterns.
- `docs/internal/0x-settler-architecture.md`, `docs/internal/0x-fee-model.md`: reference for the per-call fee bps model and cap-as-only-guarantee design.

## Decisions Log

| Decision                                         | Choice                                                                 | Rationale                                                                                                                 |
| ------------------------------------------------ | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Router architecture                              | Odos-style pull + delegate with balance-diff accounting                | Strongest user guarantee (slippage enforced after all execution); executor-agnostic; well-documented precedent.           |
| Router-to-executor relationship                  | Owner-set `executor` address, two-step pattern                         | Simplest registry; governance-tx upgrade path; matches 0x simplicity without ERC721 overhead.                             |
| Permit2 at launch                                | No — ERC20 approve path only                                           | Smaller audit scope; faster delivery; Permit2 is additive and can ship later without user migration.                      |
| Launch feature set                                | `swap()` + `swapMulti()`                                               | Covers 90%+ of volume; hooks/compact-calldata defer.                                                                     |
| EIP-712 signed fee voucher                       | Retired entirely                                                       | Router becomes the single fee authority; per-call bps in calldata + on-chain cap is the new guarantee.                    |
| Protocol fee mechanism                           | Skim from input in Router before forwarding to executor                | Matches user's "charged on INPUTS" mandate literally; deterministic; single transfer path.                                |
| Protocol fee authority model                     | Caller-supplied `protocolFeeBps` in calldata, capped on-chain          | Matches 0x's approach; backend decides bps based on user's plan; cap is the on-chain guarantee against malicious calldata.|
| Protocol fee cap                                 | `MAX_PROTOCOL_FEE_BPS = 200` (2.0%), immutable                         | Headroom above Odos's 25 bps protected-swap rate without exposing users to extreme worst case. 10% cap rejected as too loose given bps is caller-controlled. |
| Fee custody                                      | Accumulate in Router; sweep via owner/liquidator                       | Matches Odos; cheaper per-swap gas; liquidator separation lets a hot wallet handle routine sweeps.                         |
| Partner fee split                                | 100% to partner; Infrared takes no cut                                 | Go-to-market lever; easier integrator recruitment; Infrared revenue comes from protocol fee + positive slippage.          |
| Partner fee token                                | Caller chooses per-call (INPUT or OUTPUT)                              | Matches 0x's `swapFeeToken` flexibility; two code paths acceptable; supports both fee-on-sell and fee-on-buy integrators. |
| Partner fee cap                                  | `MAX_PARTNER_FEE_BPS = 200` (2.0%), immutable                          | Industry-standard 2% cap (Odos's hard cap).                                                                               |
| Partner auth                                     | Any address the caller supplies in calldata                            | No on-chain registry; caller trust is the caller's problem; cap protects the user.                                        |
| Positive slippage capture mechanism              | Balance-diff with cap at `outputQuote`                                 | Matches Odos exactly; no trust in executor; cheap.                                                                        |
| Positive-slippage pass-through flag              | Dedicated `bool passPositiveSlippageToUser` on swap struct             | Self-documenting; calldata cost negligible at launch (compact calldata deferred).                                         |
| Defense against positive-slippage revenue bypass | Accept the leak — rely on API-control of calldata                      | Both Odos and 0x explicitly accept this; adding on-chain defenses (per-caller allowlist, signed quote voucher) duplicates infrastructure and doesn't close the underlying `outputQuote`-inflation attack. |
| Partner share of positive slippage               | None — 100% to Infrared when captured                                  | Simplifies model; partners earn via partner fee only.                                                                     |
| `outputQuote` / `outputMin` model                | Both explicit in calldata; `outputMin <= outputQuote` enforced         | Matches Odos; backend responsible for honest quoting.                                                                     |
| Fee stacking on INPUT token                      | Protocol fee + partner fee both deducted from input; caps independent  | Simpler math and audit; worst-case 4% combined input fee is documented and intentional.                                   |
| Same-token swap check                            | Revert on `inputToken == outputToken`; multi-swap extended check       | Prevents self-arbitrage exploit of positive-slippage cap; matches Odos.                                                   |
| ExecutionProxy new role                          | Pure Weiroll VM wrapper; no fees, no slippage, no EIP-712, no owner    | Smallest possible audit surface for the arbitrary-execution piece; Router owns all economic logic.                         |
| Governance                                       | `Ownable2Step` multisig owner + separate Liquidator + emergency pause  | Owner multisig for config/governance; liquidator hot-wallet for routine sweeps; pause for incident response. No timelock at launch (can add post-audit). |
| Multi-chain deploy                               | CREATE3 same address on all supported chains                           | Reuses existing factory; partners can hardcode; matches Odos/0x deterministic-address pattern.                             |
| Native ETH sentinel                              | `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` (reuse existing)          | Consistent with existing ExecutionProxy + 1inch/Aave convention. Chain-agnostic (relies only on core EVM opcodes).        |
| Fee-on-transfer / rebasing tokens                | Balance-diff accounting natively handles them; no denylist              | Router measures actual pulled/produced amounts; adversarial-token mocks in `test/mocks/` cover the behavior.              |
| User migration                                   | None — pre-MVP, no prior deployment                                    | Fresh deploy; no legacy approvals to preserve.                                                                            |
| Testing scope                                    | Unit + fuzz + invariant + single external audit                        | Appropriate for pre-MVP risk level; can add fork tests, formal verification, or second audit as TVL grows.               |

## Lineage

- **Research**: None — defined from scratch, driven by `docs/internal/odos-architecture.md`, `docs/internal/odos-fees.md`, `docs/internal/0x-settler-architecture.md`, and `docs/internal/0x-fee-model.md`.
- **Originating decision ticket**: informal design brief in the `/define` invocation (Router+core split, protocol fee on inputs, partner fee at launch, positive slippage kept by default with pass-through flag).

## Open Questions

None requiring stakeholder input before `/task`. Noted for operational follow-up (out of this spec's scope):

1. Multisig composition (signers, threshold) for Router owner on each chain.
2. Liquidator hot-wallet address generation + key management.
3. Audit vendor selection + timeline booking.
4. Backend quoting engine changes required to emit the new `SwapParams` shape (tracked separately in the `infrared/` repo).
5. Vanity-address decision (accept CREATE3-computed address vs. mine for a memorable prefix) — cosmetic, can be decided at deploy time.

## Next Steps

Run `/task 00001-FEATURE-router-and-fee-model` to generate implementation tasks from this spec.
