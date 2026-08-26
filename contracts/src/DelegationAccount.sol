// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title DelegationAccount
/// @notice Personal vault that custodies ONE user's collateral.
/// @dev This contract is the heart of the protocol's thesis. ERC20Votes credits
///      voting power to the address that *holds* the tokens, and only if that
///      address has called `delegate()`. That is why collateral cannot sit in a
///      shared vault: there, every user's voting power would be pooled together
///      (or lost outright). Each user gets their own account, which holds their
///      collateral and delegates to whoever they choose.
///
///      Deployed as a minimal clone (EIP-1167), so it is set up through
///      `initialize()` rather than a constructor.
contract DelegationAccount {
    using SafeERC20 for IERC20;

    /// @notice Vault controlling this account. Non-zero means already initialized.
    address public vault;
    /// @notice User who owns the collateral this account custodies.
    address public owner;
    /// @notice Governance token deposited as collateral.
    IERC20 public collateralToken;

    event Initialized(address indexed vault, address indexed owner, address indexed token);
    event Delegated(address indexed delegatee);
    event CollateralReleased(address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotAuthorized();
    error OnlyVault();
    error ZeroAddress();

    /// @dev Locks the implementation: clones get their own storage, so this
    ///      non-zero `vault` only prevents initializing the template itself.
    constructor() {
        vault = address(0xdead);
    }

    /// @notice Initializes the clone and hands voting power back to the user.
    /// @dev Self-delegating to the owner is deliberate: without a call to
    ///      `delegate()` a contract's tokens do NOT count as votes, not even for
    ///      itself. Delegating to the owner up front is what makes depositing
    ///      collateral cost no voting power.
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

    /// @notice Redirects the voting power of the custodied collateral.
    /// @dev Callable by the owner (through the vault) or the vault. Moves no funds.
    function delegate(address delegatee) external {
        if (msg.sender != owner && msg.sender != vault) revert NotAuthorized();
        IVotes(address(collateralToken)).delegate(delegatee);
        emit Delegated(delegatee);
    }

    /// @notice Releases collateral. Vault only, after a health check or a liquidation.
    function releaseCollateral(address to, uint256 amount) external {
        if (msg.sender != vault) revert OnlyVault();
        collateralToken.safeTransfer(to, amount);
        emit CollateralReleased(to, amount);
    }

    /// @notice Current delegatee of the custodied collateral.
    function currentDelegate() external view returns (address) {
        return IVotes(address(collateralToken)).delegates(address(this));
    }

    /// @notice Voting power this collateral contributes today.
    function votingPower() external view returns (uint256) {
        return IVotes(address(collateralToken)).getVotes(IVotes(address(collateralToken)).delegates(address(this)));
    }
}
