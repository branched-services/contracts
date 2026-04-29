# INF-T5A — Testnet verification: Router state + explorer source verification

> Source: `docs/PRODUCTION_PUSH_PLAN.md` Step 5 (verification half).
> Sibling: `INF-T5B-testnet-e2e-swap.md` (the live-broadcast swap leg).

## Goal

After today's testnet deploys (Sepolia 11155111, Base Sepolia 84532), the
Router on each chain must be confirmed wired correctly (executor =
ExecutionProxy, pendingExecutor cleared, owner = multisig, not paused), and
every contract from `chains.json` must be source-verified on its explorer.
Produce `evidence/testnet-verify-2026-04-29.md` capturing pass/fail + tx
links so Step 6 (24h soak) can begin.

## Architectural Context

- The Router uses two-step executor wiring (`src/Router.sol:235-248`).
  Deployer (`0xD1c4f0...`) ≠ owner (`0xb02176...`) on these chains, so
  `DeployCreate3.s.sol` only emits `setPendingExecutor` if deployer ==
  owner — otherwise the multisig must call both `setPendingExecutor` and
  `acceptExecutor`. The user has confirmed both calls are already on-chain
  for both testnets.
- `script/Verify.s.sol` (the Forge state-assertion script) is a separate
  invocation from `./deploy.sh verify` (the bash subcommand that runs
  `forge verify-contract` for explorer source verification). The
  `PRODUCTION_PUSH_PLAN.md` wording at line 81 ("`./deploy.sh verify
  <chainid>` # post-deploy assertions") conflates them — treat them as
  two distinct steps. The state-assertion script must be invoked
  directly.
- Source verification on `verified: false` contracts is required before
  any external integrator can read source from the explorer; see
  `deployments/11155111.json` and `deployments/84532.json` — every
  contract is currently `"verified": false`.
- Evidence convention: there is no existing `evidence/` directory in the
  working tree. Create it; mirror the style of `docs/PRODUCTION_PUSH_PLAN.md`
  — terse, with `path:line` citations and explorer URLs.

## Relevant Files

- `script/Verify.s.sol` — state-assertion script. Read-only; do not modify.
- `deploy.sh` lines 453–528 — `verify <chainid>` subcommand. Read-only.
- `chains.json` — chain configs (RPC env, explorer apiUrl, contracts list).
- `deployments/11155111.json`, `deployments/84532.json` — registries to
  be updated in place: flip `verified: false` → `true` for any contract
  that successfully verified on the explorer.
- `evidence/testnet-verify-2026-04-29.md` — new file you write.
- `.env` — must already contain `SEPOLIA_RPC_URL`, `BASE_SEPOLIA_RPC_URL`,
  `ETHERSCAN_API_KEY`, `ROUTER_OWNER`, `ROUTER_LIQUIDATOR`. Do not edit.

## Reference Implementation

- The verification script's check list is `script/Verify.s.sol:81-153`
  (`verifyRouter`). It emits `[PASS]`/`[FAIL]` lines via `console2.log`
  and reverts if any check fails — capture each line in the evidence
  file.
- The `verify()` bash function pattern is `deploy.sh:453-528`. It reads
  contracts from `chains.json` via `get_contracts`, then for each calls
  `forge verify-contract` with chain-id, verifier-url, api-key, and (for
  Router only) constructor args via `cast abi-encode 'constructor(address,
  address)'`. Use the bash subcommand directly — do not reimplement.

## Constraints

- Use `forge script script/Verify.s.sol --sig "run(uint256)" <chainid>
  --rpc-url $RPC` for the state assertions. No `--broadcast`, no
  `--account` — it is a pure read; the script reverts on failure and the
  process exits non-zero.
- Use `./deploy.sh verify <chainid>` for explorer source verification —
  do not call `forge verify-contract` directly.
- Write the evidence file with absolute commands run, full stdout/stderr
  excerpts (relevant lines only), explorer links, and a final
  PASS/INCONCLUSIVE summary line.
- Update `deployments/<chainid>.json` `verified` flags only for contracts
  whose `forge verify-contract` returned `Pass - Verified` or equivalent.
  If `forge verify-contract` reports "already verified", also flip to
  `true`.
- All commands run from `/home/johnayoung/code/contracts/`.
- Never reveal RPC URLs or API keys in the evidence file. Reference them
  by env var name only.

## Non-Goals

- No source code changes (`src/`, `test/`, `script/` untouched).
- Not running an end-to-end swap — that is INF-T5B.
- Not deploying anything — registries already exist.
- Not modifying `chains.json` or `.env.example`.

## Edge Cases

- If `Verify.s.sol` reports `Router.pendingExecutor not cleared`, the
  multisig step has regressed: STOP, do not flip any `verified` flags,
  and write the evidence file with status `INCONCLUSIVE — multisig
  re-wiring required` so the operator can act. The user has stated this
  shouldn't happen but the script is the source of truth.
- `forge verify-contract` is idempotent; "already verified" responses are
  not failures — record them as PASS.
- The Router constructor args for verification are `(ROUTER_OWNER,
  ROUTER_LIQUIDATOR)` from `.env` (with fallback to registry `owner`,
  see `deploy.sh:496-497`). If those env vars are unset the bash
  fallback already handles it; don't override.
- `chains.json` contracts list is order-sensitive (ExecutionProxy first,
  Router second, then 5 helpers). Verify in registry order.
- Do not run with `--account $KEYSTORE_ACCOUNT` for `Verify.s.sol` — it
  is a pure read; broadcasting is unnecessary and would prompt for the
  keystore password.

## Acceptance Criteria

1. `forge script script/Verify.s.sol --sig "run(uint256)" 11155111 --rpc-url $SEPOLIA_RPC_URL` exits 0 and `console2.log` shows `ALL CHECKS PASSED`. Same for `84532` against `$BASE_SEPOLIA_RPC_URL`.
2. `./deploy.sh verify 11155111` and `./deploy.sh verify 84532` complete; for each of the 7 contracts the explorer reports `Pass - Verified` or `Already Verified`.
3. `deployments/11155111.json` and `deployments/84532.json` show `"verified": true` for every contract that explorer-verified.
4. `evidence/testnet-verify-2026-04-29.md` exists, lists each command, every PASS/FAIL line from the state assertions, an explorer URL per contract per chain, and a final summary line `STATUS: PASS` (or `INCONCLUSIVE` if the pendingExecutor regression case fires).
5. `git status` shows only `deployments/11155111.json`, `deployments/84532.json`, and `evidence/testnet-verify-2026-04-29.md` modified/added — no other files.

## Verification

```bash
cd /home/johnayoung/code/contracts

# 1. State assertions (each must exit 0, both must print "ALL CHECKS PASSED")
forge script script/Verify.s.sol --sig "run(uint256)" 11155111 \
  --rpc-url "$SEPOLIA_RPC_URL"
forge script script/Verify.s.sol --sig "run(uint256)" 84532 \
  --rpc-url "$BASE_SEPOLIA_RPC_URL"

# 2. Explorer source verification (must finish without "verification may
#    have failed" lines, except for already-verified contracts)
./deploy.sh verify 11155111
./deploy.sh verify 84532

# 3. Confirm registries flipped
jq '[.contracts[] | .verified] | all' deployments/11155111.json   # -> true
jq '[.contracts[] | .verified] | all' deployments/84532.json      # -> true

# 4. Confirm evidence written
test -f evidence/testnet-verify-2026-04-29.md && \
  grep -E "^STATUS: (PASS|INCONCLUSIVE)" evidence/testnet-verify-2026-04-29.md

# 5. No untouched files modified
git status --porcelain | grep -vE '^[ AM?] (deployments/(11155111|84532)\.json|evidence/testnet-verify-2026-04-29\.md)$' \
  && echo "FAIL: unexpected files changed" || echo "OK"
```
