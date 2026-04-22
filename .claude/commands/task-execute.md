---
description: Execute a single task from a phase file (Foundry/Solidity)
---

Execute this task immediately. Do not summarize -- just do it.

You are a coding agent working on the **contracts** repo (Foundry / Solidity 0.8.24). Implement exactly one task and exit.

## ARGUMENTS

$ARGUMENTS

Format: `<task-id> <phase-id>` -- always provided by the caller.

## STEP 1: LOAD AND VALIDATE

```bash
cat .workflow/tasks/active/${PHASE_ID}/_phase.json
cat .workflow/tasks/active/${PHASE_ID}/${TASK_ID}.json
```

- **Phase/task not found** -- STOP
- **Task already `passing: true`** -- report and exit
- **Prerequisites not met** (any prerequisite task file is not `passing: true`) -- STOP
- **`review_feedback` non-empty** -- RETRY. Previous attempt's code is already merged. The post-task review found these issues; fix ONLY those. Do not rewrite unrelated code.

Also read the spec referenced by `_phase.json`'s `spec` field and any `research` entries. Tasks in this repo are spec-anchored: acceptance criteria grep for exact error names, event field order, and constants defined in the spec. Treat the spec as the source of truth when code, task, and spec disagree.

## STEP 2: IMPLEMENT

**2.1 Tool discipline.** Use the Grep tool (not `bash grep/rg`) and Glob tool (not `bash find/ls`) for code navigation. Use the Agent tool with `subagent_type=Explore` for broad exploration that would otherwise take >10 sequential search calls. Do not re-read files already read in this session unless you modified them.

**2.2 Execute** the `steps` array from the task definition in order.

**2.3 Conventions** (enforced in CI via `forge fmt --check` and Slither):
- Every new `.sol` file starts with `// SPDX-License-Identifier: BUSL-1.1` and `pragma solidity ^0.8.24;`
- Imports use remappings from `remappings.txt` (`forge-std/`, `@openzeppelin/contracts/`, `@weiroll/`, `solmate/`); never use relative paths to `dependencies/`
- Reuse existing fixtures before writing new ones:
  - `test/mocks/AdversarialTokens.sol` (fee-on-transfer, rebasing, callback, false-returning)
  - `test/mocks/MockDEX.sol`
  - `test/mocks/ReentrantReceiver.sol`
  - `test/helpers/WeirollTestHelper.sol`
- `foundry.toml` is canonical: solc 0.8.24, optimizer 200 runs, fuzz=256, invariant runs=256 depth=15, fmt line_length=120
- Architecture context lives in `CLAUDE.md` at the repo root -- consult it before introducing new top-level abstractions

**2.4 Verify ALL acceptance criteria.** Run the exact greps / forge commands named in the task. If the task lists a criterion like `grep -n 'error Paused' src/Router.sol returns 1 match`, run that grep and confirm. For `[manual]` criteria, inspect the relevant file/test body and state the observation in `implementation_notes`.

Canonical Forge checks (run whichever apply to this task):

| Intent                          | Command                                                                 |
| ------------------------------- | ----------------------------------------------------------------------- |
| Compile                         | `forge build`                                                           |
| Compile without tests           | `forge build --skip test`                                               |
| Full test suite                 | `forge test -vvv`                                                       |
| Target a file                   | `forge test --match-path test/Router.t.sol -vvv`                        |
| Target a contract               | `forge test --match-contract RouterTest -vvv`                           |
| Target a single test            | `forge test --match-test test_SwapERC20ToERC20 -vvv`                    |
| Fuzz + invariant                | `forge test --match-path test/Router.Invariant.t.sol`                   |
| Format check                    | `forge fmt --check`                                                     |
| Format in place                 | `forge fmt`                                                             |
| Storage layout                  | `forge inspect ExecutionProxy storage-layout`                           |
| Bytecode size                   | `forge inspect ExecutionProxy bytecode \| wc -c`                         |
| ABI / selectors                 | `forge inspect Router abi` / `forge inspect Router methodIdentifiers`   |
| Deploy-script dry build         | `forge build` (compiles `script/` too)                                  |
| Deploy-script preview           | `forge script script/DeployCreate3.s.sol --sig 'preview()'`             |

If a test or build fails, fix the cause. Do not skip, comment out, or `vm.skip` tests to make the suite green.

## STEP 3: COMMIT

Use the `commit` field from the task definition verbatim as the subject. Include `${TASK_ID}` in the commit body.

```bash
git add <changed files>
git commit -m "$(cat <<'EOF'
<task.commit>

${TASK_ID}
EOF
)"
```

Then update the task file: set `passing: true` and populate `implementation_notes` with a 1-3 sentence summary plus the commit hash. Commit that separately:

```bash
git add ".workflow/tasks/active/${PHASE_ID}/${TASK_ID}.json"
git commit -m "chore: mark ${TASK_ID} as passing in phase file"
```

Never add `Co-Authored-By` trailers or AI attribution lines.

## STEP 4: EXIT

Report and exit. Do not continue to other tasks.

```
## Task Complete: <task-id>

**Phase:** <phase-name>
**Commit:** <commit-hash>
**Summary:** <1-2 sentences>
```

## CRITICAL RULES

1. **SINGLE TASK** -- Implement exactly one task and exit. No loop.
2. **SPEC IS SOURCE OF TRUTH** -- When the spec, task, and existing code disagree, defer to the spec. Flag the conflict in `implementation_notes` rather than silently reconciling.
3. **RESPECT DEPENDENCIES** -- Never skip prerequisites.
4. **VERIFY ALL CRITERIA** -- Each `[auto]` criterion runs its grep/forge command; each `[manual]` criterion gets an observation recorded.
5. **USE TASK COMMIT MESSAGES** -- From the task definition, verbatim.
6. **CLEAN STATE** -- `forge build` and the relevant `forge test` target must both pass before commit.
7. **NO INCOMPLETE IMPLEMENTATIONS** -- No stubs, TODOs, placeholders, mock-only implementations in `src/`. Test-only mocks under `test/mocks/` are fine. Every line in `src/` is production-ready.
8. **NO SKIPPED TESTS** -- Do not use `vm.skip`, rename to `_test_`, or comment out failing tests to pass acceptance. Fix the cause.

## IF BLOCKED

**STOP immediately. Do NOT commit incomplete code.** Exit with:
1. **Problem** -- What is blocking
2. **Task Context** -- Which task, which step
3. **Attempted** -- Approaches tried
4. **Paths Forward** -- 3-5 options with trade-offs
5. **Impact** -- What else is blocked by this (which downstream tasks depend on this one)
