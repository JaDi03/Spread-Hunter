// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// ERC-20 with free minting, chosen decimals and an optional burn on every transfer, for tests only.
contract MockToken is ERC20 {
    uint8 internal immutable _decimals;
    uint256 public transferFeeBps;

    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransferFeeBps(uint256 bps) external {
        transferFeeBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 fee = from == address(0) || to == address(0) ? 0 : value * transferFeeBps / 10_000;
        if (fee > 0) super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}
