// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {HuntToken} from "../../src/token/HuntToken.sol";

contract HuntTokenTest is Test {
    HuntToken internal token;
    address internal bridge = makeAddr("bridge");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");

    function setUp() public {
        token = new HuntToken(1_000 ether);
    }

    function test_constructor_mintsInitialSupplyToOwner() public view {
        assertEq(token.owner(), address(this));
        assertEq(token.balanceOf(address(this)), 1_000 ether);
        assertEq(token.totalSupply(), 1_000 ether);
        assertEq(token.symbol(), "HUNT");
        assertEq(token.decimals(), 18);
    }

    function test_setBridge_onlyOwnerOnceNonZero() public {
        vm.prank(stranger);
        vm.expectRevert(HuntToken.NotOwner.selector);
        token.setBridge(bridge);

        vm.expectRevert(HuntToken.ZeroAddress.selector);
        token.setBridge(address(0));

        vm.expectEmit(address(token));
        emit HuntToken.BridgeSet(bridge);
        token.setBridge(bridge);
        assertEq(token.bridge(), bridge);

        vm.expectRevert(HuntToken.BridgeAlreadySet.selector);
        token.setBridge(stranger);
    }

    function test_mintAndBurn_onlyBridge() public {
        vm.prank(stranger);
        vm.expectRevert(HuntToken.NotBridge.selector);
        token.mint(stranger, 1);

        // before the bridge is set, nobody can mint, not even address(0)
        vm.prank(address(0));
        vm.expectRevert(HuntToken.NotBridge.selector);
        token.mint(stranger, 1);

        token.setBridge(bridge);

        vm.prank(stranger);
        vm.expectRevert(HuntToken.NotBridge.selector);
        token.bridgeBurn(address(this), 1);

        vm.prank(bridge);
        token.mint(alice, 5 ether);
        assertEq(token.balanceOf(alice), 5 ether);

        vm.prank(bridge);
        token.bridgeBurn(alice, 2 ether);
        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.totalSupply(), 1_003 ether);
    }
}
