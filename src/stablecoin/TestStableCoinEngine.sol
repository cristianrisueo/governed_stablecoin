// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
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
 *
 * El sistema está diseñado para mantener 1 TSC = 1 USD mediante:
 * - Overcollateralización del 200% (soporta caídas de hasta ~25-33% antes de entrar en riesgo)
 * - Liquidaciones automáticas cuando health factor < 1
 * - Uso de Chainlink oracles para pricing en tiempo real
 *
 * IMPORTANTE: Este protocolo es algorítmico y descentralizado.
 * - Tiene gobernanza on-chain mediante TSCGovernor + TSCTimelock
 * - Parámetros críticos (liquidation threshold, bonus) son gobernables
 * - Depende completamente de la overcollateralización para mantener el peg
 */
contract TestStableCoinEngine is ReentrancyGuard, Ownable2Step {
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

    //* Tipos

    using OracleLib for AggregatorV3Interface;

    //* Variables de Estado

    //* Constantes Inmutables (no gobernables por seguridad)

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
     * @dev Mapeo de usuario a cantidad de WETH depositado como colateral
     */
    mapping(address user => uint256 amountWethDeposited) private s_collateralDeposited;

    /**
     * @dev Mapeo de usuario a cantidad de TSC acuñado
     */
    mapping(address user => uint256 amountTscMinted) private s_stablecoinMinted;

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
     * @dev Emitido cuando se detecta bad debt durante una liquidación
     * @param user Dirección del usuario liquidado que tenía bad debt
     * @param totalDebt Cantidad total de deuda en TSC que debía ser cubierta
     * @param collateralAvailable Cantidad de colateral WETH disponible (menor que deuda + bonus)
     */
    event BadDebtDetected(address indexed user, uint256 totalDebt, uint256 collateralAvailable);

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
        if (wethAddress == address(0) || tscAddress == address(0) || priceFeedAddress == address(0)) {
            revert TestStableCoinEngine__InvalidAddress();
        }

        i_weth = IERC20(wethAddress);
        i_tsc = TestStableCoin(tscAddress);
        i_priceFeed = AggregatorV3Interface(priceFeedAddress);
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
     * @param amountTscToMint Cantidad de TSC a acuñar
     * @dev Revierte si el health factor resultante es menor a MIN_HEALTH_FACTOR
     */
    function mintTsc(uint256 amountTscToMint) public moreThanZero(amountTscToMint) nonReentrant {
        s_stablecoinMinted[msg.sender] += amountTscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_tsc.mint(msg.sender, amountTscToMint);
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
     * @notice Liquida completamente una posición insolvente
     * @param user Dirección del usuario a liquidar
     * @dev El liquidador recibe el colateral correspondiente a la deuda + 10% de bonus
     * @dev SIEMPRE liquida el 100% de la deuda del usuario
     * @dev Solo se puede liquidar si el health factor del usuario es < 1
     * @dev Si el colateral del usuario no alcanza para cubrir deuda + bonus, el liquidador asume la pérdida
     *
     * Ejemplo:
     * - Usuario tiene 10 WETH de colateral y $15,000 de deuda (HF = 0.66)
     * - Colateral equivalente: $15,000 / $2,000 (precio ETH) = 7.5 WETH
     * - Bonus: 7.5 × 10% = 0.75 WETH
     * - Liquidador paga: $15,000 en TSC y recibe: 8.25 WETH
     * - Usuario queda con: 1.75 WETH y 0 de deuda
     */
    function liquidate(address user) external nonReentrant {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor >= MIN_HEALTH_FACTOR) {
            revert TestStableCoinEngine__HealthFactorOk();
        }

        uint256 totalDebt = s_stablecoinMinted[user];
        uint256 tokenAmountFromDebt = getTokenAmountFromUsd(totalDebt);
        uint256 bonusCollateral = (tokenAmountFromDebt * s_liquidationBonus) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebt + bonusCollateral;

        // Este check es súper importante para evitar bad debt. Si el colateral del usuario no alcanza
        // para cubrir la deuda + bonus, el liquidador recibe todo el colateral disponible y asume la pérdida
        uint256 userCollateral = s_collateralDeposited[user];

        if (totalCollateralToRedeem > userCollateral) {
            totalCollateralToRedeem = userCollateral;
            emit BadDebtDetected(user, totalDebt, userCollateral);
        }

        _redeemCollateral(user, msg.sender, totalCollateralToRedeem);
        _burnTsc(totalDebt, user, msg.sender);

        // Lo vamos a dejar por paranóicos, pero un liquidador gana colateral y no toca su deuda, su HF siempre sube
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
     *
     * EJEMPLO:
     * - newThreshold = 40 → 250% collateralization ratio (más seguro)
     * - newThreshold = 60 → 167% collateralization ratio (más arriesgado)
     */
    function updateLiquidationThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold < 20 || newThreshold > 80) {
            revert TestStableCoinEngine__InvalidGovernanceParameter();
        }

        uint256 oldThreshold = s_liquidationThreshold;
        s_liquidationThreshold = newThreshold;

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
     *
     * EJEMPLO:
     * - newBonus = 5 → liquidador recibe 5% extra
     * - newBonus = 15 → liquidador recibe 15% extra (más incentivo)
     */
    function updateLiquidationBonus(uint256 newBonus) external onlyOwner {
        if (newBonus < 5 || newBonus > 20) {
            revert TestStableCoinEngine__InvalidGovernanceParameter();
        }

        uint256 oldBonus = s_liquidationBonus;
        s_liquidationBonus = newBonus;

        emit LiquidationBonusUpdated(oldBonus, newBonus);
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
}
