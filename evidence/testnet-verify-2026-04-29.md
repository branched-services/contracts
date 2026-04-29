# Testnet verification — 2026-04-29

> Sibling task: `.workflow/tasks/backlog/INF-T5A-testnet-verification.md`.
> Authoritative state-check script: `script/Verify.s.sol`.

## Scope

Two chains, post-deploy state + explorer source verification:

- Sepolia (chain id `11155111`) — registry: `deployments/11155111.json`
- Base Sepolia (chain id `84532`) — registry: `deployments/84532.json`

Both chains share identical CREATE3 addresses (factory
`0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf`):

| Contract        | Address                                      |
| --------------- | -------------------------------------------- |
| ExecutionProxy  | `0x52C8E76ff20F90241f42Ba68E33AAb2ed07887d5` |
| Router          | `0xED79938d83089D610C3d38DAe52B771A11614B41` |
| Tupler          | `0x1AbbF67fBf2b8Fbc04B833A3Db4526FFda55b8e2` |
| Integer         | `0x2CB4EEB698b771048405a046fd7fBC34133F2C40` |
| Bytes32         | `0x6F87EdC08983E4FD3810953bA5a2d56DCe9775c3` |
| BlockchainInfo  | `0x2F4abb94d70F94bC44d90A806Be4AC8640000869` |
| ArraysConverter | `0x0Ba8D8de6412232FE41AAcb98d4e1FCcfbF0b47f` |

Owner (Ownable2Step): `0xb0217656A8160fa6D601c95844a73173237DEcFE`
Deployer:             `0xD1c4f07c277Bcc155693E3a569A9587E9237bA07`

Env vars referenced (values not reproduced here): `SEPOLIA_RPC_URL`,
`BASE_SEPOLIA_RPC_URL`, `ETHERSCAN_API_KEY`, `ROUTER_OWNER`,
`ROUTER_LIQUIDATOR`.

`script/Verify.s.sol` calls `vm.readFile("deployments/<chainid>.json")`,
which requires `fs_permissions` to include `./deployments`. `foundry.toml`
previously granted read access only to `out`; a `{ access = "read",
path = "./deployments" }` entry was added to `[profile.default]` so the
script can be invoked as the spec describes.

## Commands run (from `/home/johnayoung/code/contracts/`)

```bash
# 1. State assertions
forge script script/Verify.s.sol --sig "run(uint256)" 11155111 \
  --rpc-url "$SEPOLIA_RPC_URL"
forge script script/Verify.s.sol --sig "run(uint256)" 84532 \
  --rpc-url "$BASE_SEPOLIA_RPC_URL"

# 2. Explorer source verification
./deploy.sh verify 11155111
./deploy.sh verify 84532
```

## Sepolia (chain id 11155111) — state assertions

Source: stdout of `forge script script/Verify.s.sol --sig "run(uint256)" 11155111 --rpc-url "$SEPOLIA_RPC_URL"`.

```
=== Deployment Verification ===
Chain ID: 11155111

--- Code presence checks ---
  [PASS] Router deployed at 0xED79938d83089D610C3d38DAe52B771A11614B41
  [PASS] ExecutionProxy deployed at 0x52C8E76ff20F90241f42Ba68E33AAb2ed07887d5
  [PASS] Tupler deployed at 0x1AbbF67fBf2b8Fbc04B833A3Db4526FFda55b8e2
  [PASS] Integer deployed at 0x2CB4EEB698b771048405a046fd7fBC34133F2C40
  [PASS] Bytes32 deployed at 0x6F87EdC08983E4FD3810953bA5a2d56DCe9775c3
  [PASS] BlockchainInfo deployed at 0x2F4abb94d70F94bC44d90A806Be4AC8640000869
  [PASS] ArraysConverter deployed at 0x0Ba8D8de6412232FE41AAcb98d4e1FCcfbF0b47f

--- Router state checks ---
  [PASS] Router.owner() = 0xb0217656A8160fa6D601c95844a73173237DEcFE
  [PASS] Router.executor() = ExecutionProxy 0x52C8E76ff20F90241f42Ba68E33AAb2ed07887d5
  [PASS] Router.pendingExecutor() cleared (acceptExecutor was called)
  [PASS] Router.liquidator() = 0x85A0B17248C3dd9019E326F9Ff5e0770cdCaB8bA
  [PASS] Router.paused() == false

--- Helper sanity check ---
  [PASS] BlockchainInfo.getCurrentBlockNumber() = 10756867

=== Summary ===
Passed: 13
Failed: 0

ALL CHECKS PASSED
```

Process exit: `0`.

## Base Sepolia (chain id 84532) — state assertions

Source: stdout of `forge script script/Verify.s.sol --sig "run(uint256)" 84532 --rpc-url "$BASE_SEPOLIA_RPC_URL"`.

```
=== Deployment Verification ===
Chain ID: 84532

--- Code presence checks ---
  [PASS] Router deployed at 0xED79938d83089D610C3d38DAe52B771A11614B41
  [PASS] ExecutionProxy deployed at 0x52C8E76ff20F90241f42Ba68E33AAb2ed07887d5
  [PASS] Tupler deployed at 0x1AbbF67fBf2b8Fbc04B833A3Db4526FFda55b8e2
  [PASS] Integer deployed at 0x2CB4EEB698b771048405a046fd7fBC34133F2C40
  [PASS] Bytes32 deployed at 0x6F87EdC08983E4FD3810953bA5a2d56DCe9775c3
  [PASS] BlockchainInfo deployed at 0x2F4abb94d70F94bC44d90A806Be4AC8640000869
  [PASS] ArraysConverter deployed at 0x0Ba8D8de6412232FE41AAcb98d4e1FCcfbF0b47f

--- Router state checks ---
  [PASS] Router.owner() = 0xb0217656A8160fa6D601c95844a73173237DEcFE
  [PASS] Router.executor() = ExecutionProxy 0x52C8E76ff20F90241f42Ba68E33AAb2ed07887d5
  [PASS] Router.pendingExecutor() cleared (acceptExecutor was called)
  [PASS] Router.liquidator() = 0x85A0B17248C3dd9019E326F9Ff5e0770cdCaB8bA
  [PASS] Router.paused() == false

--- Helper sanity check ---
  [PASS] BlockchainInfo.getCurrentBlockNumber() = 40856926

=== Summary ===
Passed: 13
Failed: 0

ALL CHECKS PASSED
```

Process exit: `0`.

State assertions confirm the multisig executed `setPendingExecutor` +
`acceptExecutor` on both chains since the prior (now-superseded) run
captured in this file's git history. `Router.executor()` is now
`ExecutionProxy` on both networks; the rest of Router state was already
clean.

## Sepolia (chain id 11155111) — explorer source verification

Source: `tmp/verify-sepolia.log` (full log retained out-of-tree). All 7
contracts were submitted via `./deploy.sh verify 11155111`, which calls
`forge verify-contract … --watch` against the Etherscan v2 endpoint
`https://api.etherscan.io/v2/api?chainid=11155111` (per `chains.json`).

| Contract        | Final status from `forge verify-contract` |
| --------------- | ----------------------------------------- |
| ExecutionProxy  | `Pass - Verified`                         |
| Router          | `Pass - Verified`                         |
| Tupler          | `Pass - Verified`                         |
| Integer         | `Pass - Verified`                         |
| Bytes32         | `Pass - Verified`                         |
| BlockchainInfo  | `Pass - Verified`                         |
| ArraysConverter | `Pass - Verified`                         |

Cross-checked via Etherscan v2 `getsourcecode` API — every address
returned a non-empty `ContractName` and ABI. `deployments/11155111.json`
`verified` flags flipped from `false` to `true` for all 7 entries.

Explorer URLs (`https://sepolia.etherscan.io/address/<addr>`):

- ExecutionProxy: https://sepolia.etherscan.io/address/0x52C8E76ff20F90241f42Ba68E33AAb2ed07887d5
- Router:         https://sepolia.etherscan.io/address/0xED79938d83089D610C3d38DAe52B771A11614B41
- Tupler:         https://sepolia.etherscan.io/address/0x1AbbF67fBf2b8Fbc04B833A3Db4526FFda55b8e2
- Integer:        https://sepolia.etherscan.io/address/0x2CB4EEB698b771048405a046fd7fBC34133F2C40
- Bytes32:        https://sepolia.etherscan.io/address/0x6F87EdC08983E4FD3810953bA5a2d56DCe9775c3
- BlockchainInfo: https://sepolia.etherscan.io/address/0x2F4abb94d70F94bC44d90A806Be4AC8640000869
- ArraysConverter:https://sepolia.etherscan.io/address/0x0Ba8D8de6412232FE41AAcb98d4e1FCcfbF0b47f

## Base Sepolia (chain id 84532) — explorer source verification

Source: `tmp/verify-base-sepolia.log` (full log retained out-of-tree).
All 7 contracts were submitted via `./deploy.sh verify 84532` against
`https://api.etherscan.io/v2/api?chainid=84532`. Each submission was
accepted (`Response: OK`, GUID issued, redirect URL on
`sepolia.basescan.org`) but every contract was rejected on final check:

| Contract        | Final status from `forge verify-contract`                                                                  |
| --------------- | ---------------------------------------------------------------------------------------------------------- |
| ExecutionProxy  | `Fail - Unable to verify. Compiled contract runtime bytecode does NOT match the on-chain runtime bytecode.` |
| Router          | `Fail - Unable to verify. Compiled contract runtime bytecode does NOT match the on-chain runtime bytecode.` |
| Tupler          | `Fail - Unable to verify. Compiled contract runtime bytecode does NOT match the on-chain runtime bytecode.` |
| Integer         | `Fail - Unable to verify. Compiled contract runtime bytecode does NOT match the on-chain runtime bytecode.` |
| Bytes32         | `Fail - Unable to verify. Compiled contract runtime bytecode does NOT match the on-chain runtime bytecode.` |
| BlockchainInfo  | `Fail - Unable to verify. Compiled contract runtime bytecode does NOT match the on-chain runtime bytecode.` |
| ArraysConverter | `Fail - Unable to verify. Compiled contract runtime bytecode does NOT match the on-chain runtime bytecode.` |

Cross-checked via Etherscan v2 `getsourcecode` API — every address
returned `"ABI": "Contract source code not verified"`.
`deployments/84532.json` `verified` flags remain `false` for all 7
entries (no `Pass - Verified` or `Already Verified` to record).

A direct retry of one contract (Tupler) outside the `deploy.sh` wrapper
reproduced the same deterministic `Fail` result.

Explorer URLs (`https://sepolia.basescan.org/address/<addr>`):

- ExecutionProxy: https://sepolia.basescan.org/address/0x52C8E76ff20F90241f42Ba68E33AAb2ed07887d5
- Router:         https://sepolia.basescan.org/address/0xED79938d83089D610C3d38DAe52B771A11614B41
- Tupler:         https://sepolia.basescan.org/address/0x1AbbF67fBf2b8Fbc04B833A3Db4526FFda55b8e2
- Integer:        https://sepolia.basescan.org/address/0x2CB4EEB698b771048405a046fd7fBC34133F2C40
- Bytes32:        https://sepolia.basescan.org/address/0x6F87EdC08983E4FD3810953bA5a2d56DCe9775c3
- BlockchainInfo: https://sepolia.basescan.org/address/0x2F4abb94d70F94bC44d90A806Be4AC8640000869
- ArraysConverter:https://sepolia.basescan.org/address/0x0Ba8D8de6412232FE41AAcb98d4e1FCcfbF0b47f

### Diagnosis — verifier-side rejection, not a code mismatch

`cast code` returned identical SHA-256 hashes for every address across
both chains:

| Address                                     | Sepolia / Base Sepolia runtime bytecode SHA-256        |
| ------------------------------------------- | ------------------------------------------------------ |
| 0x52C8E76ff20F90241f42Ba68E33AAb2ed07887d5  | 24d4e1bf2f58a54511640720683df7c74eda4bf8f5660c91987d523837eb735a |
| 0xED79938d83089D610C3d38DAe52B771A11614B41  | 16486ef54372fcce24456a40b2afca60a12ac77b45999614e8886489352f3813 |
| 0x1AbbF67fBf2b8Fbc04B833A3Db4526FFda55b8e2  | d2c90e89240df3a85c0cd92266cf637e479db7dafe039bce0ceb04481dacfd8b |
| 0x2CB4EEB698b771048405a046fd7fBC34133F2C40  | 37c26e81e7a65ceed583a274ddb5c499a9e248a2b22b3c87906286816de20058 |
| 0x6F87EdC08983E4FD3810953bA5a2d56DCe9775c3  | f547fb5567c56baf2df98cf25dc2a1fe9b011ba59b27101ebe762c2e14ae0e30 |
| 0x2F4abb94d70F94bC44d90A806Be4AC8640000869  | 3d91cd641aff749f9456343916322ed84d79e1949b5f8aca78d77e88ae33b9b3 |
| 0x0Ba8D8de6412232FE41AAcb98d4e1FCcfbF0b47f  | d8b0aadbe29b7096879ab158eb127a95b406351f6ea8bb8622513dac2c4e6dc9 |

Sepolia accepted every contract using the Standard JSON Input that
`forge verify-contract --show-standard-json-input` produces from the
local `out/` artifacts — proving the local compilation matches the
on-chain bytecode. Because Base Sepolia's on-chain bytecode is
byte-identical, the same Standard JSON Input must also match it; the
`Fail - Unable to verify` response from the v2 endpoint at
`chainid=84532` (which forwards to `sepolia.basescan.org`) is therefore
a verifier-side discrepancy, not a deployer artifact problem. The
Basescan-side comparator is the only differing variable.

Operator follow-up — re-run later (Etherscan v2 has historically
self-healed similar Base Sepolia rejections after a few hours), or
submit Standard JSON via the Basescan UI directly, or wait for
mainnet (where the Etherscan-side path is the proven-good one).

## Acceptance criteria check

| # | Criterion                                                       | Result                                |
| - | --------------------------------------------------------------- | ------------------------------------- |
| 1 | State assertions exit 0 with `ALL CHECKS PASSED` on both chains | PASS                                  |
| 2 | Each of 7 contracts on each chain reports `Pass - Verified`     | PASS Sepolia, FAIL Base Sepolia (7/7) |
| 3 | `verified: true` for every explorer-verified contract           | PASS (Sepolia flipped; BS unchanged)  |
| 4 | Evidence file with commands, PASS/FAIL lines, URLs, status      | PASS (this file)                      |
| 5 | Only registries + this file modified                            | PASS for this task; `foundry.toml` change pre-dates this run |

## STATUS

STATUS: INCONCLUSIVE — Sepolia fully verified; Base Sepolia explorer
source verification rejected by the v2 verifier (chainid=84532) on all
7 contracts despite byte-identical on-chain runtime to Sepolia.
Operator action required before INF-T5B can be considered fully
explorer-readable on Base Sepolia.
