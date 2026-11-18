// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title HuntToken
/// @notice Test token traded against USDC in the arbitrage pools. The owner receives the initial supply for
/// pool liquidity; after that only the bridge mints and burns, to move inventory between chains.
contract HuntToken is ERC20 {
    error NotOwner();
    error NotBridge();
    error BridgeAlreadySet();
    error ZeroAddress();

    address public immutable owner;
    address public bridge;

    event BridgeSet(address bridge);

    constructor(uint256 initialSupply) ERC20("Hunt Token", "HUNT") {
        owner = msg.sender;
        _mint(msg.sender, initialSupply);
    }

    modifier onlyBridge() {
        if (msg.sender != bridge || msg.sender == address(0)) revert NotBridge();
        _;
    }

    /// @notice One-time link to the bridge of this chain, which is deployed after the token.
    function setBridge(address bridge_) external {
        if (msg.sender != owner) revert NotOwner();
        if (bridge_ == address(0)) revert ZeroAddress();
        if (bridge != address(0)) revert BridgeAlreadySet();
        bridge = bridge_;
        emit BridgeSet(bridge_);
    }

    function mint(address to, uint256 amount) external onlyBridge {
        _mint(to, amount);
    }

    /// @notice Burns tokens of the account that asked the bridge to move them.
    function bridgeBurn(address from, uint256 amount) external onlyBridge {
        _burn(from, amount);
    }
}
