// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {HuntToken} from "../../src/token/HuntToken.sol";
import {TokenBridge} from "../../src/token/TokenBridge.sol";
import {MockSystem} from "../spike/Spike.t.sol";

contract TokenBridgeTest is Test {
    uint256 internal constant PEER = 1301;

    HuntToken internal token;
    TokenBridge internal bridge;
    MockSystem internal proxy;
    address internal rc = makeAddr("rc");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");

    receive() external payable {}

    function setUp() public {
        vm.chainId(84532);
        proxy = new MockSystem();
        token = new HuntToken(1_000 ether);
        bridge = new TokenBridge(IPayable(payable(address(proxy))), rc, token, PEER);
        token.setBridge(address(bridge));
        bridge.setOperator(operator, true);
        token.transfer(operator, 100 ether);
    }

    // --- constructor and operators

    function test_constructor_rejectsZeroAndSameChain() public {
        IPayable p = IPayable(payable(address(proxy)));
        vm.expectRevert(TokenBridge.ZeroAddress.selector);
        new TokenBridge(IPayable(payable(address(0))), rc, token, PEER);
        vm.expectRevert(TokenBridge.ZeroAddress.selector);
        new TokenBridge(p, address(0), token, PEER);
        vm.expectRevert(TokenBridge.ZeroAddress.selector);
        new TokenBridge(p, rc, HuntToken(address(0)), PEER);
        vm.expectRevert(TokenBridge.InvalidPeerChain.selector);
        new TokenBridge(p, rc, token, 0);
        vm.expectRevert(TokenBridge.InvalidPeerChain.selector);
        new TokenBridge(p, rc, token, block.chainid);
    }

    function test_setOperator_emits() public {
        vm.expectEmit(address(bridge));
        emit TokenBridge.OperatorSet(alice, true);
        bridge.setOperator(alice, true);
        assertTrue(bridge.operators(alice));
    }

    function test_setOperator_onlyOwnerNonZero() public {
        vm.prank(stranger);
        vm.expectRevert(TokenBridge.NotOwner.selector);
        bridge.setOperator(stranger, true);

        vm.expectRevert(TokenBridge.ZeroAddress.selector);
        bridge.setOperator(address(0), true);

        bridge.setOperator(operator, false);
        assertFalse(bridge.operators(operator));
    }

    // --- bridge

    function test_bridge_burnsStoresAndEmits() public {
        uint256 first = bridge.nextNonce();
        vm.expectEmit(address(bridge));
        emit TokenBridge.BridgeRequested(first, operator, alice, 40 ether, PEER);
        vm.prank(operator);
        uint256 nonce = bridge.bridge(alice, 40 ether);

        assertEq(nonce, first);
        assertEq(bridge.nextNonce(), first + 1);
        assertEq(token.balanceOf(operator), 60 ether);
        assertEq(token.totalSupply(), 960 ether);
        (address from, address to, uint256 amount) = bridge.requests(first);
        assertEq(from, operator);
        assertEq(to, alice);
        assertEq(amount, 40 ether);

        vm.prank(operator);
        assertEq(bridge.bridge(alice, 1 ether), first + 1);
    }

    function test_nonces_differPerDeployment() public {
        TokenBridge other = new TokenBridge(IPayable(payable(address(proxy))), rc, token, PEER);
        assertEq(bridge.nextNonce(), uint256(uint160(address(bridge))) << 96);
        assertTrue(other.nextNonce() != bridge.nextNonce());
    }

    function test_bridge_revertsWhenTokenLinkedElsewhere() public {
        HuntToken otherToken = new HuntToken(10 ether);
        TokenBridge unlinked = new TokenBridge(IPayable(payable(address(proxy))), rc, otherToken, PEER);
        unlinked.setOperator(address(this), true);
        vm.expectRevert(HuntToken.NotBridge.selector);
        unlinked.bridge(alice, 1 ether);
    }

    function test_bridge_rejectsNonOperatorAndZeros() public {
        vm.prank(stranger);
        vm.expectRevert(TokenBridge.NotOperator.selector);
        bridge.bridge(alice, 1 ether);

        vm.startPrank(operator);
        vm.expectRevert(TokenBridge.ZeroAddress.selector);
        bridge.bridge(address(0), 1 ether);
        vm.expectRevert(TokenBridge.ZeroAmount.selector);
        bridge.bridge(alice, 0);
        vm.stopPrank();
    }

    function test_bridge_revertsWithoutBalanceAndEmitsNothing() public {
        uint256 first = bridge.nextNonce();
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, operator, 100 ether, 101 ether)
        );
        bridge.bridge(alice, 101 ether);
        assertEq(bridge.nextNonce(), first);
        (,, uint256 stored) = bridge.requests(first);
        assertEq(stored, 0);
    }

    // --- retry

    function test_retry_reemitsStoredRequestOnlyForOwner() public {
        vm.prank(operator);
        uint256 nonce = bridge.bridge(alice, 7 ether);

        vm.prank(stranger);
        vm.expectRevert(TokenBridge.NotOwner.selector);
        bridge.retry(nonce);

        vm.expectRevert(abi.encodeWithSelector(TokenBridge.UnknownRequest.selector, nonce + 1));
        bridge.retry(nonce + 1);

        vm.expectEmit(address(bridge));
        emit TokenBridge.BridgeRequested(nonce, operator, alice, 7 ether, PEER);
        bridge.retry(nonce);
        assertEq(token.balanceOf(operator), 93 ether);
    }

    // --- mintFromReactive

    function test_mint_onlyProxyAndOurReactive() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, address(proxy)));
        bridge.mintFromReactive(rc, PEER, 0, alice, 1 ether);

        vm.prank(address(proxy));
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, rc));
        bridge.mintFromReactive(stranger, PEER, 0, alice, 1 ether);
    }

    function test_mint_rejectsOtherSourceChain() public {
        vm.prank(address(proxy));
        vm.expectRevert(abi.encodeWithSelector(TokenBridge.WrongSourceChain.selector, 11155111));
        bridge.mintFromReactive(rc, 11155111, 0, alice, 1 ether);
    }

    function test_mint_oncePerSourceNonce() public {
        vm.expectEmit(address(bridge));
        emit TokenBridge.Minted(PEER, 3, alice, 5 ether);
        vm.prank(address(proxy));
        bridge.mintFromReactive(rc, PEER, 3, alice, 5 ether);
        assertEq(token.balanceOf(alice), 5 ether);
        assertTrue(bridge.minted(PEER, 3));

        // a retried request arrives again: rejected, nothing minted twice
        vm.prank(address(proxy));
        vm.expectRevert(abi.encodeWithSelector(TokenBridge.AlreadyMinted.selector, PEER, 3));
        bridge.mintFromReactive(rc, PEER, 3, alice, 5 ether);
        assertEq(token.balanceOf(alice), 5 ether);
    }

    function test_mint_failedCallbackCanLandOnRetry() public {
        // first delivery runs out of gas: state rolls back and the nonce stays free
        vm.prank(address(proxy));
        (bool ok,) = address(bridge).call{gas: 30_000}(
            abi.encodeCall(TokenBridge.mintFromReactive, (rc, PEER, 0, alice, 5 ether))
        );
        assertFalse(ok);
        assertFalse(bridge.minted(PEER, 0));

        vm.prank(address(proxy));
        bridge.mintFromReactive(rc, PEER, 0, alice, 5 ether);
        assertEq(token.balanceOf(alice), 5 ether);
    }

    // --- funds

    function test_withdraw_settlesDebtFirstAndOnlyOwner() public {
        vm.deal(address(bridge), 1 ether);
        proxy.setDebt(address(bridge), 0.25 ether);

        vm.startPrank(stranger);
        vm.expectRevert(TokenBridge.NotOwner.selector);
        bridge.withdraw(0.1 ether);
        vm.expectRevert(TokenBridge.NotOwner.selector);
        bridge.coverDebt();
        vm.stopPrank();

        uint256 before = address(this).balance;
        bridge.withdraw(0.75 ether);
        assertEq(address(this).balance - before, 0.75 ether);
        assertEq(address(proxy).balance, 0.25 ether);
        assertEq(proxy.debt(address(bridge)), 0);
    }

    function testFuzz_bridgeThenMint_conservesAmount(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(operator);
        uint256 nonce = bridge.bridge(alice, amount);
        assertEq(token.totalSupply(), supplyBefore - amount);

        // the peer bridge would mint this on the other chain; replayed here to check the amounts match
        vm.prank(address(proxy));
        bridge.mintFromReactive(rc, PEER, nonce, alice, amount);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.balanceOf(alice), amount);
    }
}
