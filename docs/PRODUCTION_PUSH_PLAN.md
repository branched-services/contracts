# First production push — Router + ExecutionProxy

> **Status (2026-04-28):** Steps 1–3 complete in working tree (uncommitted). Steps 4–8 require operator wallet / Safe access.

## Context

The Router + pure-VM ExecutionProxy phase (INF-0001 → INF-0013) is functionally complete: `forge build` clean, `forge test` 103/103 PASS (93 reviewed + 10 Permit2 added after review), `forge fmt --check` clean, bytecode under EIP-170. Internal review at SHA `dddfb0f` produced REVIEW.md (0 Critical/High/Medium, 7 Low, 6 Info). User confirmed: no external audit will be done, rollout is testnets → mainnets, production Safe addresses are provisioned.

Two material drifts since the reviewed SHA:
- **Permit2 entry points** (`swapPermit2`, `swapMultiPermit2`) added in `2e25ab0` — 155 LOC in `src/Router.sol` plus 608-line test. **Not in REVIEW.md scope.**
- Cosmetic comment scrub in `4f08103`.

No prior production deployments (`deployments/` empty save schema; `broadcast/` only has a dry-run).

## Risk acknowledgement (no external audit)

User explicitly chose to deploy without external audit. Mitigations: (a) Permit2 paths exercised by tests against the real canonical Permit2 bytecode etched at its mainnet address, (b) testnet soak before mainnet, (c) Slither run pre-deploy (clean, see `evidence/slither-triage.md`), (d) two-step executor wiring keeps the Router inert until the multisig calls `acceptExecutor()`, (e) owner can `pause()` and the liquidator can `transferRouterFunds`/`swapRouterFunds` even while paused.

## Steps

### 1. Pre-flight code hygiene — DONE

- **LOW-007** — replaced bare `require` in `swapRouterFunds` with `InsufficientRouterBalance` custom error.
- **INFO-001** — removed dead `error NotImplemented();`.
- **INFO-005** — added NatSpec on `swapRouterFunds` and `transferRouterFunds` documenting the deliberate `whenNotPaused` omission.
- **Spec sync** — moved Permit2 from "Out of Scope / deferred" into in-scope in `.workflow/specs/00001-FEATURE-router-and-fee-model.md`; decisions-log row updated.
- **Untracked review dir** — pending: `git add .workflow/tasks/active/router-and-fee-model/reviews/`.

Skipped LOW-003 / 004 / 005 / 006 untested-revert-path gaps for v1 — test gaps, not behavior bugs; underlying logic is otherwise covered.

### 2. Static analysis — DONE

Ran via `uvx --from slither-analyzer slither src/ --solc-remaps "..."` (slither 0.11.5). 14 medium/high findings against `src/`, all triaged false-positive (reentrancy guarded by `nonReentrant`; deliberate pro-rata rounding in `_splitFeeProRata`; default-init locals; zero-amount short-circuit).

Evidence:
- `evidence/slither-full.txt` — full output (387 lines, 77 raw results)
- `evidence/slither-triage.md` — per-finding verdict

Re-run command for future deploys:

```bash
uvx --from slither-analyzer slither src/ \
  --solc-remaps "@openzeppelin/contracts/=dependencies/@openzeppelin-contracts-5.5.0/contracts/ \
                 @weiroll/=dependencies/weiroll-1.0.0/contracts/ \
                 forge-std/=dependencies/forge-std-1.12.0/src/ \
                 permit2/=dependencies/permit2-1.0.0/src/ \
                 solmate/=dependencies/solmate-6.8.0/"
```

### 3. Patch `script/Verify.s.sol` — DONE

Rewrote to assert Router state after deploy:
- `Router.owner() == ROUTER_OWNER` env (with `OWNER_ADDRESS` fallback)
- `Router.executor() == ExecutionProxy` (the whole point of post-deploy verification)
- `Router.pendingExecutor() == address(0)` (proves `acceptExecutor()` was called)
- `Router.liquidator() == ROUTER_LIQUIDATOR` env (or non-zero if env unset)
- `Router.paused() == false`

Script now `revert`s on any failure so `./deploy.sh verify <chainid>` exits non-zero on misconfiguration.

### 4. Configure production `.env` — TODO (operator)

Use `.env.example` as the template. Required for deploy:
- `KEYSTORE_ACCOUNT` (Foundry encrypted keystore name; create via `./setup-deployer-wallet.sh`), `DEPLOYER_ADDRESS`
- `ROUTER_OWNER` (Safe multisig per chain — different per chain or shared via cross-chain Safe)
- `ROUTER_LIQUIDATOR`
- `ETH_RPC_URL`, `BASE_RPC_URL`, `SEPOLIA_RPC_URL`, `BASE_SEPOLIA_RPC_URL`
- `ETHERSCAN_API_KEY`
- `SALT_VERSION=v1`

Run `./deploy.sh preview <chainid>` for each chain; verify predicted Router/ExecutionProxy addresses match across all chains (CREATE3 gives identical addresses when salt + deployer match).

### 5. Testnet deploys (Sepolia 11155111, Base Sepolia 84532) — TODO

For each chain:

```bash
./deploy.sh dry-run <chainid>      # simulate
./deploy.sh deploy   <chainid>     # broadcast + write deployments/<chainid>.json
# (multisig submits setPendingExecutor + acceptExecutor if deployer != ROUTER_OWNER)
./deploy.sh verify   <chainid>     # post-deploy assertions
```

Then run a real end-to-end swap on testnet (small ERC20 → ERC20, then native ETH → ERC20) against a known DEX target via a Weiroll path, to exercise: balance-diff accounting, fee skim, slippage cap, Permit2 path, `nonReentrant` guard on a callback token if available.

### 6. Soak — TODO

Hold mainnet for at least 24h after testnets are live, watching for any unexpected reverts or accounting drift.

### 7. Mainnet deploys — Base first, then Ethereum — TODO

Same `dry-run` → `deploy` → multisig wire → `verify` sequence. Order: **Base (8453) first** (cheaper rollback if something is wrong), then **Ethereum (1)**.

Both `setPendingExecutor` and `acceptExecutor` are `onlyOwner` (`src/Router.sol:235-248`), so the multisig submits both txs sequentially — no need for the stateless ExecutionProxy to originate anything.

For each chain:
1. `./deploy.sh dry-run <chainid>`
2. `./deploy.sh deploy <chainid>` — produces `deployments/<chainid>.json`
3. Multisig submits `router.setPendingExecutor(executionProxyAddress)`
4. Multisig submits `router.acceptExecutor()`
5. `./deploy.sh verify <chainid>` — asserts wiring + ownership
6. Source-verify on the explorer (`./deploy.sh verify <chainid>` runs `forge verify-contract`)
7. `git add deployments/<chainid>.json && git commit`

### 8. Final commit + tag — TODO

After both mainnets are deployed and verified:
- `git tag v1.0.0-mainnet` on the deployed SHA
- Push deployment registries (`deployments/1.json`, `deployments/8453.json`, plus testnets) and tag

## Critical files touched

- `src/Router.sol` — step 1 hygiene patches (DONE)
- `script/Verify.s.sol` — Router verification (DONE)
- `.workflow/specs/00001-FEATURE-router-and-fee-model.md` — Permit2 scope sync (DONE)
- `.env` — production config (operator, step 4)

## Verification (end-to-end)

- `forge build && forge test && forge fmt --check` — green before each deploy
- Slither — no new High/Medium since pre-flight triage in `evidence/slither-triage.md`
- `./deploy.sh preview 1`, `8453`, `11155111`, `84532` — predicted Router address identical across chains
- After each deploy: `./deploy.sh verify <chainid>` exits 0; logs show all checks PASS, including Router owner / executor / liquidator / paused / pendingExecutor cleared
- One real swap on each testnet using a Weiroll program against a known DEX
- Etherscan/Basescan source verified for Router and ExecutionProxy
