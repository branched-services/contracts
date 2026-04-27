// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// Test-only file that forces forge to compile Permit2.sol so its deployed bytecode
// is available via `vm.getDeployedCode("Permit2.sol:Permit2")` in setup helpers.
// Permit2 itself pins `pragma 0.8.17`, so this file uses a caret range that
// overlaps; foundry's auto-detect picks 0.8.17 to satisfy both.
import { Permit2 } from "permit2/Permit2.sol";
