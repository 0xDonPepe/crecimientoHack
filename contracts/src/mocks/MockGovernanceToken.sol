// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title MockGovernanceToken
/// @notice Test governance token, standing in for ARB or ZK.
/// @dev Replaces v1's two 1,897-line mockups, which were OpenZeppelin v4
///      flattened by hand inside a repo whose manifest declared v5.
contract MockGovernanceToken is ERC20, ERC20Permit, ERC20Votes {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC20Permit(name_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
