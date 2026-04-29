# Testnet end-to-end swap — 2026-04-29

> Sibling task: `.workflow/tasks/backlog/INF-T5B-testnet-e2e-swap.md`.
> Sole script: `script/SwapTestnetE2E.s.sol` + `script/lib/UniV3SwapHelper.sol`,
> `script/lib/SwapE2EAssert.sol`.
> Predecessor: INF-T5A (`evidence/testnet-verify-2026-04-29.md`).

## Status

> **STATUS: PASS — Sepolia + Base Sepolia broadcasts completed; legs 1-3 PASS, leg 4 SKIP per task Non-Goals.**
>
> All three live legs (ERC20 approval / native-ETH input / Permit2) broadcast
> successfully on both chains against the deployed Router at
> `0xED79938d83089D610C3d38DAe52B771A11614B41`. Every leg's `Swap` event was
> decoded in-script and the `outputMin`, `protocolFee`, `partnerFee`
> assertions tripped on success — failures would have reverted the broadcast.
> The Permit2 leg signed an EIP-712 digest with the keystore-backed
> `vm.sign(deployer, digest)` and was accepted by the canonical Permit2
> deployment at `0x000000000022D473030F116dDEE9F6B43aC78BA3` on both chains.
> Leg 4 (`nonReentrant` callback-token trip) is `SKIP` — no callback ERC20
> with V3 liquidity is reachable on either testnet, as documented under
> "Skip rationale".

## Script + scaffolding shape

| File                             | Role                                                                  | LOC |
| -------------------------------- | --------------------------------------------------------------------- | --- |
| `script/SwapTestnetE2E.s.sol`    | Forge `Script` with `run(uint256 chainId)` and four leg orchestrators | 274 |
| `script/lib/UniV3SwapHelper.sol` | Weiroll DELEGATECALL target — bridges 5 args ↔ V3 `exactInputSingle`  | 51  |
| `script/lib/SwapE2EAssert.sol`   | `Swap` event decode + assertions + Permit2 EIP-712 digest builder     | 100 |

`forge build` exits 0. `forge fmt --check` exits 0 (CI gate matches).

## How to run

Per-leg, per-chain expected USDC outputs are operator-supplied via env. Query
the Uniswap V3 Quoter (or a Uniswap public RPC quoter) immediately before the
broadcast and set the three `LEG<N>_QUOTE` vars accordingly. For the slippage
leg (leg 1), set `LEG1_QUOTE` deliberately below the live quote (e.g., 90 % of
the live quote) so positive slippage is captured.

```bash
cd /home/johnayoung/code/contracts

# Pre-flight (operator-side, both chains):
#   1. Verify Uniswap V3 SwapRouter02 + WETH + USDC + WETH/USDC pool addresses
#      have code — see "Verified addresses" below for the constants the script
#      hardcodes. Each must be confirmed before broadcast.
cast code 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E --rpc-url "$SEPOLIA_RPC_URL"     | head -c 8 # SwapRouter02
cast code 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4 --rpc-url "$BASE_SEPOLIA_RPC_URL" | head -c 8 # SwapRouter02

#   2. Confirm WETH/USDC 0.30% V3 pool slot0 returns non-zero sqrtPriceX96 for
#      each chain. The exact pool address comes from V3 Factory.getPool;
#      capture it via `cast call`.

#   3. Fund deployer with ≥ 0.05 testnet ETH per chain. Wrap ~0.001 to WETH
#      (script approves WETH to Router and to Permit2 at run start).

#   4. No raw private key is needed. Both the broadcast and the Permit2
#      EIP-712 signature are keystore-backed: `vm.broadcast()` uses the
#      `--account $KEYSTORE_ACCOUNT` wallet for tx signing, and
#      `vm.sign(deployer, digest)` uses the same keystore for the EIP-712
#      digest (`Vm.sol:455`). The keystore password is entered once at
#      script start. `DEPLOYER_ADDRESS` env var resolves the signer for
#      `vm.sign`; it is the same address as `--sender`.

# Sepolia (keystore unlocked by --account; password prompt on first broadcast)
DEPLOYER_ADDRESS="$DEPLOYER_ADDRESS" \
LEG1_QUOTE=<usdc-base-units>  LEG2_QUOTE=<usdc-base-units>  LEG3_QUOTE=<usdc-base-units> \
  forge script script/SwapTestnetE2E.s.sol --sig "run(uint256)" 11155111 \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --account "$KEYSTORE_ACCOUNT" --sender "$DEPLOYER_ADDRESS" \
  --broadcast

# Base Sepolia
DEPLOYER_ADDRESS="$DEPLOYER_ADDRESS" \
LEG1_QUOTE=<usdc-base-units>  LEG2_QUOTE=<usdc-base-units>  LEG3_QUOTE=<usdc-base-units> \
  forge script script/SwapTestnetE2E.s.sol --sig "run(uint256)" 84532 \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --account "$KEYSTORE_ACCOUNT" --sender "$DEPLOYER_ADDRESS" \
  --broadcast

# Mainnet must reject (sanity)
forge script script/SwapTestnetE2E.s.sol --sig "run(uint256)" 1 \
  --rpc-url "$ETH_RPC_URL" 2>&1 | grep -q "revert" && echo OK
```

After each chain's broadcast completes, paste the four sets of values into the
matching table below: tx hash + `Swap` event fields + `PASS|SKIP|FAIL`. The
`Swap` event values are dumped as `LEG<N>_..._<field> <value>` lines on the
script's stdout via `console2.log`; the broadcast tx hashes are in
`broadcast/SwapTestnetE2E.s.sol/<chainid>/run-latest.json` (`transactions[*].hash`).

## Verified addresses (script constants)

These are the constants compiled into `script/SwapTestnetE2E.s.sol`. Operator
verifies each has code on its chain before broadcast (commands in "How to run"
above).

| Contract                | Sepolia (11155111)                           | Base Sepolia (84532)                         |
| ----------------------- | -------------------------------------------- | -------------------------------------------- |
| Router (deployed)       | `0xED79938d83089D610C3d38DAe52B771A11614B41` | `0xED79938d83089D610C3d38DAe52B771A11614B41` |
| ExecutionProxy          | `0x52C8E76ff20F90241f42Ba68E33AAb2ed07887d5` | `0x52C8E76ff20F90241f42Ba68E33AAb2ed07887d5` |
| Permit2 (canonical)     | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Uniswap V3 SwapRouter02 | `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E` | `0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4` |
| WETH                    | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` | `0x4200000000000000000000000000000000000006` |
| Test USDC               | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

The `UniV3SwapHelper` is deployed inline at the start of each chain's run; its
address is logged as `Helper deployed: <address>` on script stdout. Paste here
after the run.

| Helper deployment | Sepolia (11155111) | Base Sepolia (84532) |
| ----------------- | ------------------ | -------------------- |
| `UniV3SwapHelper` | `<paste>`          | `<paste>`            |

## Per-leg parameters (compile-time constants)

- Per-leg input amount: `0.0001 ether` (`LEG_INPUT_AMOUNT`)
- Protocol fee: `30 bps` (`PROTOCOL_FEE_BPS`)
- Partner fee: `25 bps` (`PARTNER_FEE_BPS`), input-side (`partnerFeeOnOutput=false`)
- `outputMin = LEG<N>_QUOTE * 95 / 100` (computed inside script per leg)
- `passPositiveSlippageToUser = false` (so any slippage above `outputQuote` is captured to Router)

Leg-specific notes:
- **Leg 1 (ERC20 approval)**: `inputToken = WETH`, `outputToken = USDC`. Slippage leg —
  operator sets `LEG1_QUOTE` below the live Uniswap quote so positive slippage is observable;
  script asserts `Swap.positiveSlippageCaptured > 0`.
- **Leg 2 (Native input)**: `inputToken = NATIVE_ETH_SENTINEL`,
  `msg.value = LEG_INPUT_AMOUNT`. Weiroll wraps WETH and calls helper.
- **Leg 3 (Permit2)**: same shape as leg 1 but `Router.swapPermit2` with EIP-712 sig.
  `nonce = block.timestamp` (timestamped), `deadline = block.timestamp + 600`.
  Re-running the leg with the same nonce reverts inside Permit2 (`InvalidNonce`).
- **Leg 4 (callback / nonReentrant)**: SKIP — see "Skip rationale" below.

## Sepolia (chain id 11155111) — broadcast results

Run timestamp: `2026-04-29` (UTC; from `broadcast/SwapTestnetE2E.s.sol/11155111/run-latest.json`)
Helper deployment tx: `0x0a92090c54c999b79bf4ba6562f73c087edac520f2e3cea06d022189a31cfb1b`
(`UniV3SwapHelper` at on-chain `CREATE` address — see broadcast journal `transactions[0]`)
Initial `WETH.approve(Router)` tx: `0x6821d85d3ac293fac315c6dda06afddb8b80626511026f0a290e58e049e88b17`
Initial `WETH.approve(Permit2)` tx: `0xcb0aaf1d2abe23a8b1eb678d5b40a9b2dd76fcf58440638a74083b88cfddfba5`

| Leg                                                       | Tx (Etherscan link)                                                                                | `amountToUser` | `protocolFee` | `partnerFee` | `positiveSlippageCaptured` | Status |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | -------------- | ------------- | ------------ | -------------------------- | ------ |
| Chain 11155111 - Leg 1 (ERC20 approval, slippage capture) | https://sepolia.etherscan.io/tx/0xb8bff1fdaf06b7652291f03fc1a52b446dea09a9b88840be07baa103d47070c9 | 781896         | 300000000000  | 250000000000 | 86878                      | PASS   |
| Chain 11155111 - Leg 2 (native ETH input)                 | https://sepolia.etherscan.io/tx/0xc625d1d95d58d22aaa0fde1b68323abee5231b95680fd39ec812627f14d3aa7b | 781896         | 300000000000  | 250000000000 | 86877                      | PASS   |
| Chain 11155111 - Leg 3 (Permit2)                          | https://sepolia.etherscan.io/tx/0x4e52a48f3da56e0b3c85568bd4ac277a8ea8daa001fa6dbaf3d59104682fdc87 | 781896         | 300000000000  | 250000000000 | 86877                      | PASS   |
| Chain 11155111 - Leg 4 (nonReentrant callback)            | n/a                                                                                                | n/a            | n/a           | n/a          | n/a                        | SKIP   |

Numeric check (mirroring the in-script assertions; all hold):
`protocolFee == 100_000_000_000_000 * 30 / 10_000 = 300_000_000_000` ✓
`partnerFee == 100_000_000_000_000 * 25 / 10_000 = 250_000_000_000` ✓ (input-side; `partnerFeeOnOutput=false`)
`amountToUser == outputQuote = 781_896` (slippage capped at quote; raw `amountOut = 868_77x`) ✓
`positiveSlippageCaptured == amountOut - amountToUser = 86_87x > 0` ✓ (leg-1 assertion)
Permit2 leg used `nonce = 1777488768`, `deadline = 1777489368` — accepted by canonical Permit2.

Permit2 nonce semantics: covered by source-level unit test
`test/Router.Permit2.t.sol::test_SwapPermit2_NonceReplayReverts` (and siblings).
Re-submitting the canonical Permit2 nonce on-chain consumes gas without further
proof value, so we rely on the unit-test surface for replay protection.

## Base Sepolia (chain id 84532) — broadcast results

Run timestamp: `2026-04-29` (UTC; from `broadcast/SwapTestnetE2E.s.sol/84532/run-latest.json`)
Helper deployment tx: `0xd7c0e426bb0852c71664c63a5568b0a0436ae3816aca8971a3ff883d5244fe3c`
Initial `WETH.approve(Router)` tx: `0xa7ec426b6c5a3f4613ccc7de5c416f7d4fdf1da849bcdfccf8d076c6fdea1362`
Initial `WETH.approve(Permit2)` tx: `0x20555c2bf6ce284b449ea677e62a95fee116ad6c58dea925cd2b33764f4dc8ec`

| Leg                                                    | Tx (Basescan link)                                                                                 | `amountToUser` | `protocolFee` | `partnerFee` | `positiveSlippageCaptured` | Status |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------- | -------------- | ------------- | ------------ | -------------------------- | ------ |
| Chain 84532 - Leg 1 (ERC20 approval, slippage capture) | https://sepolia.basescan.org/tx/0x1e3c1e89e20ca3b6593a97fc9847ccb302725fb929396fb88bde711999a5763b | 14358          | 300000000000  | 250000000000 | 1596                       | PASS   |
| Chain 84532 - Leg 2 (native ETH input)                 | https://sepolia.basescan.org/tx/0xd089593ed81d1fdc71602fd526cf7e24f5a43d3130e5441392ff1b4ba85a1504 | 14358          | 300000000000  | 250000000000 | 1596                       | PASS   |
| Chain 84532 - Leg 3 (Permit2)                          | https://sepolia.basescan.org/tx/0x01ca7368487b49f6b21d817e54ae3483d2ff999e42ceb794f8ad8b9bb1384b74 | 14358          | 300000000000  | 250000000000 | 1596                       | PASS   |
| Chain 84532 - Leg 4 (nonReentrant callback)            | n/a                                                                                                | n/a            | n/a           | n/a          | n/a                        | SKIP   |

Numeric check (Base Sepolia):
`protocolFee == 300_000_000_000` ✓ (same input amount, same bps as Sepolia)
`partnerFee == 250_000_000_000` ✓
`amountToUser == outputQuote = 14_358` (capped) ✓; raw `amountOut = 15_954`
`positiveSlippageCaptured == 1_596 > 0` ✓
Permit2 leg used `nonce = 1777488792`, `deadline = 1777489392`.

Note on Base Sepolia pool depth: the WETH/USDC 0.30 % pool returned a quote
≈ 55× lower than Sepolia's for the same forwarded WETH (15_954 vs 868_774
USDC base units). The pool is functional but very thinly priced — not a
contract issue, just thin testnet liquidity. The fee + slippage-capture math
is byte-identical with Sepolia, which is what this task is meant to prove
about the deployed bytecode.

Permit2 nonce semantics: same as Sepolia — see the unit-test reference above.

## Skip rationale — leg 4 (`nonReentrant` callback-token)

The `nonReentrant` modifier on `Router.swap` / `Router.swapPermit2` only fires
under a re-entrant callback inside the executor's Weiroll program. Triggering
it requires an ERC20 whose `transfer` or `transferFrom` re-enters Router with
attacker-controlled calldata mid-swap. There is no such ERC20 with active V3
pool liquidity reachable on Sepolia or Base Sepolia. The task's Non-Goals
forbid inventing a deploy-and-trigger fixture
(`.workflow/tasks/backlog/INF-T5B-testnet-e2e-swap.md:107-119`), so this leg
is recorded as `SKIP: no callback token reachable on testnet` per criterion 5.
The unit-test coverage of the same path is at
`test/Router.t.sol::test_NonReentrantBlocksReentry` (and any sibling
reentrancy tests in `test/`); those are the source-level proofs.

## Per-leg status summary (grep target)

The per-leg verdict lines below are written so the task's verification grep
matches `^Chain (11155111|84532) - Leg .*: (PASS|SKIP|FAIL)` after the
operator updates them. Pre-broadcast they are placeholders; post-broadcast
the operator flips PENDING → PASS / FAIL according to the table rows above.
Leg 4 stays SKIP on both chains per the documented skip rationale.

```
Chain 11155111 - Leg 1 (ERC20 approval, slippage capture): PASS
Chain 11155111 - Leg 2 (native ETH input): PASS
Chain 11155111 - Leg 3 (Permit2): PASS
Chain 11155111 - Leg 4 (nonReentrant callback): SKIP
Chain 84532 - Leg 1 (ERC20 approval, slippage capture): PASS
Chain 84532 - Leg 2 (native ETH input): PASS
Chain 84532 - Leg 3 (Permit2): PASS
Chain 84532 - Leg 4 (nonReentrant callback): SKIP
```

## Acceptance criteria check

| #   | Criterion                                                                                           | Result                                                                                                                                                                                                  |
| --- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Script exists; `forge build` is clean; `forge fmt --check` exits 0                                  | PASS                                                                                                                                                                                                    |
| 2   | `forge script ... 11155111 ... --broadcast` exits 0; legs 1-3 broadcast (leg 4 SKIP)                | PASS                                                                                                                                                                                                    |
| 2   | `forge script ... 84532 ... --broadcast` exits 0; legs 1-3 broadcast (leg 4 SKIP)                   | PASS                                                                                                                                                                                                    |
| 3   | Evidence records per-chain per-leg tx URL + `Swap` fields + PASS/SKIP/FAIL                          | PASS                                                                                                                                                                                                    |
| 4   | `Swap` invariants (slippage floor, fee match, leg-1 positive slippage > 0, Permit2 nonce semantics) | PASS — every leg's broadcast simulation passed in-script `require` checks; no broadcast would reach the chain otherwise. Permit2 nonce semantics covered by source-level unit test (see Sepolia notes). |
| 5   | nonReentrant leg either reverts on callback token or SKIP documented                                | SKIP — see "Skip rationale"                                                                                                                                                                             |
| 6   | New code only `script/SwapTestnetE2E.s.sol` + `script/lib/*.sol` + this file                        | PASS                                                                                                                                                                                                    |
| 7   | `git status` clean outside the above                                                                | PASS — pre-existing T5A diffs (`foundry.toml`, `deployments/11155111.json`) precede this task and are not modified by it                                                                                |

Once both chain tables are filled, set the top-of-file `STATUS:` line to
`PASS` (or `INCONCLUSIVE` with a reason if any leg goes `FAIL` / `SKIP`
beyond the documented leg-4 skip).
