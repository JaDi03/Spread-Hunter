// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {HuntToken} from "../../src/token/HuntToken.sol";
import {TokenBridge} from "../../src/token/TokenBridge.sol";
import {BridgeReactive} from "../../src/token/BridgeReactive.sol";
import {MockSystem} from "../spike/Spike.t.sol";

contract BridgeReactiveTest is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 internal constant BASE = 84532;
    uint256 internal constant UNI = 1301;
    uint256 internal constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    MockSystem internal sys;
    MockSystem internal proxy;
    BridgeReactive internal rc;
    HuntToken internal baseToken;
    TokenBridge internal baseBridge;
    HuntToken internal uniToken;
    TokenBridge internal uniBridge;
    address internal executor = makeAddr("executor");
    address internal peerExecutor = makeAddr("peerExecutor");
    address internal stranger = makeAddr("stranger");

    receive() external payable {}

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM));
        proxy = new MockSystem();
        rc = new BridgeReactive(BASE, UNI);

        vm.chainId(BASE);
        (baseToken, baseBridge) = _deployBridge(UNI);
        vm.chainId(UNI);
        (uniToken, uniBridge) = _deployBridge(BASE);
        rc.setBridges(address(baseBridge), address(uniBridge));
    }

    function _deployBridge(uint256 peer) internal returns (HuntToken token, TokenBridge bridge) {
        token = new HuntToken(500 ether);
        bridge = new TokenBridge(IPayable(payable(address(proxy))), address(rc), token, peer);
        token.setBridge(address(bridge));
        bridge.setOperator(executor, true);
        token.transfer(executor, 100 ether);
    }

    /// Runs bridge() on `chainId` and returns the BridgeRequested log as the system contract hands it to react().
    function _requestLog(TokenBridge bridge, uint256 chainId, uint256 amount)
        internal
        returns (IReactive.LogRecord memory rec)
    {
        vm.chainId(chainId);
        vm.recordLogs();
        vm.prank(executor);
        bridge.bridge(peerExecutor, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(bridge) && uint256(logs[i].topics[0]) == rc.BRIDGE_REQUESTED_TOPIC0()) {
                rec.chainId = chainId;
                rec.contractAddress = address(bridge);
                rec.topic0 = uint256(logs[i].topics[0]);
                rec.topic1 = uint256(logs[i].topics[1]);
                rec.topic2 = uint256(logs[i].topics[2]);
                rec.topic3 = uint256(logs[i].topics[3]);
                rec.data = logs[i].data;
                return rec;
            }
        }
        revert("no BridgeRequested");
    }

    /// Delivers callback request `i` the way the proxy does: first argument replaced by the reactive contract.
    function _tryDeliver(uint256 i) internal returns (bool ok, bytes memory ret) {
        ISystemContract.CallbackConfiguration_V_1_0 memory req = sys.request(i);
        bytes memory payload = req.payload;
        bytes32 rcWord = bytes32(uint256(uint160(address(rc))));
        assembly {
            mstore(add(payload, 36), rcWord)
        }
        vm.chainId(req.chainId);
        vm.prank(address(proxy));
        (ok, ret) = req.recipient.call{gas: 1_000_000}(payload);
    }

    function _deliverLast(uint256 destChainId) internal {
        uint256 i = sys.requestCount() - 1;
        assertEq(sys.request(i).chainId, destChainId);
        (bool ok, bytes memory ret) = _tryDeliver(i);
        assertTrue(ok, string(ret));
    }

    // --- setup and access

    function test_constructor_rejectsBadChains() public {
        vm.expectRevert(BridgeReactive.InvalidChains.selector);
        new BridgeReactive(0, UNI);
        vm.expectRevert(BridgeReactive.InvalidChains.selector);
        new BridgeReactive(BASE, 0);
        vm.expectRevert(BridgeReactive.InvalidChains.selector);
        new BridgeReactive(BASE, BASE);
    }

    function test_setBridges_subscribesBothOnceOnlyOwner() public {
        assertEq(sys.subCount(), 2);
        (uint256 c0, address t0, uint256 topic0) = sys.subs(0);
        (uint256 c1, address t1, uint256 topic1) = sys.subs(1);
        assertEq(c0, BASE);
        assertEq(t0, address(baseBridge));
        assertEq(c1, UNI);
        assertEq(t1, address(uniBridge));
        assertEq(topic0, rc.BRIDGE_REQUESTED_TOPIC0());
        assertEq(topic1, rc.BRIDGE_REQUESTED_TOPIC0());
        assertTrue(topic0 != IGNORE);

        vm.expectRevert(BridgeReactive.BridgesAlreadySet.selector);
        rc.setBridges(stranger, stranger);

        BridgeReactive fresh = new BridgeReactive(BASE, UNI);
        vm.expectEmit(address(fresh));
        emit BridgeReactive.BridgesSet(address(baseBridge), address(uniBridge));
        fresh.setBridges(address(baseBridge), address(uniBridge));

        fresh = new BridgeReactive(BASE, UNI);
        vm.prank(stranger);
        vm.expectRevert(BridgeReactive.NotOwner.selector);
        fresh.setBridges(address(baseBridge), address(uniBridge));
        vm.expectRevert(BridgeReactive.ZeroAddress.selector);
        fresh.setBridges(address(0), address(uniBridge));
        vm.expectRevert(BridgeReactive.ZeroAddress.selector);
        fresh.setBridges(address(baseBridge), address(0));
    }

    function test_topicMatchesTheBridgeEvent() public pure {
        assertEq(
            bytes32(uint256(keccak256("BridgeRequested(uint256,address,address,uint256,uint256)"))),
            TokenBridge.BridgeRequested.selector
        );
    }

    function test_react_onlySystem() public {
        IReactive.LogRecord memory rec = _requestLog(baseBridge, BASE, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM));
        rc.react(rec);
    }

    // --- relay

    function test_baseToUnichain_fullLoop() public {
        IReactive.LogRecord memory rec = _requestLog(baseBridge, BASE, 30 ether);
        vm.expectEmit(address(rc));
        emit BridgeReactive.Relayed(BASE, rec.topic1, peerExecutor, 30 ether);
        vm.prank(SYSTEM);
        rc.react(rec);

        ISystemContract.CallbackConfiguration_V_1_0 memory req = sys.request(0);
        assertEq(req.recipient, address(uniBridge));
        assertEq(req.gasLimit, rc.CALLBACK_GAS_LIMIT());
        assertEq(
            req.payload,
            abi.encodeCall(TokenBridge.mintFromReactive, (address(0), BASE, rec.topic1, peerExecutor, 30 ether))
        );

        _deliverLast(UNI);
        assertEq(uniToken.balanceOf(peerExecutor), 30 ether);
        assertEq(baseToken.totalSupply() + uniToken.totalSupply(), 1_000 ether);
    }

    function test_unichainToBase_fullLoop() public {
        IReactive.LogRecord memory rec = _requestLog(uniBridge, UNI, 12 ether);
        vm.prank(SYSTEM);
        rc.react(rec);
        assertEq(sys.request(0).recipient, address(baseBridge));
        _deliverLast(BASE);
        assertEq(baseToken.balanceOf(peerExecutor), 12 ether);
    }

    function test_react_ignoresOtherTopicContractOrChain() public {
        IReactive.LogRecord memory rec = _requestLog(baseBridge, BASE, 1 ether);

        IReactive.LogRecord memory wrongTopic = rec;
        wrongTopic.topic0 = uint256(keccak256("Transfer(address,address,uint256)"));
        IReactive.LogRecord memory wrongContract = _requestLog(baseBridge, BASE, 1 ether);
        wrongContract.contractAddress = stranger;
        // the Base bridge address reported from Unichain is not the Unichain bridge
        IReactive.LogRecord memory wrongChain = _requestLog(baseBridge, BASE, 1 ether);
        wrongChain.chainId = UNI;
        IReactive.LogRecord memory otherChain = _requestLog(baseBridge, BASE, 1 ether);
        otherChain.chainId = 11155111;

        vm.startPrank(SYSTEM);
        rc.react(wrongTopic);
        rc.react(wrongContract);
        rc.react(wrongChain);
        rc.react(otherChain);
        vm.stopPrank();
        assertEq(sys.requestCount(), 0);
    }

    function test_react_beforeBridgesSet_relaysNothing() public {
        BridgeReactive fresh = new BridgeReactive(BASE, UNI);
        IReactive.LogRecord memory rec = _requestLog(baseBridge, BASE, 1 ether);
        rec.contractAddress = address(0);
        vm.prank(SYSTEM);
        fresh.react(rec);
        assertEq(sys.requestCount(), 0);
    }

    function test_react_skipsWrongDestination() public {
        IReactive.LogRecord memory rec = _requestLog(baseBridge, BASE, 1 ether);
        rec.data = abi.encode(uint256(1 ether), uint256(11155111));
        vm.expectEmit(address(rc));
        emit BridgeReactive.Skipped(BASE, rec.topic1, 11155111);
        vm.prank(SYSTEM);
        rc.react(rec);
        assertEq(sys.requestCount(), 0);
    }

    function test_replayedLog_mintsOnce() public {
        IReactive.LogRecord memory rec = _requestLog(baseBridge, BASE, 5 ether);
        vm.startPrank(SYSTEM);
        rc.react(rec);
        rc.react(rec);
        vm.stopPrank();
        assertEq(sys.requestCount(), 2);

        (bool first,) = _tryDeliver(0);
        (bool second, bytes memory ret) = _tryDeliver(1);
        assertTrue(first);
        assertFalse(second);
        assertEq(ret, abi.encodeWithSelector(TokenBridge.AlreadyMinted.selector, BASE, rec.topic1));
        assertEq(uniToken.balanceOf(peerExecutor), 5 ether);
    }

    function testFuzz_react_relaysExactRequest(uint256 nonce, address to, uint256 amount, bool fromBase) public {
        IReactive.LogRecord memory rec;
        rec.chainId = fromBase ? BASE : UNI;
        rec.contractAddress = fromBase ? address(baseBridge) : address(uniBridge);
        rec.topic0 = rc.BRIDGE_REQUESTED_TOPIC0();
        rec.topic1 = nonce;
        rec.topic2 = uint256(uint160(executor));
        rec.topic3 = uint256(uint160(to));
        rec.data = abi.encode(amount, fromBase ? UNI : BASE);

        vm.prank(SYSTEM);
        rc.react(rec);

        ISystemContract.CallbackConfiguration_V_1_0 memory req = sys.request(0);
        assertEq(req.chainId, fromBase ? UNI : BASE);
        assertEq(req.recipient, fromBase ? address(uniBridge) : address(baseBridge));
        assertEq(
            req.payload, abi.encodeCall(TokenBridge.mintFromReactive, (address(0), rec.chainId, nonce, to, amount))
        );
    }

    // --- gas and funds

    /// The proxy keeps part of the requested limit; what is left must run a cold mint with room to spare.
    function test_callbackGasLimit_coversProxyReservesAndMint() public {
        IReactive.LogRecord memory rec = _requestLog(baseBridge, BASE, 1 ether);
        vm.chainId(UNI);
        vm.prank(address(proxy));
        uint256 before = gasleft();
        uniBridge.mintFromReactive(address(rc), BASE, rec.topic1, peerExecutor, 1 ether);
        uint256 mintGas = before - gasleft();

        // measured on the Base Sepolia proxy: a 200_000 limit leaves 23_321 gas for the recipient
        uint256 forwarded = 23_321 + (uint256(rc.CALLBACK_GAS_LIMIT()) - 200_000) * 63 / 64;
        assertGe(forwarded, mintGas * 2, "callback gas limit leaves under 2x the gas the mint needs");
    }

    function test_withdraw_settlesDebtFirstOnlyOwner() public {
        vm.deal(address(rc), 1 ether);
        sys.setDebt(address(rc), 0.2 ether);

        vm.startPrank(stranger);
        vm.expectRevert(BridgeReactive.NotOwner.selector);
        rc.withdraw(0.1 ether);
        vm.expectRevert(BridgeReactive.NotOwner.selector);
        rc.coverDebt();
        vm.stopPrank();

        uint256 before = address(this).balance;
        rc.withdraw(0.8 ether);
        assertEq(address(this).balance - before, 0.8 ether);
        assertEq(sys.debt(address(rc)), 0);
    }

    function test_coverDebt_paysSystem() public {
        vm.deal(address(rc), 1 ether);
        sys.setDebt(address(rc), 0.3 ether);
        rc.coverDebt();
        assertEq(address(rc).balance, 0.7 ether);
    }
}
