// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SpikeDeploy} from "../../script/SpikeDeploy.s.sol";
import {Testnet} from "../../script/config/Testnet.sol";
import {SpikeEmitter} from "../../src/spike/SpikeEmitter.sol";
import {SpikeReactive} from "../../src/spike/SpikeReactive.sol";
import {SpikeCallback} from "../../src/spike/SpikeCallback.sol";
import {MockSystem} from "../utils/MockSystem.sol";

contract SpikeDeployTest is Test {
    SpikeDeploy internal script;
    address internal deployer;

    function setUp() public {
        // with no key in the script, forge broadcasts from the --sender / --account address, tx.origin in tests
        deployer = tx.origin;
        vm.deal(deployer, 10 ether);
        vm.etch(Testnet.LASNA_SYSTEM, address(new MockSystem()).code);
        vm.etch(Testnet.BASE_SEPOLIA_CALLBACK_PROXY, address(new MockSystem()).code);
        script = new SpikeDeploy();
    }

    function test_fullSequence_wiresContractsAndFunds() public {
        vm.chainId(Testnet.BASE_SEPOLIA);
        SpikeEmitter emitter = script.emitter();

        vm.chainId(Testnet.LASNA);
        SpikeReactive rc = script.reactive(address(emitter), 5, 1 ether);

        vm.chainId(Testnet.BASE_SEPOLIA);
        SpikeCallback cb = script.callback(address(rc), 0.01 ether);

        vm.chainId(Testnet.LASNA);
        script.link(address(rc), address(cb));

        assertEq(emitter.owner(), deployer);
        assertEq(rc.owner(), deployer);
        assertEq(cb.owner(), deployer);
        assertEq(rc.originEmitter(), address(emitter));
        assertEq(rc.originChainId(), Testnet.BASE_SEPOLIA);
        assertEq(rc.destinationChainId(), Testnet.BASE_SEPOLIA);
        assertEq(rc.threshold(), 5);
        assertEq(rc.callbackContract(), address(cb));
        assertEq(cb._CALLBACK_SENDER(), address(rc));
        assertEq(address(rc).balance, 1 ether);
        assertEq(address(cb).balance, 0.01 ether);

        vm.chainId(Testnet.BASE_SEPOLIA);
        vm.expectEmit(address(emitter));
        emit SpikeEmitter.Ping(7, block.timestamp);
        script.ping(address(emitter), 7);
    }

    function test_eachStep_rejectsWrongChain() public {
        vm.chainId(Testnet.LASNA);
        vm.expectRevert(abi.encodeWithSelector(SpikeDeploy.WrongChain.selector, Testnet.BASE_SEPOLIA, Testnet.LASNA));
        script.emitter();

        vm.chainId(Testnet.BASE_SEPOLIA);
        vm.expectRevert(abi.encodeWithSelector(SpikeDeploy.WrongChain.selector, Testnet.LASNA, Testnet.BASE_SEPOLIA));
        script.reactive(address(1), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(SpikeDeploy.WrongChain.selector, Testnet.LASNA, Testnet.BASE_SEPOLIA));
        script.link(address(1), address(2));

        vm.chainId(Testnet.LASNA);
        vm.expectRevert(abi.encodeWithSelector(SpikeDeploy.WrongChain.selector, Testnet.BASE_SEPOLIA, Testnet.LASNA));
        script.callback(address(1), 0);

        vm.expectRevert(abi.encodeWithSelector(SpikeDeploy.WrongChain.selector, Testnet.BASE_SEPOLIA, Testnet.LASNA));
        script.ping(address(1), 0);
    }

    function test_callbackProxy_knownAndUnknownChains() public {
        assertEq(Testnet.callbackProxy(Testnet.BASE_SEPOLIA), Testnet.BASE_SEPOLIA_CALLBACK_PROXY);
        assertEq(Testnet.callbackProxy(Testnet.UNICHAIN_SEPOLIA), Testnet.UNICHAIN_SEPOLIA_CALLBACK_PROXY);
        vm.expectRevert(abi.encodeWithSelector(Testnet.UnknownChain.selector, 1));
        this.proxyOf(1);
    }

    function proxyOf(uint256 chainId) external pure returns (address) {
        return Testnet.callbackProxy(chainId);
    }
}
