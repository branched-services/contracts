# INF-T5B — End-to-end testnet swap (Sepolia + Base Sepolia, live broadcast)

> Source: `docs/PRODUCTION_PUSH_PLAN.md` Step 5 (e2e swap leg).
> Sibling: `INF-T5A-testnet-verification.md`. T5A's PASS is a precondition.

## Goal

Author `script/SwapTestnetE2E.s.sol`, a Forge script that broadcasts real
swaps through the deployed Router on Sepolia (11155111) and Base Sepolia
(84532), exercising the contract paths `forge test` cannot fully prove on
real bytecode: balance-diff accounting, protocol+partner fee skim,
positive-slippage cap, the canonical Permit2 path, and a `nonReentrant`
trip via a callback-style token. Produce
`evidence/testnet-e2e-swap-2026-04-29.md` with broadcast tx hashes per leg
per chain.

## Architectural Context

- Router (`src/Router.sol`) holds user funds for the duration of a swap.
  The deployed bytecode at `0xED79938d83089D610C3d38DAe52B771A11614B41`
  (same on both testnets, CREATE3) is what we need to exercise — local
  unit tests prove the source, this task proves the deployed object.
- ExecutionProxy is a pure Weiroll VM (`src/ExecutionProxy.sol`); the
  swap "path" the Router forwards is `(bytes32[] commands, bytes[] state)`.
  Build these via the helpers in `test/helpers/WeirollTestHelper.sol` —
  do not roll your own encoder.
- Permit2 is hardcoded at `0x000000000022D473030F116dDEE9F6B43aC78BA3`
  in `src/Router.sol:89`; the canonical contract is deployed at that
  address on every supported chain (no etching needed at runtime, unlike
  in `test/Router.Permit2.t.sol:134-136` which is a unit-test concern).
- Fee model (`src/Router.sol` `_validateSwap`): protocol fee bps and
  partner fee bps are both ≤ `MAX_PROTOCOL_FEE_BPS = MAX_PARTNER_FEE_BPS =
  200` (2.00%, `src/Router.sol:78,83`). Positive slippage above
  `outputQuote` is captured by the Router unless the per-call flag passes
  through. Both must be observable via the `Swap` event
  (`src/Router.sol:148-159`).
- DEX target: pick **Uniswap V3 SwapRouter02** on each testnet (most
  reliable testnet liquidity for WETH↔USDC). Resolve the address per chain
  at the top of the script as `address constant UNISWAP_V3_ROUTER_<CHAIN>`
  — verify your chosen address has code via
  `cast code <addr> --rpc-url $RPC` before encoding it into the script.
- Token target: WETH (Sepolia `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`,
  Base Sepolia `0x4200000000000000000000000000000000000006`) and a
  USDC-like ERC20 with active liquidity. Confirm liquidity before picking
  via a `cast call` to the V3 pool's `slot0()`.

## Relevant Files

- `script/SwapTestnetE2E.s.sol` — new file you create (≤300 LOC; if
  longer, factor a helper into `script/lib/`).
- `src/Router.sol` — read-only reference: function signatures at `:735`
  (`swap`), `:770` (`swapPermit2`), `Swap` event at `:148`, `NATIVE_ETH`
  sentinel at `:74`, fee caps at `:78,83`, canonical Permit2 at `:89`.
- `test/helpers/WeirollTestHelper.sol` — Weiroll command builders
  (`encodeCommand` at `:29`, `buildCallOneArg`, `createState3`, etc.).
  Reuse.
- `test/Router.Permit2.t.sol` — Permit2 EIP-712 helpers
  (`_domainSeparator`, `_signSinglePermit`, typehashes at `:104-110`).
  Mirror exactly; do not re-derive the typehashes.
- `test/ExecutionProxy.t.sol` — Weiroll wiring patterns
  (`test_BuildWETHDepositCommand`, `test_BuildApproveCommand`,
  `test_BuildTransferCommand`). Use as templates for the
  `approve(uniRouter, amount) -> exactInputSingle(...)` shape.
- `deployments/11155111.json`, `deployments/84532.json` — read Router +
  ExecutionProxy + helper addresses from these via `vm.parseJsonAddress`
  (mirror `script/Verify.s.sol:188-195`).
- `chains.json` — RPC env mapping.
- `evidence/testnet-e2e-swap-2026-04-29.md` — new file you write.

## Reference Implementation

- Address-loading shape: copy `script/Verify.s.sol:177-195` (read
  `deployments/<chainid>.json`, parse contract addresses).
- Permit2 signing shape: copy `test/Router.Permit2.t.sol:156-180` for
  single-token. The script-context replacement for `vm.sign(userPk, …)`
  is to read the deployer key via `vm.envOr("DEPLOYER_PRIVATE_KEY",
  uint256(0))`. If unset, `revert` with a clear message instructing the
  operator to set it for the duration of the run only — see Edge Cases.
- Weiroll path encoding: copy the test patterns in
  `test/ExecutionProxy.t.sol` (`test_BuildWETHDepositCommand`,
  `test_BuildApproveCommand`, `test_BuildTransferCommand`) — they show
  how to wire `approve(uniRouter, amount) -> exactInputSingle(...)` as
  Weiroll commands against an ExecutionProxy.

## Constraints

- All swaps live-broadcast via `--account $KEYSTORE_ACCOUNT --sender
  $DEPLOYER_ADDRESS --broadcast`. No simulation-only path.
- Amounts are tiny: ≤ `0.001 WETH` per leg per chain. Total deployer
  testnet ETH spend ≤ `0.05` per chain.
- Use the existing deployed Router at the address from
  `deployments/<chainid>.json`. Do not deploy a new Router.
- Use the canonical Permit2 at `0x000000000022D473030F116dDEE9F6B43aC78BA3`
  for the Permit2 leg.
- Never write a private key into the script source or evidence file.
- The script must read `chainid` from a `--sig "run(uint256)"` parameter
  (mirror `script/Verify.s.sol:171`); do not branch on `block.chainid`
  magic.
- Each leg must end with: read the `Swap` event from the receipt, assert
  `amountToUser >= outputMin`, assert `protocolFee` and `partnerFee`
  match what was requested. Failure should `revert` so the broadcast
  errors out.
- Total new code in `script/SwapTestnetE2E.s.sol` should stay below
  300 LOC. If a leg exceeds, factor out a helper library file under
  `script/lib/`.

## Non-Goals

- No new tests in `test/` — this is a script, not a unit test. The unit
  tests (`Router.Permit2.t.sol`, `Router.Fees.t.sol`, etc.) are the
  source-level proof; this task is the deployed-bytecode proof.
- No mainnet branches. Reject `chainId in {1, 8453}` with a `revert`
  inside the script.
- Don't refactor `Router.sol`, `ExecutionProxy.sol`, or any helper.
- No new mock tokens. Use real testnet WETH + USDC.
- The `nonReentrant` callback-token leg is **conditional**: if no
  callback-style token is reachable on either testnet (likely), record
  "not reachable on testnet" in the evidence file and skip it. Do not
  invent a deploy-and-trigger fixture.

## Edge Cases

- Router takes ERC20 inputs via either approval (`Router.swap`) or
  Permit2 signature (`Router.swapPermit2`). Test both. The approval path
  needs `IERC20(token).approve(router, amount)` from the deployer before
  the swap call.
- Native ETH input uses sentinel `0xEeee...EeEE` (`src/Router.sol:74`)
  and requires `msg.value == inputAmount`. The fallback (Router receives
  ETH from executor on a buy) is at `Router.sol` receive/fallback
  handlers.
- Fee skim test: set `protocolFeeBps = 30` (0.30%) and
  `partnerFeeBps = 25` (0.25%) — both well below the 200 cap. Confirm
  the `Swap` event reports those exact values back.
- Positive slippage: set `outputQuote` slightly below the expected Uniswap
  quote (e.g., 99% of quoted) so positive slippage is observable. Default
  flag captures slippage to Router; the `Swap` event field
  `positiveSlippageCaptured` should be > 0.
- Permit2 signature: nonce must be unused. Use the timestamp as nonce
  (or query `Permit2.nonceBitmap(user, wordPos)` first). Deadline should
  be ~10 min from `block.timestamp`.
- For signing under `vm.startBroadcast(accountName)`, the keystore
  account is what's used to send tx — for `vm.sign` you need the private
  key. The keystore is encrypted (project standard,
  `setup-deployer-wallet.sh`). The script must call
  `vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0))` and `revert` with a
  clear message instructing the operator to set it for the duration of
  the run only. **Never log the key, never write it to a file.**
- Uniswap V3 SwapRouter02 `exactInputSingle` requires the input token
  approved to Uniswap's router, NOT to our Router. Inside the Weiroll
  path, our ExecutionProxy will hold the input and approve Uniswap.
- Sepolia and Base Sepolia have different USDC test addresses; hardcode
  per-chain. Verify with `cast code` before encoding.
- Run the test legs in sequence, not parallel — same nonce on the
  deployer wallet would otherwise collide.

## Acceptance Criteria

1. `script/SwapTestnetE2E.s.sol` exists; `forge build` is clean and
   `forge fmt --check` exits 0.
2. `forge script script/SwapTestnetE2E.s.sol --sig "run(uint256)"
   11155111 --rpc-url $SEPOLIA_RPC_URL --account $KEYSTORE_ACCOUNT
   --sender $DEPLOYER_ADDRESS --broadcast` exits 0; all four legs
   broadcast (ERC20→ERC20 via approval, native→ERC20, Permit2,
   `nonReentrant`-or-skipped). Same for Base Sepolia.
3. `evidence/testnet-e2e-swap-2026-04-29.md` records, per chain, per leg:
   Etherscan/Basescan tx URL, the `Swap` event values (`amountToUser`,
   `protocolFee`, `partnerFee`, `positiveSlippageCaptured`), and a
   one-line PASS/SKIP/FAIL.
4. The `Swap` event values for each leg satisfy: `amountToUser >=
   outputMin`; `protocolFee == requestedProtocolFee`; `partnerFee ==
   requestedPartnerFee`; for the slippage leg,
   `positiveSlippageCaptured > 0`; for Permit2, the input transfer used
   Permit2 nonce semantics (a second submission with the same nonce
   reverts on Permit2).
5. The `nonReentrant` leg either reverts on a real callback token or the
   evidence file documents `SKIP: no callback token reachable on
   <chain>`.
6. Total new code: only `script/SwapTestnetE2E.s.sol` (and optionally
   `script/lib/<helper>.sol`) plus
   `evidence/testnet-e2e-swap-2026-04-29.md`.
7. `git status` has no spurious modifications outside the above.

## Verification

```bash
cd /home/johnayoung/code/contracts

# 1. Build & format gates
forge build
forge fmt --check script/SwapTestnetE2E.s.sol

# 2. Sepolia
forge script script/SwapTestnetE2E.s.sol --sig "run(uint256)" 11155111 \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --account "$KEYSTORE_ACCOUNT" \
  --sender "$DEPLOYER_ADDRESS" \
  --broadcast

# 3. Base Sepolia
forge script script/SwapTestnetE2E.s.sol --sig "run(uint256)" 84532 \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --account "$KEYSTORE_ACCOUNT" \
  --sender "$DEPLOYER_ADDRESS" \
  --broadcast

# 4. Mainnet must reject
forge script script/SwapTestnetE2E.s.sol --sig "run(uint256)" 1 \
  --rpc-url "$ETH_RPC_URL" 2>&1 | grep -q "revert" && echo OK

# 5. Evidence file shape
test -f evidence/testnet-e2e-swap-2026-04-29.md
grep -cE "^Chain (11155111|84532) - Leg .*: (PASS|SKIP|FAIL)" \
  evidence/testnet-e2e-swap-2026-04-29.md   # >= 6 (3+ legs x 2 chains)

# 6. No spurious diffs
git status --porcelain | grep -vE '^[ A?] (script/SwapTestnetE2E\.s\.sol|script/lib/|evidence/testnet-e2e-swap-2026-04-29\.md)' \
  && echo "FAIL: unexpected files changed" || echo "OK"
```
