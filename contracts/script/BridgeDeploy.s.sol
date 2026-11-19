// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {HuntToken} from "../src/token/HuntToken.sol";
import {TokenBridge} from "../src/token/TokenBridge.sol";
import {BridgeReactive} from "../src/token/BridgeReactive.sol";
import {Testnet} from "./config/Testnet.sol";

/// @title BridgeDeploy
/// @notice Deploys the HUNT bridge, one step per call, each against its own RPC.
/// Order: reactive (Lasna) -> pair (Base Sepolia) -> pair (Unichain Sepolia) -> link (Lasna).
/// The bridges need the reactive contract's address at deploy, so it always goes first.
contract BridgeDeploy is Script {
    error WrongChain(uint256 actual);

    /// @param funding lREACT sent to the reactive contract to pay for reactions and callbacks.
    function reactive(uint256 funding) external returns (BridgeReactive deployed) {
        if (block.chainid != Testnet.LASNA) revert WrongChain(block.chainid);
        vm.startBroadcast();
        deployed = new BridgeReactive{value: funding}(Testnet.BASE_SEPOLIA, Testnet.UNICHAIN_SEPOLIA);
        vm.stopBroadcast();
        console.log("BRIDGE_REACTIVE=%s", address(deployed));
    }

    /// @param reactiveAddr BridgeReactive on Lasna, the only sender the bridge accepts mints from.
    /// @param initialSupply HUNT minted to the deployer on this chain for pool liquidity.
    /// @param funding ETH sent to the bridge to pay the proxy for delivered mints.
    function pair(address reactiveAddr, uint256 initialSupply, uint256 funding)
        external
        returns (HuntToken token, TokenBridge bridge)
    {
        address proxy = Testnet.callbackProxy(block.chainid);
        uint256 peer = Testnet.peerChain(block.chainid);
        vm.startBroadcast();
        token = new HuntToken(initialSupply);
        bridge = new TokenBridge{value: funding}(IPayable(payable(proxy)), reactiveAddr, token, peer);
        token.setBridge(address(bridge));
        bridge.setOperator(bridge.owner(), true);
        vm.stopBroadcast();
        console.log("HUNT_TOKEN=%s", address(token));
        console.log("TOKEN_BRIDGE=%s", address(bridge));
    }

    /// @param baseBridge TokenBridge on Base Sepolia; @param uniBridge TokenBridge on Unichain Sepolia.
    function link(address reactiveAddr, address baseBridge, address uniBridge) external {
        if (block.chainid != Testnet.LASNA) revert WrongChain(block.chainid);
        vm.startBroadcast();
        BridgeReactive(payable(reactiveAddr)).setBridges(baseBridge, uniBridge);
        vm.stopBroadcast();
    }
}
