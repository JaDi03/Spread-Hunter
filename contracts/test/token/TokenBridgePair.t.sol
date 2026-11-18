// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {HuntToken} from "../../src/token/HuntToken.sol";
import {TokenBridge} from "../../src/token/TokenBridge.sol";
import {MockSystem} from "../spike/Spike.t.sol";

/// Two bridges, one per chain, with the reactive relay played by the test: a request emitted on one chain is
/// delivered as the callback the reactive contract would send to the other.
contract TokenBridgePairTest is Test {
    uint256 internal constant BASE = 84532;
    uint256 internal constant UNI = 1301;
    bytes32 internal constant REQUESTED = keccak256("BridgeRequested(uint256,address,address,uint256,uint256)");

    MockSystem internal proxy;
    address internal rc = makeAddr("bridgeReactive");
    address internal executor = makeAddr("executor");
    address internal peerExecutor = makeAddr("peerExecutor");

    HuntToken internal baseToken;
    TokenBridge internal baseBridge;
    HuntToken internal uniToken;
    TokenBridge internal uniBridge;

    function setUp() public {
        proxy = new MockSystem();
        vm.chainId(BASE);
        (baseToken, baseBridge) = _deploy(UNI, 500 ether);
        vm.chainId(UNI);
        (uniToken, uniBridge) = _deploy(BASE, 500 ether);
    }

    function _deploy(uint256 peer, uint256 supply) internal returns (HuntToken token, TokenBridge bridge) {
        token = new HuntToken(supply);
        bridge = new TokenBridge(IPayable(payable(address(proxy))), rc, token, peer);
        token.setBridge(address(bridge));
        bridge.setOperator(executor, true);
        token.transfer(executor, 100 ether);
    }

    /// Bridges on `from` (running on `fromChain`) and returns the request fields as the reactive contract reads them.
    function _send(TokenBridge from, uint256 fromChain, uint256 amount)
        internal
        returns (uint256 nonce, address to, uint256 sent)
    {
        vm.chainId(fromChain);
        vm.recordLogs();
        vm.prank(executor);
        from.bridge(peerExecutor, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(from) && logs[i].topics[0] == REQUESTED) {
                nonce = uint256(logs[i].topics[1]);
                to = address(uint160(uint256(logs[i].topics[3])));
                (sent,) = abi.decode(logs[i].data, (uint256, uint256));
                return (nonce, to, sent);
            }
        }
        revert("no BridgeRequested");
    }

    function _deliver(TokenBridge to, uint256 toChain, uint256 srcChain, uint256 nonce, address recipient, uint256 amt)
        internal
    {
        vm.chainId(toChain);
        vm.prank(address(proxy));
        to.mintFromReactive(rc, srcChain, nonce, recipient, amt);
    }

    function test_baseToUnichain_burnsThereMintsHere() public {
        (uint256 nonce, address to, uint256 amount) = _send(baseBridge, BASE, 30 ether);
        _deliver(uniBridge, UNI, BASE, nonce, to, amount);

        assertEq(baseToken.balanceOf(executor), 70 ether);
        assertEq(uniToken.balanceOf(peerExecutor), 30 ether);
        assertEq(baseToken.totalSupply() + uniToken.totalSupply(), 1_000 ether);
    }

    function test_unichainToBase_rejectsDeliveryToTheSourceBridge() public {
        (uint256 nonce, address to, uint256 amount) = _send(uniBridge, UNI, 5 ether);
        // delivering back to the bridge that burned it fails: its peer is Base, not Unichain
        vm.chainId(UNI);
        vm.prank(address(proxy));
        vm.expectRevert(abi.encodeWithSelector(TokenBridge.WrongSourceChain.selector, UNI));
        uniBridge.mintFromReactive(rc, UNI, nonce, to, amount);

        _deliver(baseBridge, BASE, UNI, nonce, to, amount);
        assertEq(baseToken.balanceOf(peerExecutor), 5 ether);
    }

    function test_redeployedSourceBridge_doesNotCollideWithMintedNonces() public {
        (uint256 oldNonce, address to, uint256 amount) = _send(baseBridge, BASE, 10 ether);
        _deliver(uniBridge, UNI, BASE, oldNonce, to, amount);

        vm.chainId(BASE);
        (, TokenBridge newBaseBridge) = _deploy(UNI, 100 ether);
        (uint256 newNonce, address to2, uint256 amount2) = _send(newBaseBridge, BASE, 10 ether);
        assertTrue(newNonce != oldNonce);

        _deliver(uniBridge, UNI, BASE, newNonce, to2, amount2);
        assertEq(uniToken.balanceOf(peerExecutor), 20 ether);
    }

    function test_mintBeforePeerTokenLinked_landsOnRetry() public {
        vm.chainId(UNI);
        HuntToken lateToken = new HuntToken(0);
        TokenBridge lateBridge = new TokenBridge(IPayable(payable(address(proxy))), rc, lateToken, BASE);

        (uint256 nonce, address to, uint256 amount) = _send(baseBridge, BASE, 8 ether);

        vm.chainId(UNI);
        vm.prank(address(proxy));
        vm.expectRevert(HuntToken.NotBridge.selector);
        lateBridge.mintFromReactive(rc, BASE, nonce, to, amount);
        assertFalse(lateBridge.minted(BASE, nonce));

        lateToken.setBridge(address(lateBridge));
        vm.chainId(BASE);
        baseBridge.retry(nonce);
        _deliver(lateBridge, UNI, BASE, nonce, to, amount);
        assertEq(lateToken.balanceOf(peerExecutor), 8 ether);
    }

    /// Total HUNT over both chains never grows, whatever the order of sends and deliveries.
    function testFuzz_supplyAcrossChainsNeverGrows(uint96[4] memory amounts, bool[4] memory baseFirst) public {
        uint256 total = baseToken.totalSupply() + uniToken.totalSupply();
        for (uint256 i; i < 4; ++i) {
            uint256 amount = bound(amounts[i], 1, 20 ether);
            bool fromBase = baseFirst[i];
            (uint256 nonce, address to, uint256 sent) =
                _send(fromBase ? baseBridge : uniBridge, fromBase ? BASE : UNI, amount);
            assertLe(baseToken.totalSupply() + uniToken.totalSupply(), total);

            _deliver(fromBase ? uniBridge : baseBridge, fromBase ? UNI : BASE, fromBase ? BASE : UNI, nonce, to, sent);
            assertEq(baseToken.totalSupply() + uniToken.totalSupply(), total);

            // a second delivery of the same request never mints again
            vm.prank(address(proxy));
            vm.expectRevert();
            (fromBase ? uniBridge : baseBridge).mintFromReactive(rc, fromBase ? BASE : UNI, nonce, to, sent);

            // the peer executor sends it back next round, so balances stay funded
            vm.prank(peerExecutor);
            (fromBase ? uniToken : baseToken).transfer(executor, sent);
        }
        assertEq(baseToken.totalSupply() + uniToken.totalSupply(), total);
    }
}
