// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {GovStablecoin} from "./GovStablecoin.sol";
import {DelegationAccount} from "./DelegationAccount.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// @title CollateralVotingVault
/// @notice Overcollateralized CDP that preserves the collateral's voting power.
/// @dev A single constructor-parameterized contract serves any ERC20Votes token
///      with a Chainlink feed. v1 kept one copy per chain and the copies drifted
///      apart.
///
///      Decimal conventions, settled once and for all:
///        - collateral is assumed to have 18 decimals (checked in the constructor);
///        - the price is ALWAYS normalized to 18 decimals (`_price`);
///        - debt and the stablecoin have 18 decimals;
///        - USD value (18 dec) = amount(18) * price(18) / 1e18.
///      That final division by 1e18 is what v1 was missing, which made it mint
///      1e18 times more stablecoins than it should have.
contract CollateralVotingVault is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    /// @notice Hard cap on the liquidation bonus, so the owner cannot configure
    ///         a parameter that would confiscate healthy positions.
    uint256 public constant MAX_LIQUIDATION_BONUS_BPS = 2_000;
    uint256 public constant MIN_PRICE_AGE = 1 minutes;
    uint256 public constant MAX_PRICE_AGE = 7 days;

    /* ---------------------------------------------------------------- *
     *                       immutable configuration                     *
     * ---------------------------------------------------------------- */

    /// @notice Governance token accepted as collateral (must be ERC20Votes).
    IERC20 public immutable collateralToken;
    /// @notice USD price feed for the collateral.
    IAggregatorV3 public immutable priceFeed;
    /// @notice Stablecoin minted against this collateral.
    GovStablecoin public immutable stablecoin;
    /// @notice EIP-1167 template that delegation accounts are cloned from.
    address public immutable accountImplementation;
    /// @dev Multiplier that brings the feed price up to 18 decimals.
    uint256 private immutable priceScale;

    /* ---------------------------------------------------------------- *
     *                          risk parameters                          *
     * ---------------------------------------------------------------- */

    /// @notice Maximum LTV when minting or withdrawing. 5000 = 50%.
    uint256 public maxLtvBps;
    /// @notice LTV at which a position becomes liquidatable. 7500 = 75%.
    uint256 public liquidationThresholdBps;
    /// @notice Discount the liquidator receives. 1000 = 10%.
    uint256 public liquidationBonusBps;
    /// @notice Largest fraction of the debt coverable in a single liquidation.
    uint256 public closeFactorBps;
    /// @notice Maximum tolerated age of the oracle price.
    uint256 public maxPriceAge;

    /* ---------------------------------------------------------------- *
     *                               state                               *
     * ---------------------------------------------------------------- */

    /// @notice Collateral deposited per user.
    mapping(address user => uint256 amount) public collateralOf;
    /// @notice Outstanding debt per user, denominated in the stablecoin.
    mapping(address user => uint256 amount) public debtOf;
    /// @notice Each user's delegation account (zero if they don't have one yet).
    mapping(address user => address account) public accountOf;

    uint256 public totalCollateral;
    uint256 public totalDebt;

    /* ---------------------------------------------------------------- *
     *                               events                              *
     * ---------------------------------------------------------------- */

    event AccountOpened(address indexed user, address indexed account);
    event Deposited(address indexed user, address indexed account, uint256 amount);
    event Minted(address indexed user, uint256 amount, uint256 newDebt);
    event Repaid(address indexed payer, address indexed user, uint256 amount, uint256 newDebt);
    event Withdrawn(address indexed user, uint256 amount);
    event DelegateChanged(address indexed user, address indexed delegatee);
    event Liquidated(address indexed liquidator, address indexed user, uint256 debtCovered, uint256 collateralSeized);
    event RiskParametersUpdated(
        uint256 maxLtvBps, uint256 liquidationThresholdBps, uint256 liquidationBonusBps, uint256 closeFactorBps
    );
    event MaxPriceAgeUpdated(uint256 maxPriceAge);

    /* ---------------------------------------------------------------- *
     *                               errors                              *
     * ---------------------------------------------------------------- */

    error ZeroAddress();
    error ZeroAmount();
    error UnsupportedDecimals();
    error InvalidParameters();
    error NoAccount();
    error NoDebt();
    error InsufficientCollateral();
    /// @param debt resulting debt; @param maxDebtAllowed ceiling implied by the LTV
    error ExceedsMaxLtv(uint256 debt, uint256 maxDebtAllowed);
    error PositionHealthy(uint256 healthFactor);
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error InvalidPrice(int256 answer);

    /* ---------------------------------------------------------------- *
     *                            constructor                            *
     * ---------------------------------------------------------------- */

    constructor(
        address collateralToken_,
        address priceFeed_,
        string memory stablecoinName,
        string memory stablecoinSymbol,
        uint256 maxLtvBps_,
        uint256 liquidationThresholdBps_,
        uint256 liquidationBonusBps_,
        uint256 closeFactorBps_,
        uint256 maxPriceAge_,
        address owner_
    ) Ownable(owner_) {
        if (collateralToken_ == address(0) || priceFeed_ == address(0)) revert ZeroAddress();
        if (IERC20Metadata(collateralToken_).decimals() != 18) revert UnsupportedDecimals();

        uint8 feedDecimals = IAggregatorV3(priceFeed_).decimals();
        if (feedDecimals > 18) revert UnsupportedDecimals();

        collateralToken = IERC20(collateralToken_);
        priceFeed = IAggregatorV3(priceFeed_);
        priceScale = 10 ** (18 - feedDecimals);

        accountImplementation = address(new DelegationAccount());
        stablecoin = new GovStablecoin(stablecoinName, stablecoinSymbol, address(this));

        _setRiskParameters(maxLtvBps_, liquidationThresholdBps_, liquidationBonusBps_, closeFactorBps_);
        _setMaxPriceAge(maxPriceAge_);
    }

    /* ---------------------------------------------------------------- *
     *                          user operations                          *
     * ---------------------------------------------------------------- */

    /// @notice Creates the caller's delegation account ahead of time.
    /// @dev Optional: `deposit` creates it on its own. Useful to set a delegate
    ///      before depositing anything.
    function openAccount() external whenNotPaused returns (address) {
        return _accountFor(msg.sender);
    }

    /// @notice Deposits collateral into the caller's own delegation account.
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        _deposit(msg.sender, amount);
    }

    /// @notice Mints stablecoin against already-deposited collateral.
    function mint(uint256 amount) external nonReentrant whenNotPaused {
        _mint(msg.sender, amount);
    }

    /// @notice Deposits and mints in a single transaction.
    /// @param mintAmount may be 0 to deposit without taking on debt.
    function depositAndMint(uint256 collateralAmount, uint256 mintAmount) external nonReentrant whenNotPaused {
        _deposit(msg.sender, collateralAmount);
        if (mintAmount != 0) _mint(msg.sender, mintAmount);
    }

    /// @notice Repays your own debt by burning stablecoin.
    /// @dev If `amount` exceeds the debt it is clamped to the debt; passing
    ///      `type(uint256).max` repays everything without reading it first.
    function repay(uint256 amount) external nonReentrant returns (uint256 repaid) {
        return _repay(msg.sender, msg.sender, amount);
    }

    /// @notice Repays someone else's debt. Useful for rescuing a position.
    function repayFor(address user, uint256 amount) external nonReentrant returns (uint256 repaid) {
        return _repay(msg.sender, user, amount);
    }

    /// @notice Withdraws collateral, as long as the position stays under max LTV.
    function withdraw(uint256 amount) external nonReentrant {
        _withdraw(msg.sender, amount);
    }

    /// @notice Repays and withdraws in a single transaction.
    function repayAndWithdraw(uint256 repayAmount, uint256 withdrawAmount) external nonReentrant {
        if (repayAmount != 0) _repay(msg.sender, msg.sender, repayAmount);
        if (withdrawAmount != 0) _withdraw(msg.sender, withdrawAmount);
    }

    /// @notice Redirects the voting power of your own collateral.
    /// @dev Callable with debt outstanding: delegating moves no funds and does
    ///      not affect the position's health. That is precisely the point of
    ///      this protocol.
    function delegate(address delegatee) external {
        address account = accountOf[msg.sender];
        if (account == address(0)) revert NoAccount();
        DelegationAccount(account).delegate(delegatee);
        emit DelegateChanged(msg.sender, delegatee);
    }

    /// @notice Liquidates a position whose health factor fell below 1e18.
    /// @param debtToCover debt the liquidator covers; clamped to the close factor.
    /// @return seized collateral handed to the liquidator, bonus included.
    function liquidate(address user, uint256 debtToCover) external nonReentrant whenNotPaused returns (uint256 seized) {
        uint256 price = _price();
        uint256 debt = debtOf[user];
        if (debt == 0) revert NoDebt();

        uint256 hf = _healthFactor(collateralOf[user], debt, price);
        if (hf >= WAD) revert PositionHealthy(hf);

        uint256 maxRepay = (debt * closeFactorBps) / BPS;
        if (debtToCover > maxRepay) debtToCover = maxRepay;
        if (debtToCover == 0) revert ZeroAmount();

        // Collateral to seize = value of the covered debt plus bonus, in tokens.
        seized = (debtToCover * (BPS + liquidationBonusBps) * WAD) / (BPS * price);

        uint256 collateral = collateralOf[user];
        // Insolvent position: the liquidator takes whatever is left and the rest
        // of the debt stays owed. Without this cap `releaseCollateral` would
        // revert and the bad position could never be closed.
        if (seized > collateral) seized = collateral;

        debtOf[user] = debt - debtToCover;
        totalDebt -= debtToCover;
        collateralOf[user] = collateral - seized;
        totalCollateral -= seized;

        stablecoin.burn(msg.sender, debtToCover);
        DelegationAccount(accountOf[user]).releaseCollateral(msg.sender, seized);

        emit Liquidated(msg.sender, user, debtToCover, seized);
    }

    /* ---------------------------------------------------------------- *
     *                               views                               *
     * ---------------------------------------------------------------- */

    /// @notice Collateral price in USD, normalized to 18 decimals.
    function getPrice() external view returns (uint256) {
        return _price();
    }

    /// @notice USD value (18 dec) of a user's collateral.
    function collateralValue(address user) external view returns (uint256) {
        return (collateralOf[user] * _price()) / WAD;
    }

    /// @notice Largest debt the position can carry today, per the max LTV.
    function maxDebt(address user) external view returns (uint256) {
        return _maxDebt(collateralOf[user], _price());
    }

    /// @notice Stablecoin the user can still mint. Zero if already over the limit.
    function maxMintable(address user) external view returns (uint256) {
        uint256 limit = _maxDebt(collateralOf[user], _price());
        uint256 debt = debtOf[user];
        return debt >= limit ? 0 : limit - debt;
    }

    /// @notice Health factor with 18 decimals. Below 1e18 the position is liquidatable.
    /// @dev Returns `type(uint256).max` when there is no debt.
    function healthFactor(address user) external view returns (uint256) {
        return _healthFactor(collateralOf[user], debtOf[user], _price());
    }

    function isLiquidatable(address user) external view returns (bool) {
        uint256 debt = debtOf[user];
        if (debt == 0) return false;
        return _healthFactor(collateralOf[user], debt, _price()) < WAD;
    }

    /// @notice Current delegatee of a user's collateral.
    function delegateOf(address user) external view returns (address) {
        address account = accountOf[user];
        if (account == address(0)) return address(0);
        return DelegationAccount(account).currentDelegate();
    }

    /// @notice The whole position in a single call, for the frontend.
    function positionOf(address user)
        external
        view
        returns (
            address account,
            uint256 collateral,
            uint256 debt,
            uint256 collateralUsd,
            uint256 health,
            address delegatee
        )
    {
        account = accountOf[user];
        collateral = collateralOf[user];
        debt = debtOf[user];
        uint256 price = _price();
        collateralUsd = (collateral * price) / WAD;
        health = _healthFactor(collateral, debt, price);
        delegatee = account == address(0) ? address(0) : DelegationAccount(account).currentDelegate();
    }

    /// @notice Address a user's account would have, whether it exists yet or not.
    function predictAccountAddress(address user) external view returns (address) {
        return Clones.predictDeterministicAddress(accountImplementation, _salt(user), address(this));
    }

    /* ---------------------------------------------------------------- *
     *                          administration                           *
     * ---------------------------------------------------------------- */

    function setRiskParameters(
        uint256 maxLtvBps_,
        uint256 liquidationThresholdBps_,
        uint256 liquidationBonusBps_,
        uint256 closeFactorBps_
    ) external onlyOwner {
        _setRiskParameters(maxLtvBps_, liquidationThresholdBps_, liquidationBonusBps_, closeFactorBps_);
    }

    function setMaxPriceAge(uint256 maxPriceAge_) external onlyOwner {
        _setMaxPriceAge(maxPriceAge_);
    }

    /// @notice Freezes deposits, minting and liquidations.
    /// @dev `repay` and `withdraw` stay open on purpose: pausing must never be
    ///      able to hold anyone's collateral hostage.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ---------------------------------------------------------------- *
     *                             internals                             *
     * ---------------------------------------------------------------- */

    function _deposit(address user, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();

        address account = _accountFor(user);

        collateralOf[user] += amount;
        totalCollateral += amount;

        // Collateral travels to the user's own account, NOT to the vault. That
        // is what lets them keep their voting power.
        collateralToken.safeTransferFrom(user, account, amount);

        emit Deposited(user, account, amount);
    }

    function _mint(address user, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();

        uint256 newDebt = debtOf[user] + amount;
        uint256 limit = _maxDebt(collateralOf[user], _price());
        if (newDebt > limit) revert ExceedsMaxLtv(newDebt, limit);

        debtOf[user] = newDebt;
        totalDebt += amount;

        // The stablecoin goes to the user. In v1 it went to the delegation
        // account, which had no way to move it: it was stuck there forever.
        stablecoin.mint(user, amount);

        emit Minted(user, amount, newDebt);
    }

    function _repay(address payer, address user, uint256 amount) private returns (uint256 repaid) {
        uint256 debt = debtOf[user];
        if (debt == 0) revert NoDebt();

        repaid = amount > debt ? debt : amount;
        if (repaid == 0) revert ZeroAmount();

        uint256 newDebt = debt - repaid;
        debtOf[user] = newDebt;
        totalDebt -= repaid;

        stablecoin.burn(payer, repaid);

        emit Repaid(payer, user, repaid, newDebt);
    }

    function _withdraw(address user, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();

        uint256 collateral = collateralOf[user];
        if (amount > collateral) revert InsufficientCollateral();

        uint256 remaining = collateral - amount;
        collateralOf[user] = remaining;
        totalCollateral -= amount;

        uint256 debt = debtOf[user];
        if (debt != 0) {
            uint256 limit = _maxDebt(remaining, _price());
            if (debt > limit) revert ExceedsMaxLtv(debt, limit);
        }

        DelegationAccount(accountOf[user]).releaseCollateral(user, amount);

        emit Withdrawn(user, amount);
    }

    /// @dev Returns the user's account, creating it with CREATE2 if absent.
    function _accountFor(address user) private returns (address account) {
        account = accountOf[user];
        if (account != address(0)) return account;

        account = Clones.cloneDeterministic(accountImplementation, _salt(user));
        accountOf[user] = account;
        DelegationAccount(account).initialize(address(this), user, address(collateralToken));

        emit AccountOpened(user, account);
    }

    function _salt(address user) private pure returns (bytes32) {
        return bytes32(uint256(uint160(user)));
    }

    /// @dev Validated price, normalized to 18 decimals.
    function _price() private view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();

        if (answer <= 0) revert InvalidPrice(answer);
        // `block.timestamp` is safe here: the window is an hour and a validator
        // can only shift it by seconds. There is nothing to gain by moving it
        // within that margin.
        // forge-lint: disable-next-line(block-timestamp)
        if (updatedAt == 0 || block.timestamp - updatedAt > maxPriceAge) revert StalePrice(updatedAt, maxPriceAge);
        // Answer carried over from an earlier round: the feed is stuck.
        if (answeredInRound < roundId) revert StalePrice(updatedAt, maxPriceAge);

        // The cast to uint256 is safe because `answer <= 0` already reverted above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer) * priceScale;
    }

    /// @dev Largest debt allowed by the LTV. The division by WAD is the scaling
    ///      fix that v1 was missing. Everything is multiplied before dividing to
    ///      avoid losing precision.
    function _maxDebt(uint256 collateral, uint256 price) private view returns (uint256) {
        return (collateral * price * maxLtvBps) / (WAD * BPS);
    }

    function _healthFactor(uint256 collateral, uint256 debt, uint256 price) private view returns (uint256) {
        if (debt == 0) return type(uint256).max;
        uint256 adjusted = (collateral * price * liquidationThresholdBps) / (WAD * BPS);
        return (adjusted * WAD) / debt;
    }

    function _setRiskParameters(
        uint256 maxLtvBps_,
        uint256 liquidationThresholdBps_,
        uint256 liquidationBonusBps_,
        uint256 closeFactorBps_
    ) private {
        // The minting LTV must leave room before the liquidation threshold, or a
        // position would be born liquidatable.
        if (maxLtvBps_ == 0 || maxLtvBps_ > liquidationThresholdBps_) revert InvalidParameters();
        if (liquidationThresholdBps_ >= BPS) revert InvalidParameters();
        if (liquidationBonusBps_ > MAX_LIQUIDATION_BONUS_BPS) revert InvalidParameters();
        if (closeFactorBps_ == 0 || closeFactorBps_ > BPS) revert InvalidParameters();

        maxLtvBps = maxLtvBps_;
        liquidationThresholdBps = liquidationThresholdBps_;
        liquidationBonusBps = liquidationBonusBps_;
        closeFactorBps = closeFactorBps_;

        emit RiskParametersUpdated(maxLtvBps_, liquidationThresholdBps_, liquidationBonusBps_, closeFactorBps_);
    }

    function _setMaxPriceAge(uint256 maxPriceAge_) private {
        if (maxPriceAge_ < MIN_PRICE_AGE || maxPriceAge_ > MAX_PRICE_AGE) revert InvalidParameters();
        maxPriceAge = maxPriceAge_;
        emit MaxPriceAgeUpdated(maxPriceAge_);
    }
}
