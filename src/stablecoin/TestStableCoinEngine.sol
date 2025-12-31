// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TestStableCoin} from "./TestStableCoin.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title TestStableCoinEngine
 * @author cristianrisueo
 * @notice Motor del protocolo de stablecoin overcollateralizada
 * @dev Este contrato maneja toda la lógica de:
 * - Depósito y retiro de colateral (WETH)
 * - Acuñación y quema de stablecoins (TSC)
 * - Liquidaciones de posiciones insolventes
 * - Cálculo de health factors
 * - Fondo de seguro para cubrir el bad debt
 *
 * El sistema está diseñado para mantener 1 TSC = 1 USD mediante:
 * - Overcollateralización del 200% (soporta caídas de hasta ~25-33% antes de entrar en riesgo)
 * - Liquidaciones automáticas cuando health factor < 1
 * - Uso de Chainlink oracles para pricing en tiempo real
 * - Insurance fund que cobra fees en el minting y cubre el bad debt en las liquidaciones
 *
 * IMPORTANTE: Este protocolo es algorítmico y descentralizado.
 * - Tiene gobernanza on-chain mediante TSCGovernor + TSCTimelock
 * - Parámetros críticos (liquidation threshold, bonus, mint fee) son gobernables
 * - Depende completamente de la overcollateralización para mantener el peg
 */
contract TestStableCoinEngine is ReentrancyGuard, Ownable {
    //* Errores

    /**
     * @dev Error que se lanza cuando se proporciona una dirección inválida (0x0)
     */
    error TestStableCoinEngine__InvalidAddress();

    /**
     * @dev Error que se lanza cuando se intenta operar con una cantidad igual a cero
     */
    error TestStableCoinEngine__NeedsMoreThanZero();

    /**
     * @dev Error que se lanza cuando una transferencia de tokens falla
     */
    error TestStableCoinEngine__TransferFailed();

    /**
     * @dev Error que se lanza cuando una operación (acuñación) rompería el health factor mínimo
     * @param healthFactor El health factor resultante que causó el error
     */
    error TestStableCoinEngine__BreaksHealthFactor(uint256 healthFactor);

    /**
     * @dev Error que se lanza cuando la acuñación de tokens falla
     */
    error TestStableCoinEngine__MintFailed();

    /**
     * @dev Error que se lanza cuando se intenta liquidar un usuario con health factor >= 1
     */
    error TestStableCoinEngine__HealthFactorOk();

    /**
     * @dev Error que se lanza cuando se intenta configurar parámetros de gobernanza con valores inválidos
     */
    error TestStableCoinEngine__InvalidGovernanceParameter();

    /**
     * @dev Error lanzado cuando la liquidación falla en alcanzar el target health factor
     */
    error TestStableCoinEngine__HealthFactorStillBroken();

    /**
     * @dev Error lanzado cuando el fondo de seguro no tiene suficientes fondos para cubrir bad debt
     */
    error TestStableCoinEngine__InsufficientInsuranceFunds();

    /**
     * @dev Error lanzado cuando el cambio propuesto excede el máximo permitido
     * Previene cambios drásticos en parámetros gobernables
     */
    error TestStableCoinEngine__ChangeExceedsMaximum();

    /**
     * @dev Error lanzado cuando no ha pasado suficiente tiempo desde el último cambio
     * Enforza MIN_CHANGE_COOLDOWN entre actualizaciones del mismo parámetro
     */
    error TestStableCoinEngine__CooldownNotElapsed();

    //* Tipos

    using OracleLib for AggregatorV3Interface;

    //* Constantes (no gobernables por seguridad)

    /**
     * @dev Factor de salud mínimo permitido (con 18 decimales)
     * 1e18 = 1.0, por debajo de esto la posición puede ser liquidada
     * INMUTABLE: Cambiar esto podría causar liquidaciones masivas o insolvencia
     */
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    /**
     * @dev Precisión usada en todos los cálculos (18 decimales)
     * INMUTABLE: Cambiar esto rompería todos los cálculos del protocolo
     */
    uint256 private constant PRECISION = 1e18;

    /**
     * @dev Número de decimales adicionales del price feed de Chainlink
     * ETH/USD price feed retorna precios con 8 decimales. Añadimos 10
     * INMUTABLE: Depende del formato del oracle, no debe cambiar
     */
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;

    /**
     * @dev Precisión para el cálculo del bonus de liquidación
     * INMUTABLE: Base matemática, no debe cambiar
     */
    uint256 private constant LIQUIDATION_PRECISION = 100;

    /**
     * @dev Precisión para el cálculo de fees en basis points
     * 10000 basis points = 100%
     * INMUTABLE: Base matemática, no debe cambiar
     */
    uint256 private constant BASIS_POINTS = 10000;

    /**
     * @dev Cambio máximo permitido en liquidationThreshold por propuesta (puntos)
     * Ejemplo: Si threshold = 50, solo puede cambiar a 45-55
     * INMUTABLE: Protección contra ataques de governance. Se puede cambiar, pero no mucho de una vez
     */
    uint256 private constant MAX_THRESHOLD_CHANGE = 5;

    /**
     * @dev Cambio máximo permitido en liquidationBonus por propuesta (puntos)
     * Ejemplo: Si bonus = 10, solo puede cambiar a 8-12
     * INMUTABLE: Protección contra ataques de governance. Se puede cambiar, pero no mucho de una vez
     */
    uint256 private constant MAX_BONUS_CHANGE = 2;

    /**
     * @dev Cambio máximo permitido en targetHealthFactor por propuesta (con 18 decimales)
     * 0.1e18 = 0.1, permite cambios de ±0.1 (ej: 1.25 → 1.15 o 1.35)
     * INMUTABLE: Protección contra ataques de governance. Se puede cambiar, pero no mucho de una vez
     */
    uint256 private constant MAX_TARGET_HF_CHANGE = 0.1e18;

    /**
     * @dev Cambio máximo permitido en mintFee por propuesta (basis points)
     * Ejemplo: Si fee = 20 bps, solo puede cambiar a 15-25 bps
     * INMUTABLE: Protección contra ataques de governance. Se puede cambiar, pero no mucho de una vez
     */
    uint256 private constant MAX_MINT_FEE_CHANGE = 5;

    /**
     * @dev Tiempo mínimo entre cambios del mismo parámetro (15 días)
     * Previene cambios rápidos consecutivos que puedan desestabilizar el protocolo
     * INMUTABLE: Protección contra ataques de governance
     */
    uint256 private constant MIN_CHANGE_COOLDOWN = 15 days;

    //* Variables Inmutables (referencias a otros contratos)

    /**
     * @dev Referencia al token WETH (ERC20)
     */
    IERC20 private immutable i_weth;

    /**
     * @dev Referencia al contrato TestStableCoin
     */
    TestStableCoin private immutable i_tsc;

    /**
     * @dev Referencia al price feed de Chainlink para WETH/USD
     */
    AggregatorV3Interface private immutable i_priceFeed;

    //* Parámetros Gobernables (pueden ser modificados por gobernanza)

    /**
     * @dev Umbral de liquidación: 50 significa 50%
     * Esto se traduce en 200% de colateralización requerida
     * Ejemplo: $100 de colateral permite acuñar máximo $50 de TSC
     *
     * GOBERNABLE: La gobernanza puede ajustar entre 20-80 para gestionar riesgo
     * - Más alto = protocolo más seguro, menos capital efficient
     * - Más bajo = protocolo más arriesgado, más capital efficient
     */
    uint256 private s_liquidationThreshold = 50;

    /**
     * @dev Bonus que recibe el liquidador: 10 significa 10%
     * Incentiva a los liquidadores a mantener el protocolo solvente
     *
     * GOBERNABLE: La gobernanza puede ajustar entre 5-20 para optimizar incentivos
     * - Más alto = más incentivo para liquidadores, más costoso para liquidados
     * - Más bajo = menos incentivo, riesgo de liquidaciones lentas
     */
    uint256 private s_liquidationBonus = 10;

    /**
     * @dev Health factor objetivo a restaurar tras liquidación parcial
     * 1.25e18 = 1.25 con precisión de 18 decimales
     * Proporciona un buffer de seguridad por encima del mínimo (1.0)
     *
     * GOBERNABLE: La gobernanza puede ajustar entre 1.1 - 1.5 para gestionar agresividad de liquidación
     * - Más alto (1.5) = liquidaciones más agresivas, mayor buffer de seguridad
     * - Más bajo (1.1) = liquidaciones más conservadoras, menor impacto en usuarios
     */
    uint256 private s_targetHealthFactor = 1.25e18;

    /**
     * @dev Mint fee en basis points (20 = 0.2%)
     * Fee cobrada en cada operación de mint de TSC para financiar el fondo de seguro
     *
     * GOBERNABLE: La gobernanza puede ajustar entre 5-50 basis points
     * - Más bajo (5 bps = 0.05%) = menos seguro, más atractivo para usuarios
     * - Más alto (50 bps = 0.5%) = más seguro, menos atractivo para usuarios
     */
    uint256 private s_mintFee = 20;

    //* Variables de estado no gobernables

    /**
     * @dev Timestamp del último cambio de liquidationThreshold
     * Usado para enforcar MIN_CHANGE_COOLDOWN entre actualizaciones
     */
    uint256 private s_lastThresholdUpdate;

    /**
     * @dev Timestamp del último cambio de liquidationBonus
     * Usado para enforcar MIN_CHANGE_COOLDOWN entre actualizaciones
     */
    uint256 private s_lastBonusUpdate;

    /**
     * @dev Timestamp del último cambio de targetHealthFactor
     * Usado para enforcar MIN_CHANGE_COOLDOWN entre actualizaciones
     */
    uint256 private s_lastTargetHFUpdate;

    /**
     * @dev Timestamp del último cambio de mintFee
     * Usado para enforcar MIN_CHANGE_COOLDOWN entre actualizaciones
     */
    uint256 private s_lastMintFeeUpdate;

    /**
     * @dev Balance del fondo de seguro en USD (18 decimales)
     * Acumula las fees de mint para cubrir bad debt durante liquidaciones
     * Cuando ocurre bad debt, este fondo asegura que los liquidadores reciban su bonus completo
     *
     * NO GOBERNABLE: Es un acumulador que crece con las fees, no un parámetro ajustable
     */
    uint256 private s_insuranceFund;

    /**
     * @dev Mapeo de usuario a cantidad de WETH depositado como colateral
     */
    mapping(address user => uint256 amountWethDeposited) private s_collateralDeposited;

    /**
     * @dev Mapeo de usuario a cantidad de TSC acuñado
     */
    mapping(address user => uint256 amountTscMinted) private s_stablecoinMinted;

    //* Eventos

    /**
     * @dev Emitido cuando un usuario deposita colateral
     * @param user Dirección del usuario que deposita
     * @param amountCollateral Cantidad de WETH depositado (en wei)
     */
    event CollateralDeposited(address indexed user, uint256 indexed amountCollateral);

    /**
     * @dev Emitido cuando se rescata colateral
     * @param redeemedFrom Usuario del cual se retira el colateral (owner original)
     * @param redeemedTo Usuario que recibe el colateral (puede ser diferente en liquidaciones)
     * @param amountCollateral Cantidad de WETH rescatado (en wei, 18 decimales)
     */
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, uint256 amountCollateral);

    /**
     * @dev Emitido cuando se liquida una posición con bad debt usando el fondo de seguridad
     * @param user Dirección del usuario liquidado que tenía bad debt
     * @param totalDebt Cantidad total de deuda en TSC que fue liquidada (100% de la deuda)
     * @param insuranceUsed Cantidad en TSC del fondo de seguridad usada para cubrir el shortfall
     */
    event BadDebtTotalLiquidation(address indexed user, uint256 totalDebt, uint256 insuranceUsed);

    /**
     * @dev Emitido cuando la gobernanza actualiza el umbral de liquidación
     * @param oldThreshold Valor anterior del threshold
     * @param newThreshold Nuevo valor del threshold
     */
    event LiquidationThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /**
     * @dev Emitido cuando la gobernanza actualiza el bonus de liquidación
     * @param oldBonus Valor anterior del bonus
     * @param newBonus Nuevo valor del bonus
     */
    event LiquidationBonusUpdated(uint256 oldBonus, uint256 newBonus);

    /**
     * @dev Emitido cuando la gobernanza actualiza el target health factor
     * @param oldTarget Valor anterior del target health factor
     * @param newTarget Nuevo valor del target health factor
     */
    event TargetHealthFactorUpdated(uint256 oldTarget, uint256 newTarget);

    /**
     * @dev Emitido cuando la gobernanza actualiza la mint fee
     * @param oldFee Valor anterior de la fee (en basis points)
     * @param newFee Nuevo valor de la fee (en basis points)
     */
    event MintFeeUpdated(uint256 oldFee, uint256 newFee);

    //* Modifiers

    /**
     * @dev Modifier que verifica que la cantidad sea mayor a cero
     * @param amount La cantidad a verificar
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert TestStableCoinEngine__NeedsMoreThanZero();
        }

        _;
    }

    //* Constructor

    /**
     * @notice Constructor del Engine (en un principio en Sepolia)
     * @param wethAddress Dirección del contrato WETH en la red
     * @param tscAddress Dirección del contrato TestStableCoin
     * @param priceFeedAddress Dirección del Chainlink price feed WETH/USD
     * @param initialOwner Dirección del owner inicial (el Timelock para gobernanza)
     */
    constructor(address wethAddress, address tscAddress, address priceFeedAddress, address initialOwner)
        Ownable(initialOwner)
    {
        // Validar direcciones de contratos no nulas
        if (wethAddress == address(0) || tscAddress == address(0) || priceFeedAddress == address(0)) {
            revert TestStableCoinEngine__InvalidAddress();
        }

        // Inicializa referencias a contratos externos
        i_weth = IERC20(wethAddress);
        i_tsc = TestStableCoin(tscAddress);
        i_priceFeed = AggregatorV3Interface(priceFeedAddress);

        // Inicializar timestamps para permitir cambios de gobernanza inmediatos
        s_lastThresholdUpdate = block.timestamp - MIN_CHANGE_COOLDOWN;
        s_lastBonusUpdate = block.timestamp - MIN_CHANGE_COOLDOWN;
        s_lastTargetHFUpdate = block.timestamp - MIN_CHANGE_COOLDOWN;
        s_lastMintFeeUpdate = block.timestamp - MIN_CHANGE_COOLDOWN;
    }

    //* Lógica de negocio. Funciones externas y públicas

    /**
     * @notice Deposita colateral WETH y acuña TSC en una sola transacción
     * @param amountCollateral Cantidad de WETH a depositar
     * @param amountTscToMint Cantidad de TSC a acuñar
     * @dev Esta función combina depositCollateral y mintTsc para mejor UX
     */
    function depositCollateralAndMintTsc(uint256 amountCollateral, uint256 amountTscToMint) external {
        depositCollateral(amountCollateral);
        mintTsc(amountTscToMint);
    }

    /**
     * @notice Deposita WETH como colateral
     * @param amountCollateral Cantidad de WETH a depositar
     * @dev El usuario debe aprobar primero la transferencia de WETH a este contrato
     */
    function depositCollateral(uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant {
        s_collateralDeposited[msg.sender] += amountCollateral;
        emit CollateralDeposited(msg.sender, amountCollateral);

        bool success = i_weth.transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert TestStableCoinEngine__TransferFailed();
        }
    }

    /**
     * @notice Acuña TestStableCoins contra el colateral depositado
     * @param amountTscToMint Cantidad BRUTA de TSC que el usuario solicita (antes de fees)
     * @dev Cobra un fee de minting que va al fondo de seguridad contra bad debt
     * @dev El usuario recibe: amountTscToMint - fee
     * @dev La deuda registrada es el monto NETO (lo que realmente recibe el usuario)
     * @dev Revierte si el health factor resultante es menor a MIN_HEALTH_FACTOR
     */
    function mintTsc(uint256 amountTscToMint) public moreThanZero(amountTscToMint) nonReentrant {
        // Calcula la fee y el monto neto a mintear
        uint256 fee = (amountTscToMint * s_mintFee) / BASIS_POINTS;
        uint256 netAmount = amountTscToMint - fee;

        // Registra solo el monto NETO como deuda del usuario
        s_stablecoinMinted[msg.sender] += netAmount;

        // Añade la fee al fondo de seguridad (valor en USD con 18 decimales)
        s_insuranceFund += fee;

        // Verifica que el health factor permanece saludable
        _revertIfHealthFactorIsBroken(msg.sender);

        // Mintea solo el monto NETO al usuario (la fee no se mintea, solo se contabiliza)
        bool minted = i_tsc.mint(msg.sender, netAmount);
        if (!minted) {
            revert TestStableCoinEngine__MintFailed();
        }
    }

    /**
     * @notice Rescata colateral y quema TSC en una sola transacción
     * @param amountCollateral Cantidad de WETH a rescatar
     * @param amountTscToBurn Cantidad de TSC a quemar
     * @dev Esta función permite al usuario salir de su posición en una transacción
     */
    function redeemCollateralForTsc(uint256 amountCollateral, uint256 amountTscToBurn) external {
        burnTsc(amountTscToBurn);
        redeemCollateral(amountCollateral);
    }

    /**
     * @notice Quema TestStableCoins
     * @param amount Cantidad de TSC a quemar
     * @dev Reduce la deuda del usuario, permitiendo rescatar más colateral
     */
    function burnTsc(uint256 amount) public moreThanZero(amount) {
        _burnTsc(amount, msg.sender, msg.sender);
    }

    /**
     * @notice Rescata colateral depositado
     * @param amountCollateral Cantidad de WETH a rescatar
     * @dev Revierte si el health factor resultante es menor a MIN_HEALTH_FACTOR
     */
    function redeemCollateral(uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(msg.sender, msg.sender, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Liquida parcialmente una posición insolvente o totalmente en caso de bad debt
     * @param user Dirección del usuario a liquidar
     * @dev El liquidador recibe el colateral correspondiente a la deuda cubierta + bonus (en WETH)
     * @dev Liquida SOLO la cantidad necesaria para restaurar el health factor a s_targetHealthFactor
     * @dev Solo se puede liquidar si el health factor del usuario es < 1
     * @dev Si el colateral del usuario no alcanza para cubrir deuda + bonus, se usa el fondo de seguridad
     *
     * Ejemplo de liquidación parcial:
     * - Usuario tiene 10 WETH de colateral ($20,000) y $16,000 de deuda (HF = 0.625)
     * - Cálculo determina que liquidar $8,000 restaura HF a s_targetHealthFactor
     * - Colateral para $8,000: 4 WETH
     * - Bonus: 4 × 10% = 0.4 WETH
     * - Liquidador paga: $8,000 en TSC y recibe: 4.4 WETH
     * - Usuario queda con: 5.6 WETH, $8,000 de deuda y HF = s_targetHealthFactor
     */
    function liquidate(address user) external nonReentrant {
        // Comprueba que el usuario es liquidable (health factor < 1)
        uint256 initialHealthFactor = _healthFactor(user);

        if (initialHealthFactor >= MIN_HEALTH_FACTOR) {
            revert TestStableCoinEngine__HealthFactorOk();
        }

        // Obtiene la deuda en TSC y el valor del colateral en USD
        uint256 totalDebt = s_stablecoinMinted[user];
        uint256 totalCollateralValue = getAccountCollateralValue(user);

        // Calcula la deuda a cubrir para alcanzar el target HF
        uint256 debtToCover = _calculateDebtToCover(totalDebt, totalCollateralValue);

        // Calcula la deuda del usuario en WETH y el colateral el colateral total a redimir (deuda + bonus)
        uint256 tokenAmountFromDebt = getTokenAmountFromUsd(debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebt * s_liquidationBonus) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebt + bonusCollateral;

        // Obtiene el colateral total del usuario
        uint256 userCollateral = s_collateralDeposited[user];

        // Si el usuario no tiene suficiente colateral, es bad debt (liquidación total con insurance fund)
        if (totalCollateralToRedeem > userCollateral) {
            _liquidateTotalWithInsurance(user, totalDebt, userCollateral);
        } else {
            _liquidatePartial(user, debtToCover, totalCollateralToRedeem);
        }

        // Comprueba que el health factor del usuario liquidado ha llegado al target
        uint256 finalHealthFactor = _healthFactor(user);

        if (finalHealthFactor <= s_targetHealthFactor) {
            revert TestStableCoinEngine__HealthFactorStillBroken();
        }

        // Comprueba que el health factor del liquidador no se ha roto (<1)
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //* Lógica de negocio. Funciones privadas e internas

    /**
     * @dev Función interna para quemar TSC
     * @param amountTscToBurn Cantidad de TSC a quemar
     * @param onBehalfOf Usuario cuya deuda se está reduciendo
     * @param tscFrom Usuario del cual se toman los tokens TSC
     */
    function _burnTsc(uint256 amountTscToBurn, address onBehalfOf, address tscFrom) private {
        s_stablecoinMinted[onBehalfOf] -= amountTscToBurn;

        bool success = i_tsc.transferFrom(tscFrom, address(this), amountTscToBurn);
        if (!success) {
            revert TestStableCoinEngine__TransferFailed();
        }

        i_tsc.burn(amountTscToBurn);
    }

    /**
     * @dev Función interna para rescatar colateral
     * @param from Usuario del cual se toma el colateral
     * @param to Usuario que recibe el colateral
     * @param amountCollateral Cantidad de WETH a transferir
     */
    function _redeemCollateral(address from, address to, uint256 amountCollateral) private {
        s_collateralDeposited[from] -= amountCollateral;
        emit CollateralRedeemed(from, to, amountCollateral);

        bool success = i_weth.transfer(to, amountCollateral);
        if (!success) {
            revert TestStableCoinEngine__TransferFailed();
        }
    }

    /**
     * @dev Ejecuta liquidación parcial (colateral del usuario suficiente para cubrir deuda + bonus)
     * @param user Usuario a liquidar
     * @param debtToCover Cantidad de deuda a cubrir
     * @param collateralToRedeem Cantidad de colateral a transferir al liquidador (deuda + bonus)
     */
    function _liquidatePartial(address user, uint256 debtToCover, uint256 collateralToRedeem) private {
        // El liquidador paga la deuda total del usuario
        _burnTsc(debtToCover, user, msg.sender);

        // El liquidador recibe el colateral correspondiente (deuda + bonus)
        _redeemCollateral(user, msg.sender, collateralToRedeem);
    }

    /**
     * @dev Ejecuta liquidación total usando insurance fund para cubrir lo que falte del bad debt
     * @param user Usuario a liquidar
     * @param totalDebt Deuda total del usuario (100%)
     * @param userCollateral Colateral total disponible del usuario
     */
    function _liquidateTotalWithInsurance(address user, uint256 totalDebt, uint256 userCollateral) private {
        // Calcula la cantidad de deuda en colateral
        uint256 tokenAmountFromDebt = getTokenAmountFromUsd(totalDebt);

        // Calcula el colateral total necesario (deuda + bonus)
        uint256 bonusCollateral = (tokenAmountFromDebt * s_liquidationBonus) / LIQUIDATION_PRECISION;
        uint256 totalCollateralNeeded = tokenAmountFromDebt + bonusCollateral;

        // Calcula el colateral necesario y el que tiene el usuario en USD (o TSC)
        uint256 collateralValueNeeded = getUsdValue(totalCollateralNeeded);
        uint256 collateralValueAvailable = getUsdValue(userCollateral);

        // Calcula el shortfall (diferencia entre necesario y disponible)
        uint256 shortfall = collateralValueNeeded - collateralValueAvailable;

        // Comprueba que el insurance fund tiene fondos suficientes (más nos vale)
        if (s_insuranceFund < shortfall) {
            revert TestStableCoinEngine__InsufficientInsuranceFunds();
        }

        // Actualiza el state del insurance fund para quitar el shortfall y emite evento
        s_insuranceFund -= shortfall;

        emit BadDebtTotalLiquidation(user, totalDebt, shortfall);

        // El liquidador paga la deuda total del usuario
        _burnTsc(totalDebt, user, msg.sender);

        // El liquidador recibe todo el colateral del usuario
        _redeemCollateral(user, msg.sender, userCollateral);

        // El fondo de seguridad compensa el shortfall (en TSC) al liquidador
        bool minted = i_tsc.mint(msg.sender, shortfall);
        if (!minted) {
            revert TestStableCoinEngine__MintFailed();
        }
    }

    /**
     * @dev Obtiene información de la cuenta del usuario
     * @param user Dirección del usuario
     * @return totalTscMinted Cantidad total de TSC acuñado por el usuario
     * @return collateralValueInUsd Valor total del colateral en USD
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalTscMinted, uint256 collateralValueInUsd)
    {
        totalTscMinted = s_stablecoinMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @dev Calcula el health factor de un usuario
     * @param user Dirección del usuario
     * @return El health factor con 18 decimales (1e18 = 1.0)
     *
     * Health Factor = (Colateral ajustado por umbral) / Deuda total
     *
     * Si health factor < 1, el usuario puede ser liquidado
     * Si health factor >= 1, el usuario está seguro
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalTscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        return _calculateHealthFactor(totalTscMinted, collateralValueInUsd);
    }

    /**
     * @dev Calcula el health factor dados los valores de deuda y colateral
     * @dev Con más florituras, pero la fórmula es HF = (T.Colateral * Límite liq.) / T.Minteado
     * @param totalTscMinted Cantidad de TSC acuñado
     * @param collateralValueInUsd Valor del colateral en USD
     * @return El health factor calculado
     */
    function _calculateHealthFactor(uint256 totalTscMinted, uint256 collateralValueInUsd)
        internal
        view
        returns (uint256)
    {
        if (totalTscMinted == 0) return type(uint256).max;

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * s_liquidationThreshold) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalTscMinted;
    }

    /**
     * @dev Calcula la cantidad de deuda a cubrir para restaurar el health factor del usuario al objetivo
     * @param totalDebt Deuda total del usuario en USD (18 decimales)
     * @param totalCollateralValue Valor total del colateral en USD (18 decimales)
     * @return debtToCover Cantidad de deuda a cubrir en USD para alcanzar s_targetHealthFactor
     *
     * Derivación de la fórmula:
     * Objetivo: (colateral_final × threshold) / deuda_final = target HF
     *
     * Casos especiales:
     * - Retorna 0 si el cálculo da negativo (posición ya saludable)
     * - Retorna totalDebt si la cantidad calculada excede la deuda total
     */
    function _calculateDebtToCover(uint256 totalDebt, uint256 totalCollateralValue) private view returns (uint256) {
        // Calcula el multiplicador de threshold (50/100 = 0.5 con precisión)
        uint256 thresholdMultiplier = (s_liquidationThreshold * PRECISION) / LIQUIDATION_PRECISION;

        // Calcula el multiplicador de bonus (1 + bonus / 100) = (100 + 10)/100 = 1.1 con precisión
        uint256 bonusMultiplier = ((LIQUIDATION_PRECISION + s_liquidationBonus) * PRECISION) / LIQUIDATION_PRECISION;

        // Numerador: collateralValue × threshold - totalDebt × targetHF
        uint256 numerator = (totalCollateralValue * thresholdMultiplier) / PRECISION;
        uint256 debtComponent = (totalDebt * s_targetHealthFactor) / PRECISION;

        // Si numerador <= debtComponent, la liquidación parcial no es matemáticamente posible
        // Esto ocurre cuando el usuario está muy sub-colateralizado (HF < threshold × (1 + bonus) / targetHF)
        // En este caso, se necesita liquidación total
        if (numerator <= debtComponent) {
            return totalDebt;
        }

        numerator = numerator - debtComponent;

        // Denominador: targetHF - threshold × (1 + bonus)
        uint256 thresholdWithBonus = (thresholdMultiplier * bonusMultiplier) / PRECISION;

        // Si el denominador es negativo o cero, algo está mal
        if (s_targetHealthFactor <= thresholdWithBonus) {
            return totalDebt; // Liquidar todo como fallback
        }

        uint256 denominator = s_targetHealthFactor - thresholdWithBonus;

        // Calcular deuda a cubrir
        uint256 debtToCover = (numerator * PRECISION) / denominator;

        // Limitar a la deuda total
        if (debtToCover > totalDebt) {
            return totalDebt;
        }

        return debtToCover;
    }

    /**
     * @dev Revierte la transacción si el health factor está roto
     * @param user Usuario a verificar
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);

        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert TestStableCoinEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    //* Setters de Gobernanza (solo owner = Timelock)

    /**
     * @notice Actualiza el umbral de liquidación (solo owner/gobernanza)
     * @param newThreshold Nuevo umbral de liquidación (20-80 recomendado)
     * @dev Solo puede ser llamado por el owner (Timelock via gobernanza)
     *
     * VALIDACIONES:
     * - Debe estar entre 20 y 80 (125%-500% collateralization ratio)
     * - Muy bajo (<20) = riesgo de insolvencia sistémica
     * - Muy alto (>80) = protocolo poco capital efficient
     * - Cambio máximo: ±5 puntos por propuesta (rate limiting)
     * - Cooldown mínimo: 15 días entre cambios (rate limiting)
     *
     * EJEMPLO:
     * - newThreshold = 40 → 250% collateralization ratio (más seguro)
     * - newThreshold = 60 → 167% collateralization ratio (más arriesgado)
     */
    function updateLiquidationThreshold(uint256 newThreshold) external onlyOwner {
        // Comprobación de rango válido
        if (newThreshold < 20 || newThreshold > 80) {
            revert TestStableCoinEngine__InvalidGovernanceParameter();
        }

        // Obtiene el umbral actual y calcula el cambio (ternarios en solidity? WTF 🤯)
        uint256 currentThreshold = s_liquidationThreshold;

        // Si newThreshold > currentThreshold, change = new - current
        // Si newThreshold <= currentThreshold, change = current - new
        uint256 change =
            newThreshold > currentThreshold ? newThreshold - currentThreshold : currentThreshold - newThreshold;

        // Comprueba que el cambio no excede el máximo permitido de una sola vez
        if (change > MAX_THRESHOLD_CHANGE) {
            revert TestStableCoinEngine__ChangeExceedsMaximum();
        }

        // Comprueba que el tiempo de cooldown ha pasado desde el último cambio
        if (block.timestamp < s_lastThresholdUpdate + MIN_CHANGE_COOLDOWN) {
            revert TestStableCoinEngine__CooldownNotElapsed();
        }

        // Actualiza el estado con el nuevo umbral de liquidación y el timestamp del cambio
        uint256 oldThreshold = s_liquidationThreshold;
        s_liquidationThreshold = newThreshold;
        s_lastThresholdUpdate = block.timestamp;

        // Emite evento de actualización del umbral de liquidación
        emit LiquidationThresholdUpdated(oldThreshold, newThreshold);
    }

    /**
     * @notice Actualiza el bonus de liquidación (solo owner/gobernanza)
     * @param newBonus Nuevo bonus para liquidadores (5-20 recomendado)
     * @dev Solo puede ser llamado por el owner (Timelock via gobernanza)
     *
     * VALIDACIONES:
     * - Debe estar entre 5 y 20 (5%-20% bonus)
     * - Muy bajo (<5) = poco incentivo para liquidadores → liquidaciones lentas
     * - Muy alto (>20) = muy costoso para usuarios liquidados
     * - Cambio máximo: ±2 puntos por propuesta (rate limiting)
     * - Cooldown mínimo: 15 días entre cambios (rate limiting)
     *
     * EJEMPLO:
     * - newBonus = 5 → liquidador recibe 5% extra
     * - newBonus = 15 → liquidador recibe 15% extra (más incentivo)
     */
    function updateLiquidationBonus(uint256 newBonus) external onlyOwner {
        // Comprobación de rango válido
        if (newBonus < 5 || newBonus > 20) {
            revert TestStableCoinEngine__InvalidGovernanceParameter();
        }

        // Obtiene el bonus actual y calcula el cambio (ternarios en solidity? WTF 🤯)
        uint256 currentBonus = s_liquidationBonus;

        // Si newBonus > currentBonus, change = new - current
        // Si newBonus <= currentBonus, change = current - new
        uint256 change = newBonus > currentBonus ? newBonus - currentBonus : currentBonus - newBonus;

        // Comprueba que el cambio no excede el máximo permitido de una sola vez
        if (change > MAX_BONUS_CHANGE) {
            revert TestStableCoinEngine__ChangeExceedsMaximum();
        }

        // Comprueba que el tiempo de cooldown ha pasado desde el último cambio
        if (block.timestamp < s_lastBonusUpdate + MIN_CHANGE_COOLDOWN) {
            revert TestStableCoinEngine__CooldownNotElapsed();
        }

        // Actualiza el estado con el nuevo bonus de liquidación y el timestamp del cambio
        uint256 oldBonus = s_liquidationBonus;
        s_liquidationBonus = newBonus;
        s_lastBonusUpdate = block.timestamp;

        // Emite evento de actualización del bonus de liquidación
        emit LiquidationBonusUpdated(oldBonus, newBonus);
    }

    /**
     * @notice Actualiza el target health factor (solo owner/gobernanza)
     * @param newTarget Nuevo target health factor (1.1e18-1.5e18 recomendado)
     * @dev Solo puede ser llamado por el owner (Timelock via gobernanza)
     *
     * VALIDACIONES:
     * - Debe estar entre 1.1e18 y 1.5e18 (1.1 - 1.5 con 18 decimales)
     * - Muy bajo (<1.1) = poco margen de seguridad
     * - Muy alto (>1.5) = mayor impacto en usuarios
     * - Cambio máximo: ±0.1e18 por propuesta (rate limiting)
     * - Cooldown mínimo: 15 días entre cambios (rate limiting)
     *
     * EJEMPLO:
     * - newTarget = 1.1e18 → restaura HF a 1.1 (más conservador, menor impacto)
     * - newTarget = 1.5e18 → restaura HF a 1.5 (más agresivo, mayor seguridad)
     */
    function updateTargetHealthFactor(uint256 newTarget) external onlyOwner {
        // Comprobación de rango válido
        if (newTarget < 1.1e18 || newTarget > 1.5e18) {
            revert TestStableCoinEngine__InvalidGovernanceParameter();
        }

        // Obtiene el target HF actual y calcula el cambio (ternarios en solidity? WTF 🤯)
        uint256 currentTarget = s_targetHealthFactor;

        // Si newTarget > currentTarget, change = new - current
        // Si newTarget <= currentTarget, change = current - new
        uint256 change = newTarget > currentTarget ? newTarget - currentTarget : currentTarget - newTarget;

        // Comprueba que el cambio no excede el máximo permitido de una sola vez
        if (change > MAX_TARGET_HF_CHANGE) {
            revert TestStableCoinEngine__ChangeExceedsMaximum();
        }

        // Comprueba que el tiempo de cooldown ha pasado desde el último cambio
        if (block.timestamp < s_lastTargetHFUpdate + MIN_CHANGE_COOLDOWN) {
            revert TestStableCoinEngine__CooldownNotElapsed();
        }

        // Actualiza el estado con el nuevo target health factor y el timestamp del cambio
        uint256 oldTarget = s_targetHealthFactor;
        s_targetHealthFactor = newTarget;
        s_lastTargetHFUpdate = block.timestamp;

        // Emite evento de actualización del target health factor
        emit TargetHealthFactorUpdated(oldTarget, newTarget);
    }

    /**
     * @notice Actualiza la mint fee (solo owner/gobernanza)
     * @param newFee Nueva fee en basis points (5-50 recomendado)
     * @dev Solo puede ser llamado por el owner (Timelock via gobernanza)
     *
     * VALIDACIONES:
     * - Debe estar entre 5 y 50 basis points (0.05% - 0.5%)
     * - Muy bajo (<5 bps) = fondo de seguro crece lentamente
     * - Muy alto (>50 bps) = desincentiva el uso del protocolo
     * - Cambio máximo: ±5 basis points por propuesta (rate limiting)
     * - Cooldown mínimo: 15 días entre cambios (rate limiting)
     *
     * EJEMPLO:
     * - newFee = 10 → 0.1% fee por mint
     * - newFee = 30 → 0.3% fee por mint (más seguridad)
     */
    function updateMintFee(uint256 newFee) external onlyOwner {
        // Comprobación de rango válido
        if (newFee < 5 || newFee > 50) {
            revert TestStableCoinEngine__InvalidGovernanceParameter();
        }

        // Obtiene la fee actual y calcula el cambio (ternarios en solidity? WTF 🤯)
        uint256 currentFee = s_mintFee;

        // Si newFee > currentFee, change = new - current
        // Si newFee <= currentFee, change = current - new
        uint256 change = newFee > currentFee ? newFee - currentFee : currentFee - newFee;

        // Comprueba que el cambio no excede el máximo permitido de una sola vez
        if (change > MAX_MINT_FEE_CHANGE) {
            revert TestStableCoinEngine__ChangeExceedsMaximum();
        }

        // Comprueba que el tiempo de cooldown ha pasado desde el último cambio
        if (block.timestamp < s_lastMintFeeUpdate + MIN_CHANGE_COOLDOWN) {
            revert TestStableCoinEngine__CooldownNotElapsed();
        }

        // Actualiza el estado con la nueva mint fee y el timestamp del cambio
        uint256 oldFee = s_mintFee;
        s_mintFee = newFee;
        s_lastMintFeeUpdate = block.timestamp;

        // Emite evento de actualización de la mint fee
        emit MintFeeUpdated(oldFee, newFee);
    }

    //* Helpers y getters

    /**
     * @notice Convierte una cantidad de WETH a su valor en USD
     * @param amount Cantidad de WETH (en wei)
     * @return Valor en USD (con 18 decimales)
     */
    function getUsdValue(uint256 amount) public view returns (uint256) {
        int256 price = i_priceFeed.staleCheckLatestRoundData();

        // price tiene 8 decimales, amount tiene 18 decimales
        // Queremos resultado con 18 decimales
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * @notice Convierte un valor en USD a cantidad de WETH
     * @param usdAmountInWei Valor en USD (con 18 decimales)
     * @return Cantidad de WETH correspondiente
     */
    function getTokenAmountFromUsd(uint256 usdAmountInWei) public view returns (uint256) {
        int256 price = i_priceFeed.staleCheckLatestRoundData();

        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /**
     * @notice Obtiene el valor total del colateral de un usuario en USD
     * @param user Dirección del usuario
     * @return Valor total en USD (con 18 decimales)
     */
    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 amount = s_collateralDeposited[user];
        return getUsdValue(amount);
    }

    /**
     * @notice Obtiene información completa de la cuenta de un usuario
     * @param user Dirección del usuario
     * @return totalTscMinted Cantidad de TSC acuñado
     * @return collateralValueInUsd Valor del colateral en USD
     */
    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalTscMinted, uint256 collateralValueInUsd)
    {
        (totalTscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    /**
     * @notice Calcula el health factor de un usuario
     * @param user Dirección del usuario
     * @return El health factor (1e18 = 1.0)
     */
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /**
     * @notice Obtiene el balance de colateral depositado por un usuario
     * @param user Dirección del usuario
     * @return Cantidad de WETH depositado
     */
    function getCollateralBalanceOfUser(address user) external view returns (uint256) {
        return s_collateralDeposited[user];
    }

    /**
     * @notice Obtiene la cantidad de TSC acuñado por un usuario
     * @param user Dirección del usuario
     * @return Cantidad de TSC acuñado
     */
    function getStablecoinMinted(address user) external view returns (uint256) {
        return s_stablecoinMinted[user];
    }

    /**
     * @notice Obtiene el umbral de liquidación actual
     * @return El umbral (50 = 50% = 200% collateralization ratio)
     */
    function getLiquidationThreshold() external view returns (uint256) {
        return s_liquidationThreshold;
    }

    /**
     * @notice Obtiene el bonus de liquidación actual
     * @return El bonus (10 = 10%)
     */
    function getLiquidationBonus() external view returns (uint256) {
        return s_liquidationBonus;
    }

    /**
     * @notice Obtiene el target health factor actual
     * @return El target health factor (1.25e18 = 1.25)
     */
    function getTargetHealthFactor() external view returns (uint256) {
        return s_targetHealthFactor;
    }

    /**
     * @notice Obtiene la precisión usada para cálculos de liquidación
     * @return La precisión (100)
     */
    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    /**
     * @notice Obtiene el factor de salud mínimo
     * @return El factor mínimo (1e18 = 1.0)
     */
    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    /**
     * @notice Obtiene la precisión usada en cálculos
     * @return La precisión (1e18)
     */
    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    /**
     * @notice Obtiene la precisión adicional del price feed
     * @return La precisión adicional (1e10)
     */
    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    /**
     * @notice Obtiene la dirección del contrato WETH
     * @return Dirección de WETH
     */
    function getWeth() external view returns (address) {
        return address(i_weth);
    }

    /**
     * @notice Obtiene la dirección del contrato TSC
     * @return Dirección de TestStableCoin
     */
    function getStablecoin() external view returns (address) {
        return address(i_tsc);
    }

    /**
     * @notice Obtiene la dirección del price feed
     * @return Dirección del Chainlink price feed
     */
    function getPriceFeed() external view returns (address) {
        return address(i_priceFeed);
    }

    /**
     * @notice Obtiene el balance actual del fondo de seguro
     * @return Balance en USD (con 18 decimales)
     */
    function getInsuranceFundBalance() external view returns (uint256) {
        return s_insuranceFund;
    }

    /**
     * @notice Obtiene la mint fee actual
     * @return La fee en basis points (20 = 0.2%)
     */
    function getMintFee() external view returns (uint256) {
        return s_mintFee;
    }
}
