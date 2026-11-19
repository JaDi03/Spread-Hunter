// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {SpikeReactive} from "../../src/spike/SpikeReactive.sol";
import {SpikeCallback} from "../../src/spike/SpikeCallback.sol";
import {SpikeEmitter} from "../../src/spike/SpikeEmitter.sol";
import {MockSystem} from "../utils/MockSystem.sol";

contract SpikeTest is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 internal constant ORIGIN = 84532;
    uint256 internal constant DEST = 84532;
    uint256 internal constant PING_TOPIC0 = uint256(keccak256("Ping(uint256,uint256)"));

    event Pong(uint256 value, uint256 thresholdSeen, uint256 sentAt, uint256 landedAt, uint256 originTxHash);
    event Reacted(uint256 value, uint256 thresholdSeen, bool forwarded);

    MockSystem internal sys;
    MockSystem internal proxy;
    SpikeReactive internal rc;
    SpikeCallback internal cb;
    address internal emitter = makeAddr("emitter");
    address internal stranger = makeAddr("stranger");

    receive() external payable {}

    function setUp() public {
        MockSystem impl = new MockSystem();
        vm.etch(SYSTEM, address(impl).code);
        sys = MockSystem(payable(SYSTEM));
        proxy = new MockSystem();

        rc = new SpikeReactive(ORIGIN, emitter, DEST, 10);
        cb = new SpikeCallback(IPayable(payable(address(proxy))), address(rc));
        rc.setCallbackContract(address(cb));
    }

    function _log(uint256 value, uint256 sentAt) internal view returns (IReactive.LogRecord memory log_) {
        log_.chainId = ORIGIN;
        log_.contractAddress = emitter;
        log_.topic0 = PING_TOPIC0;
        log_.topic1 = value;
        log_.data = abi.encode(sentAt);
        log_.txHash = 0xabc;
    }

    function _payload(uint256 value, uint256 seen, uint256 sentAt) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "onPing(address,uint256,uint256,uint256,uint256)", address(0), value, seen, sentAt, uint256(0xabc)
        );
    }

    // --- SpikeEmitter

    function test_ping_topicMatchesReactiveSubscription() public {
        SpikeEmitter e = new SpikeEmitter();
        vm.recordLogs();
        e.ping(7);
        assertEq(uint256(vm.getRecordedLogs()[0].topics[0]), PING_TOPIC0);
    }

    function test_ping_rejectsStranger() public {
        SpikeEmitter e = new SpikeEmitter();
        vm.prank(stranger);
        vm.expectRevert(SpikeEmitter.NotOwner.selector);
        e.ping(7);
    }

    // --- SpikeReactive: construction

    function test_constructor_subscribesToPing() public view {
        assertEq(sys.subCount(), 1);
        (uint256 chainId, address target, uint256 topic0) = sys.subs(0);
        assertEq(chainId, ORIGIN);
        assertEq(target, emitter);
        assertEq(topic0, PING_TOPIC0);
    }

    function test_constructor_rejectsZeroValues() public {
        vm.expectRevert(SpikeReactive.ZeroAddress.selector);
        new SpikeReactive(ORIGIN, address(0), DEST, 10);
        vm.expectRevert(SpikeReactive.ZeroChainId.selector);
        new SpikeReactive(0, emitter, DEST, 10);
        vm.expectRevert(SpikeReactive.ZeroChainId.selector);
        new SpikeReactive(ORIGIN, emitter, 0, 10);
    }

    function test_setCallbackContract_rejectsZeroAndSecondCall() public {
        SpikeReactive fresh = new SpikeReactive(ORIGIN, emitter, DEST, 10);
        vm.expectRevert(SpikeReactive.ZeroAddress.selector);
        fresh.setCallbackContract(address(0));
        vm.expectRevert(SpikeReactive.CallbackAlreadySet.selector);
        rc.setCallbackContract(stranger);
    }

    // --- SpikeReactive: react

    function test_react_forwardsAtThresholdWithFullPayload() public {
        vm.expectEmit(address(rc));
        emit Reacted(10, 10, true);
        vm.prank(SYSTEM);
        rc.react(_log(10, 123));

        assertEq(sys.requestCount(), 1);
        ISystemContract.CallbackConfiguration_V_1_0 memory req = sys.request(0);
        assertEq(req.chainId, DEST);
        assertEq(req.recipient, address(cb));
        assertEq(req.gasLimit, 300_000);
        assertEq(req.payload, _payload(10, 10, 123));
        assertEq(rc.reactCount(), 1);
    }

    function test_react_skipsBelowThreshold() public {
        vm.prank(SYSTEM);
        rc.react(_log(9, 1));
        assertEq(sys.requestCount(), 0);
        assertEq(rc.reactCount(), 1);
    }

    function test_react_carriesThresholdSetByOwner() public {
        rc.setThreshold(5);
        vm.prank(SYSTEM);
        rc.react(_log(7, 1));
        assertEq(sys.request(0).payload, _payload(7, 5, 1));
    }

    function test_react_withoutCallbackSet_doesNotForward() public {
        SpikeReactive fresh = new SpikeReactive(ORIGIN, emitter, DEST, 0);
        vm.prank(SYSTEM);
        fresh.react(_log(100, 1));
        assertEq(sys.requestCount(), 0);
        assertEq(fresh.reactCount(), 1);
    }

    function test_react_ignoresOtherContractChainOrTopic() public {
        IReactive.LogRecord memory a = _log(100, 1);
        a.contractAddress = stranger;
        IReactive.LogRecord memory b = _log(100, 1);
        b.chainId = 1301;
        IReactive.LogRecord memory c = _log(100, 1);
        c.topic0 = 1;
        vm.startPrank(SYSTEM);
        rc.react(a);
        rc.react(b);
        rc.react(c);
        vm.stopPrank();
        assertEq(sys.requestCount(), 0);
        assertEq(rc.reactCount(), 0);
    }

    function test_react_rejectsNonSystemCaller() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM));
        rc.react(_log(100, 1));
    }

    function testFuzz_react_forwardsIffValueAtLeastThreshold(uint256 value, uint256 threshold) public {
        rc.setThreshold(threshold);
        vm.prank(SYSTEM);
        rc.react(_log(value, 1));
        assertEq(sys.requestCount(), value >= threshold ? 1 : 0);
    }

    // --- SpikeReactive: owner and funds

    function test_ownerFunctions_rejectStranger() public {
        vm.startPrank(stranger);
        vm.expectRevert(SpikeReactive.NotOwner.selector);
        rc.setThreshold(1);
        vm.expectRevert(SpikeReactive.NotOwner.selector);
        rc.setCallbackContract(stranger);
        vm.expectRevert(SpikeReactive.NotOwner.selector);
        rc.coverDebt();
        vm.expectRevert(SpikeReactive.NotOwner.selector);
        rc.withdraw(0);
        vm.expectRevert(SpikeCallback.NotOwner.selector);
        cb.coverDebt();
        vm.expectRevert(SpikeCallback.NotOwner.selector);
        cb.withdraw(0);
        vm.stopPrank();
    }

    function test_reactive_coverDebtPaysSystem() public {
        vm.deal(address(rc), 1 ether);
        sys.setDebt(address(rc), 0.3 ether);
        uint256 before = SYSTEM.balance;
        rc.coverDebt();
        assertEq(SYSTEM.balance - before, 0.3 ether);
        assertEq(address(rc).balance, 0.7 ether);
    }

    function test_reactive_withdrawSendsToOwnerOnly() public {
        vm.deal(address(rc), 1 ether);
        uint256 before = address(this).balance;
        rc.withdraw(0.4 ether);
        assertEq(address(this).balance - before, 0.4 ether);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.InsufficientFunds.selector, 2 ether, 0.6 ether));
        rc.withdraw(2 ether);
    }

    function test_reactive_withdrawSettlesDebtFirst() public {
        vm.deal(address(rc), 1 ether);
        sys.setDebt(address(rc), 0.3 ether);
        uint256 before = address(this).balance;
        rc.withdraw(0.7 ether);
        assertEq(address(this).balance - before, 0.7 ether);
        assertEq(sys.debt(address(rc)), 0);
        assertEq(address(rc).balance, 0);
    }

    function test_reactive_withdrawRevertsIfItWouldLeaveDebt() public {
        vm.deal(address(rc), 1 ether);
        sys.setDebt(address(rc), 0.3 ether);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.InsufficientFunds.selector, 1 ether, 0.7 ether));
        rc.withdraw(1 ether);
    }

    // --- SpikeCallback

    function test_callback_constructorRejectsZero() public {
        vm.expectRevert(SpikeCallback.ZeroAddress.selector);
        new SpikeCallback(IPayable(payable(address(0))), address(rc));
        vm.expectRevert(SpikeCallback.ZeroAddress.selector);
        new SpikeCallback(IPayable(payable(address(proxy))), address(0));
    }

    function test_onPing_emitsPongWithAllFields() public {
        vm.warp(1_000);
        vm.expectEmit(address(cb));
        emit Pong(10, 7, 990, 1_000, 0xabc);
        vm.prank(address(proxy));
        cb.onPing(address(rc), 10, 7, 990, 0xabc);
        assertEq(cb.pongCount(), 1);
    }

    /// The proxy withholds its own reserves from the requested gas limit; what is left must run onPing on a cold slot.
    function test_callbackGasLimit_coversProxyReservesAndOnPing() public {
        // measured on the Base Sepolia proxy: a 200_000 limit leaves 23_321 gas for the recipient
        uint256 measuredLimit = 200_000;
        uint256 measuredForwarded = 23_321;

        vm.prank(SYSTEM);
        rc.react(_log(10, 123));
        uint256 requested = sys.request(0).gasLimit;

        vm.prank(address(proxy));
        uint256 before = gasleft();
        cb.onPing(address(rc), 10, 10, 990, 0xabc);
        uint256 onPingGas = before - gasleft();

        // gas above the measured limit loses 1/64 to the proxy's CALL
        uint256 forwarded = measuredForwarded + (requested - measuredLimit) * 63 / 64;
        assertGe(forwarded, onPingGas * 2, "callback gas limit leaves under 2x the gas onPing needs");
    }

    function test_onPing_rejectsNonProxyCaller() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, address(proxy)));
        cb.onPing(address(rc), 10, 10, 123, 0xabc);
    }

    function test_onPing_rejectsOtherReactiveSender() public {
        vm.prank(address(proxy));
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, address(rc)));
        cb.onPing(stranger, 10, 10, 123, 0xabc);
    }

    function test_callback_coverDebtAndWithdraw() public {
        vm.deal(address(cb), 1 ether);
        proxy.setDebt(address(cb), 0.25 ether);
        cb.coverDebt();
        assertEq(address(proxy).balance, 0.25 ether);
        uint256 before = address(this).balance;
        cb.withdraw(0.75 ether);
        assertEq(address(this).balance - before, 0.75 ether);
    }

    function test_callback_withdrawSettlesDebtFirst() public {
        vm.deal(address(cb), 1 ether);
        proxy.setDebt(address(cb), 0.25 ether);
        uint256 before = address(this).balance;
        cb.withdraw(0.75 ether);
        assertEq(address(this).balance - before, 0.75 ether);
        assertEq(address(proxy).balance, 0.25 ether);
        assertEq(proxy.debt(address(cb)), 0);
    }
}
