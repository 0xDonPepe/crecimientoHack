// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title GovStablecoin
/// @notice Overcollateralized stablecoin minted and burned by a single vault.
/// @dev The vault is `immutable` and fixed in the constructor. There is no
///      owner and no arbitrary mint function: the CDP is the only source of
///      supply.
contract GovStablecoin is ERC20, ERC20Permit {
    /// @notice The only contract allowed to mint and burn.
    address public immutable vault;

    error OnlyVault();
    error ZeroAddress();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(string memory name_, string memory symbol_, address vault_) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
    }

    /// @notice Mints `amount` to `to`. Vault only, against deposited collateral.
    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    /// @notice Burns `amount` from `from`. Vault only, on repayment or liquidation.
    /// @dev Needs no allowance because the vault only ever calls it on whoever
    ///      signed the transaction (the payer or the liquidator).
    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}
