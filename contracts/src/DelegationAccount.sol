// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title DelegationAccount
/// @notice Boveda personal que custodia el colateral de UN usuario.
/// @dev Este contrato es el corazon de la tesis del protocolo. ERC20Votes
///      contabiliza el poder de voto de la direccion que *sostiene* los tokens,
///      y solo si esa direccion ha llamado `delegate()`. Por eso el colateral no
///      puede quedarse en el vault comun: ahi el poder de voto de todos los
///      usuarios se mezclaria (o se perderia). Cada usuario recibe su propia
///      cuenta, que sostiene su colateral y delega a quien el decida.
///
///      Se despliega como clon minimo (EIP-1167), asi que se inicializa por
///      `initialize()` y no por constructor.
contract DelegationAccount {
    using SafeERC20 for IERC20;

    /// @notice Vault que controla esta cuenta. Distinto de cero = ya inicializada.
    address public vault;
    /// @notice Usuario dueno del colateral que custodia esta cuenta.
    address public owner;
    /// @notice Token de gobernanza depositado como colateral.
    IERC20 public collateralToken;

    event Initialized(address indexed vault, address indexed owner, address indexed token);
    event Delegated(address indexed delegatee);
    event CollateralReleased(address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotAuthorized();
    error OnlyVault();
    error ZeroAddress();

    /// @dev Bloquea la implementacion: los clones tienen su propio storage, asi
    ///      que este `vault` distinto de cero solo impide inicializar el molde.
    constructor() {
        vault = address(0xdead);
    }

    /// @notice Inicializa el clon y devuelve el poder de voto al usuario.
    /// @dev La auto-delegacion al dueno es deliberada: sin una llamada a
    ///      `delegate()` los tokens de un contrato NO cuentan como votos, ni
    ///      siquiera para el mismo. Delegar al dueno de entrada es lo que hace
    ///      que depositar colateral no cueste poder de voto.
    function initialize(address vault_, address owner_, address token_) external {
        if (vault != address(0)) revert AlreadyInitialized();
        if (vault_ == address(0) || owner_ == address(0) || token_ == address(0)) revert ZeroAddress();

        vault = vault_;
        owner = owner_;
        collateralToken = IERC20(token_);

        emit Initialized(vault_, owner_, token_);

        IVotes(token_).delegate(owner_);
        emit Delegated(owner_);
    }

    /// @notice Redirige el poder de voto del colateral custodiado.
    /// @dev Lo puede llamar el dueno (via el vault) o el vault. No mueve fondos.
    function delegate(address delegatee) external {
        if (msg.sender != owner && msg.sender != vault) revert NotAuthorized();
        IVotes(address(collateralToken)).delegate(delegatee);
        emit Delegated(delegatee);
    }

    /// @notice Libera colateral. Solo el vault, tras comprobar la salud o liquidar.
    function releaseCollateral(address to, uint256 amount) external {
        if (msg.sender != vault) revert OnlyVault();
        collateralToken.safeTransfer(to, amount);
        emit CollateralReleased(to, amount);
    }

    /// @notice Delegatee actual del colateral custodiado.
    function currentDelegate() external view returns (address) {
        return IVotes(address(collateralToken)).delegates(address(this));
    }

    /// @notice Poder de voto que este colateral aporta hoy.
    function votingPower() external view returns (uint256) {
        return IVotes(address(collateralToken)).getVotes(IVotes(address(collateralToken)).delegates(address(this)));
    }
}
