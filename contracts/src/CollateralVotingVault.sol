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
/// @notice CDP sobrecolateralizado que conserva el poder de voto del colateral.
/// @dev Un solo contrato parametrizado por constructor sirve a cualquier token
///      ERC20Votes con un feed de Chainlink. La v1 tenia una copia por cadena y
///      las copias divergieron.
///
///      Convenciones de decimales, fijadas de una vez:
///        - el colateral se asume de 18 decimales (se verifica en el constructor);
///        - el precio se normaliza SIEMPRE a 18 decimales (`_price`);
///        - la deuda y la stablecoin son de 18 decimales;
///        - valor en USD (18 dec) = cantidad(18) * precio(18) / 1e18.
///      Esa division final por 1e18 es la que faltaba en la v1 y hacia que se
///      emitieran 1e18 veces mas stablecoins de las debidas.
contract CollateralVotingVault is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    /// @notice Cota dura del bono de liquidacion, para que el owner no pueda
    ///         configurar un parametro que confisque posiciones sanas.
    uint256 public constant MAX_LIQUIDATION_BONUS_BPS = 2_000;
    uint256 public constant MIN_PRICE_AGE = 1 minutes;
    uint256 public constant MAX_PRICE_AGE = 7 days;

    /* ---------------------------------------------------------------- *
     *                        configuracion inmutable                    *
     * ---------------------------------------------------------------- */

    /// @notice Token de gobernanza aceptado como colateral (debe ser ERC20Votes).
    IERC20 public immutable collateralToken;
    /// @notice Feed de precio del colateral en USD.
    IAggregatorV3 public immutable priceFeed;
    /// @notice Stablecoin emitida contra este colateral.
    GovStablecoin public immutable stablecoin;
    /// @notice Molde EIP-1167 del que se clonan las cuentas de delegacion.
    address public immutable accountImplementation;
    /// @dev Multiplicador que lleva el precio del feed a 18 decimales.
    uint256 private immutable priceScale;

    /* ---------------------------------------------------------------- *
     *                       parametros de riesgo                        *
     * ---------------------------------------------------------------- */

    /// @notice LTV maximo al emitir o retirar. 5000 = 50%.
    uint256 public maxLtvBps;
    /// @notice LTV a partir del cual la posicion es liquidable. 7500 = 75%.
    uint256 public liquidationThresholdBps;
    /// @notice Descuento que se lleva el liquidador. 1000 = 10%.
    uint256 public liquidationBonusBps;
    /// @notice Fraccion maxima de la deuda cubrible en una sola liquidacion.
    uint256 public closeFactorBps;
    /// @notice Antiguedad maxima tolerada del precio del oraculo.
    uint256 public maxPriceAge;

    /* ---------------------------------------------------------------- *
     *                              estado                               *
     * ---------------------------------------------------------------- */

    /// @notice Colateral depositado por usuario.
    mapping(address user => uint256 amount) public collateralOf;
    /// @notice Deuda viva por usuario, denominada en la stablecoin.
    mapping(address user => uint256 amount) public debtOf;
    /// @notice Cuenta de delegacion de cada usuario (cero si aun no tiene).
    mapping(address user => address account) public accountOf;

    uint256 public totalCollateral;
    uint256 public totalDebt;

    /* ---------------------------------------------------------------- *
     *                              eventos                              *
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
     *                              errores                              *
     * ---------------------------------------------------------------- */

    error ZeroAddress();
    error ZeroAmount();
    error UnsupportedDecimals();
    error InvalidParameters();
    error NoAccount();
    error NoDebt();
    error InsufficientCollateral();
    /// @param debt deuda resultante; @param maxDebtAllowed maximo permitido por el LTV
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
     *                       operaciones de usuario                      *
     * ---------------------------------------------------------------- */

    /// @notice Crea por adelantado la cuenta de delegacion de quien llama.
    /// @dev Opcional: `deposit` la crea sola. Sirve para delegar antes de depositar.
    function openAccount() external whenNotPaused returns (address) {
        return _accountFor(msg.sender);
    }

    /// @notice Deposita colateral en la cuenta de delegacion propia.
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        _deposit(msg.sender, amount);
    }

    /// @notice Emite stablecoin contra el colateral ya depositado.
    function mint(uint256 amount) external nonReentrant whenNotPaused {
        _mint(msg.sender, amount);
    }

    /// @notice Deposita y emite en una sola transaccion.
    /// @param mintAmount puede ser 0 para depositar sin endeudarse.
    function depositAndMint(uint256 collateralAmount, uint256 mintAmount) external nonReentrant whenNotPaused {
        _deposit(msg.sender, collateralAmount);
        if (mintAmount != 0) _mint(msg.sender, mintAmount);
    }

    /// @notice Repaga deuda propia quemando stablecoin.
    /// @dev Si `amount` supera la deuda se ajusta a la deuda; pasar
    ///      `type(uint256).max` repaga todo sin necesidad de leerla antes.
    function repay(uint256 amount) external nonReentrant returns (uint256 repaid) {
        return _repay(msg.sender, msg.sender, amount);
    }

    /// @notice Repaga la deuda de otro usuario. Util para rescatar una posicion.
    function repayFor(address user, uint256 amount) external nonReentrant returns (uint256 repaid) {
        return _repay(msg.sender, user, amount);
    }

    /// @notice Retira colateral, siempre que la posicion siga bajo el LTV maximo.
    function withdraw(uint256 amount) external nonReentrant {
        _withdraw(msg.sender, amount);
    }

    /// @notice Repaga y retira en una sola transaccion.
    function repayAndWithdraw(uint256 repayAmount, uint256 withdrawAmount) external nonReentrant {
        if (repayAmount != 0) _repay(msg.sender, msg.sender, repayAmount);
        if (withdrawAmount != 0) _withdraw(msg.sender, withdrawAmount);
    }

    /// @notice Redirige el poder de voto del colateral propio.
    /// @dev Se puede llamar con deuda viva: delegar no mueve fondos ni afecta la
    ///      salud de la posicion. Esa es justamente la propuesta del protocolo.
    function delegate(address delegatee) external {
        address account = accountOf[msg.sender];
        if (account == address(0)) revert NoAccount();
        DelegationAccount(account).delegate(delegatee);
        emit DelegateChanged(msg.sender, delegatee);
    }

    /// @notice Liquida una posicion cuyo health factor cayo por debajo de 1e18.
    /// @param debtToCover deuda que el liquidador cubre; se recorta al close factor.
    /// @return seized colateral entregado al liquidador, bono incluido.
    function liquidate(address user, uint256 debtToCover) external nonReentrant whenNotPaused returns (uint256 seized) {
        uint256 price = _price();
        uint256 debt = debtOf[user];
        if (debt == 0) revert NoDebt();

        uint256 hf = _healthFactor(collateralOf[user], debt, price);
        if (hf >= WAD) revert PositionHealthy(hf);

        uint256 maxRepay = (debt * closeFactorBps) / BPS;
        if (debtToCover > maxRepay) debtToCover = maxRepay;
        if (debtToCover == 0) revert ZeroAmount();

        // Colateral a incautar = valor de la deuda cubierta + bono, en tokens.
        seized = (debtToCover * (BPS + liquidationBonusBps) * WAD) / (BPS * price);

        uint256 collateral = collateralOf[user];
        // Posicion insolvente: el liquidador se lleva todo lo que queda y el
        // resto de la deuda se sigue debiendo. Sin este tope, `releaseCollateral`
        // revertiria y la posicion mala quedaria sin poder cerrarse nunca.
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
     *                              vistas                               *
     * ---------------------------------------------------------------- */

    /// @notice Precio del colateral en USD, normalizado a 18 decimales.
    function getPrice() external view returns (uint256) {
        return _price();
    }

    /// @notice Valor en USD (18 dec) del colateral de un usuario.
    function collateralValue(address user) external view returns (uint256) {
        return (collateralOf[user] * _price()) / WAD;
    }

    /// @notice Deuda maxima que soporta hoy la posicion, segun el LTV maximo.
    function maxDebt(address user) external view returns (uint256) {
        return _maxDebt(collateralOf[user], _price());
    }

    /// @notice Stablecoin que el usuario todavia puede emitir. Cero si ya excede.
    function maxMintable(address user) external view returns (uint256) {
        uint256 limit = _maxDebt(collateralOf[user], _price());
        uint256 debt = debtOf[user];
        return debt >= limit ? 0 : limit - debt;
    }

    /// @notice Health factor con 18 decimales. Por debajo de 1e18 es liquidable.
    /// @dev Sin deuda devuelve `type(uint256).max`.
    function healthFactor(address user) external view returns (uint256) {
        return _healthFactor(collateralOf[user], debtOf[user], _price());
    }

    function isLiquidatable(address user) external view returns (bool) {
        uint256 debt = debtOf[user];
        if (debt == 0) return false;
        return _healthFactor(collateralOf[user], debt, _price()) < WAD;
    }

    /// @notice Delegatee actual del colateral de un usuario.
    function delegateOf(address user) external view returns (address) {
        address account = accountOf[user];
        if (account == address(0)) return address(0);
        return DelegationAccount(account).currentDelegate();
    }

    /// @notice Posicion completa en una sola llamada, para el frontend.
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

    /// @notice Direccion que tendria la cuenta de un usuario, la tenga o no ya.
    function predictAccountAddress(address user) external view returns (address) {
        return Clones.predictDeterministicAddress(accountImplementation, _salt(user), address(this));
    }

    /* ---------------------------------------------------------------- *
     *                          administracion                           *
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

    /// @notice Congela deposito, emision y liquidacion.
    /// @dev `repay` y `withdraw` siguen abiertos a proposito: pausar no debe
    ///      poder secuestrar el colateral de nadie.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ---------------------------------------------------------------- *
     *                             internos                              *
     * ---------------------------------------------------------------- */

    function _deposit(address user, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();

        address account = _accountFor(user);

        collateralOf[user] += amount;
        totalCollateral += amount;

        // El colateral viaja a la cuenta del usuario, NO al vault: es lo que
        // permite que conserve su poder de voto.
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

        // La stablecoin va al usuario. En la v1 iba a la cuenta de delegacion,
        // que no tenia forma de moverla: quedaba atrapada para siempre.
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

    /// @dev Devuelve la cuenta del usuario, creandola con CREATE2 si no existe.
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

    /// @dev Precio validado y normalizado a 18 decimales.
    function _price() private view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();

        if (answer <= 0) revert InvalidPrice(answer);
        // `block.timestamp` es seguro aqui: la ventana es de una hora y un
        // validador solo puede desviarla unos segundos. No hay nada que ganar
        // moviendola dentro de ese margen.
        // forge-lint: disable-next-line(block-timestamp)
        if (updatedAt == 0 || block.timestamp - updatedAt > maxPriceAge) revert StalePrice(updatedAt, maxPriceAge);
        // Respuesta arrastrada de una ronda anterior: el feed esta atascado.
        if (answeredInRound < roundId) revert StalePrice(updatedAt, maxPriceAge);

        // El cast a uint256 es seguro porque `answer <= 0` ya revirtio arriba.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer) * priceScale;
    }

    /// @dev Deuda maxima permitida por el LTV. La division por WAD es la
    ///      correccion de escala que faltaba en la v1.
    ///      Se multiplica todo antes de dividir para no perder precision.
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
        // El LTV de emision debe dejar margen antes del umbral de liquidacion,
        // o una posicion naceria liquidable.
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
