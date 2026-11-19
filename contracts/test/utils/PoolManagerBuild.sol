// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// compiles Uniswap's PoolManager with the exact compiler it pins, so tests deploy the real contract
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
