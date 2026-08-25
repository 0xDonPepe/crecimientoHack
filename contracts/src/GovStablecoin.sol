// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title GovStablecoin
/// @notice Stablecoin sobrecolateralizada que emite y quema un unico vault.
/// @dev El vault es `immutable` y se fija en el constructor. No hay owner, ni
///      funcion de emision arbitraria: la unica fuente de oferta es el CDP.
contract GovStablecoin is ERC20, ERC20Permit {
    /// @notice Unico contrato autorizado a emitir y quemar.
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

    /// @notice Emite `amount` a `to`. Solo el vault, contra colateral depositado.
    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    /// @notice Quema `amount` de `from`. Solo el vault, al repagar o liquidar.
    /// @dev No requiere allowance porque el vault solo la invoca sobre quien
    ///      firmo la transaccion (el pagador o el liquidador).
    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}
