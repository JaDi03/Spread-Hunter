// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {SpikeEmitter} from "../src/spike/SpikeEmitter.sol";
import {SpikeReactive} from "../src/spike/SpikeReactive.sol";
import {SpikeCallback} from "../src/spike/SpikeCallback.sol";
import {Testnet} from "./config/Testnet.sol";

/// @title SpikeDeploy
/// @notice Deploys the loop test across Base Sepolia and Lasna, one step per call, each against its own RPC.
/// Order: emitter (Base) -> reactive (Lasna) -> callback (Base) -> link (Lasna) -> ping (Base).
contract SpikeDeploy is Script {
    error WrongChain(uint256 expected, uint256 actual);

    function emitter() external returns (SpikeEmitter deployed) {
        _requireChain(Testnet.BASE_SEPOLIA);
        vm.startBroadcast();
        deployed = new SpikeEmitter();
        vm.stopBroadcast();
        console.log("SPIKE_EMITTER=%s", address(deployed));
    }

    /// @param emitterAddr SpikeEmitter on Base Sepolia.
    /// @param threshold Minimum ping value forwarded as a callback.
    /// @param funding lREACT sent to the reactive contract to pay for reactions and callbacks.
    function reactive(address emitterAddr, uint256 threshold, uint256 funding)
        external
        returns (SpikeReactive deployed)
    {
        _requireChain(Testnet.LASNA);
        vm.startBroadcast();
        deployed = new SpikeReactive{value: funding}(Testnet.BASE_SEPOLIA, emitterAddr, Testnet.BASE_SEPOLIA, threshold);
        vm.stopBroadcast();
        console.log("SPIKE_REACTIVE=%s", address(deployed));
    }

    /// @param reactiveAddr SpikeReactive on Lasna, the only sender the callback accepts.
    /// @param funding ETH sent to the callback contract to pay the proxy for delivered callbacks.
    function callback(address reactiveAddr, uint256 funding) external returns (SpikeCallback deployed) {
        _requireChain(Testnet.BASE_SEPOLIA);
        vm.startBroadcast();
        deployed =
            new SpikeCallback{value: funding}(IPayable(payable(Testnet.callbackProxy(block.chainid))), reactiveAddr);
        vm.stopBroadcast();
        console.log("SPIKE_CALLBACK=%s", address(deployed));
    }

    function link(address reactiveAddr, address callbackAddr) external {
        _requireChain(Testnet.LASNA);
        vm.startBroadcast();
        SpikeReactive(payable(reactiveAddr)).setCallbackContract(callbackAddr);
        vm.stopBroadcast();
    }

    function ping(address emitterAddr, uint256 value) external {
        _requireChain(Testnet.BASE_SEPOLIA);
        vm.startBroadcast();
        SpikeEmitter(emitterAddr).ping(value);
        vm.stopBroadcast();
    }

    function _requireChain(uint256 expected) private view {
        if (block.chainid != expected) revert WrongChain(expected, block.chainid);
    }
}
