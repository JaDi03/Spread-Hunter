// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BridgeDeploy} from "../../script/BridgeDeploy.s.sol";
import {Testnet} from "../../script/config/Testnet.sol";
import {HuntToken} from "../../src/token/HuntToken.sol";
import {TokenBridge} from "../../src/token/TokenBridge.sol";
import {BridgeReactive} from "../../src/token/BridgeReactive.sol";
import {MockSystem} from "../spike/Spike.t.sol";

contract BridgeDeployTest is Test {
    BridgeDeploy internal script;
    address internal deployer;

    function setUp() public {
        // with no key in the script, forge broadcasts from the --sender / --account address, tx.origin in tests
        deployer = tx.origin;
        vm.deal(deployer, 10 ether);
        vm.etch(Testnet.LASNA_SYSTEM, address(new MockSystem()).code);
        vm.etch(Testnet.BASE_SEPOLIA_CALLBACK_PROXY, address(new MockSystem()).code);
        vm.etch(Testnet.UNICHAIN_SEPOLIA_CALLBACK_PROXY, address(new MockSystem()).code);
        script = new BridgeDeploy();
    }

    function test_fullSequence_wiresEverything() public {
        vm.chainId(Testnet.LASNA);
        BridgeReactive rc = script.reactive(1 ether);

        vm.chainId(Testnet.BASE_SEPOLIA);
        (HuntToken baseToken, TokenBridge baseBridge) = script.pair(address(rc), 500 ether, 0.01 ether);
        vm.chainId(Testnet.UNICHAIN_SEPOLIA);
        (HuntToken uniToken, TokenBridge uniBridge) = script.pair(address(rc), 500 ether, 0.01 ether);

        vm.chainId(Testnet.LASNA);
        script.link(address(rc), address(baseBridge), address(uniBridge));

        assertEq(rc.owner(), deployer);
        assertEq(rc.chainA(), Testnet.BASE_SEPOLIA);
        assertEq(rc.chainB(), Testnet.UNICHAIN_SEPOLIA);
        assertEq(rc.bridgeA(), address(baseBridge));
        assertEq(rc.bridgeB(), address(uniBridge));
        assertEq(address(rc).balance, 1 ether);

        _checkPair(baseToken, baseBridge, rc, Testnet.BASE_SEPOLIA_CALLBACK_PROXY, Testnet.UNICHAIN_SEPOLIA);
        _checkPair(uniToken, uniBridge, rc, Testnet.UNICHAIN_SEPOLIA_CALLBACK_PROXY, Testnet.BASE_SEPOLIA);
    }

    function _checkPair(HuntToken token, TokenBridge bridge, BridgeReactive rc, address proxy, uint256 peer)
        internal
        view
    {
        assertEq(token.owner(), deployer);
        assertEq(token.balanceOf(deployer), 500 ether);
        assertEq(token.bridge(), address(bridge));
        assertEq(address(bridge.token()), address(token));
        assertEq(bridge.owner(), deployer);
        assertEq(bridge._CALLBACK_SENDER(), address(rc));
        assertEq(address(bridge._SERVICE_PROVIDER()), proxy);
        assertEq(bridge.peerChainId(), peer);
        assertTrue(bridge.operators(deployer));
        assertEq(address(bridge).balance, 0.01 ether);
    }

    function test_steps_rejectWrongChain() public {
        vm.chainId(Testnet.BASE_SEPOLIA);
        vm.expectRevert(abi.encodeWithSelector(BridgeDeploy.WrongChain.selector, Testnet.BASE_SEPOLIA));
        script.reactive(0);
        vm.expectRevert(abi.encodeWithSelector(BridgeDeploy.WrongChain.selector, Testnet.BASE_SEPOLIA));
        script.link(address(1), address(2), address(3));

        vm.chainId(Testnet.LASNA);
        vm.expectRevert(abi.encodeWithSelector(Testnet.UnknownChain.selector, Testnet.LASNA));
        script.pair(address(1), 1, 0);
    }

    function test_peerChain_pairsBaseAndUnichainOnly() public {
        assertEq(Testnet.peerChain(Testnet.BASE_SEPOLIA), Testnet.UNICHAIN_SEPOLIA);
        assertEq(Testnet.peerChain(Testnet.UNICHAIN_SEPOLIA), Testnet.BASE_SEPOLIA);
        vm.expectRevert(abi.encodeWithSelector(Testnet.UnknownChain.selector, Testnet.LASNA));
        this.peerOf(Testnet.LASNA);
    }

    function peerOf(uint256 chainId) external pure returns (uint256) {
        return Testnet.peerChain(chainId);
    }
}
