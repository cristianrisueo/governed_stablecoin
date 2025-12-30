// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestStableCoinEngine} from "../../../src/stablecoin/TestStableCoinEngine.sol";
import {TestStableCoin} from "../../../src/stablecoin/TestStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";

/**
 * @title EngineGettersTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para funciones getter del Engine
 * @dev Tests que verifican lectura correcta de estado
 */
contract EngineGettersTest is Test {
    // Contratos
    TestStableCoinEngine public engine;
    TestStableCoin public tsc;
    ERC20Mock public weth;
    MockV3Aggregator public priceFeed;

    // Direcciones de prueba
    address public owner;
    address public user;

    // Constantes
    uint8 public constant DECIMALS = 8;
    int256 public constant INITIAL_PRICE = 2000e8; // $2000 por ETH

    /**
     * @notice Configuración inicial ejecutada antes de cada test
     */
    function setUp() public {
        // Establecer timestamp inicial para evitar underflow en el constructor
        vm.warp(16 days);

        // Setup de direcciones
        owner = makeAddr("owner");
        user = makeAddr("user");

        // Deployment de contratos
        weth = new ERC20Mock();
        tsc = new TestStableCoin();
        priceFeed = new MockV3Aggregator(DECIMALS, INITIAL_PRICE);
        engine = new TestStableCoinEngine(address(weth), address(tsc), address(priceFeed), owner);

        // Transferir ownership de TSC al Engine
        tsc.transferOwnership(address(engine));

        // Dar WETH al usuario
        weth.mint(user, 100 ether);

        // Usuario aprueba WETH al Engine
        vm.prank(user);
        weth.approve(address(engine), type(uint256).max);
    }

    /**
     * @notice Verifica que getAccountCollateralValue retorna el valor correcto en USD
     * @dev Calcula: collateral * price * ADDITIONAL_PRECISION
     */
    function test_GetAccountCollateralValue_ReturnsCorrectValue() public {
        // Setup: Usuario deposita colateral
        uint256 collateralAmount = 5 ether;
        vm.prank(user);
        engine.depositCollateral(collateralAmount);

        // Acción: Obtener valor del colateral en USD
        uint256 collateralValue = engine.getAccountCollateralValue(user);

        // Verificación: 5 ETH * $2000 = $10,000 (con 18 decimales)
        uint256 expectedValue = 10000e18;
        assertEq(collateralValue, expectedValue);
    }

    /**
     * @notice Verifica que getAccountInformation retorna datos correctos
     * @dev Retorna: (totalTscMinted, collateralValueInUsd)
     */
    function test_GetAccountInformation_ReturnsCorrectData() public {
        // Setup: Usuario deposita y mintea
        vm.startPrank(user);
        engine.depositCollateral(10 ether); // $20,000
        engine.mintTsc(5000e18); // ~$5000 de deuda (menos fee)
        vm.stopPrank();

        // Acción: Obtener información de la cuenta
        (uint256 totalTscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(user);

        // Verificación: Colateral en USD
        assertEq(collateralValueInUsd, 20000e18);

        // Verificación: Deuda minteada (aproximada, considerando fee de 0.2%)
        uint256 expectedDebt = 5000e18 - ((5000e18 * 20) / 10000); // 5000 - 10 = 4990
        assertEq(totalTscMinted, expectedDebt);
    }

    /**
     * @notice Verifica que getCollateralBalanceOfUser retorna el balance correcto
     * @dev Retorna s_collateralDeposited[user]
     */
    function test_GetCollateralBalanceOfUser_ReturnsCorrectBalance() public {
        // Setup: Usuario deposita colateral
        uint256 depositAmount = 7 ether;
        vm.prank(user);
        engine.depositCollateral(depositAmount);

        // Acción: Obtener balance de colateral
        uint256 balance = engine.getCollateralBalanceOfUser(user);

        // Verificación: Balance debe coincidir
        assertEq(balance, depositAmount);
    }

    /**
     * @notice Verifica que getStablecoinMinted retorna la cantidad correcta
     * @dev Retorna s_stablecoinMinted[user] (deuda)
     */
    function test_GetStablecoinMinted_ReturnsCorrectAmount() public {
        // Setup: Usuario deposita y mintea
        vm.startPrank(user);
        engine.depositCollateral(10 ether);
        engine.mintTsc(3000e18);
        vm.stopPrank();

        // Acción: Obtener TSC minteado (deuda)
        uint256 tscMinted = engine.getStablecoinMinted(user);

        // Verificación: Debe ser monto neto (después de fee)
        uint256 expectedDebt = 3000e18 - ((3000e18 * 20) / 10000); // 3000 - 6 = 2994
        assertEq(tscMinted, expectedDebt);
    }

    /**
     * @notice Verifica que getLiquidationThreshold retorna el valor actual
     * @dev Valor por defecto = 50
     */
    function test_GetLiquidationThreshold_ReturnsCurrentValue() public view {
        // Acción: Obtener threshold
        uint256 threshold = engine.getLiquidationThreshold();

        // Verificación: Valor por defecto es 50
        assertEq(threshold, 50);
    }

    /**
     * @notice Verifica que getLiquidationBonus retorna el valor actual
     * @dev Valor por defecto = 10
     */
    function test_GetLiquidationBonus_ReturnsCurrentValue() public view {
        // Acción: Obtener bonus
        uint256 bonus = engine.getLiquidationBonus();

        // Verificación: Valor por defecto es 10
        assertEq(bonus, 10);
    }

    /**
     * @notice Verifica que getTargetHealthFactor retorna el valor actual
     * @dev Valor por defecto = 1.25e18
     */
    function test_GetTargetHealthFactor_ReturnsCurrentValue() public view {
        // Acción: Obtener target HF
        uint256 targetHF = engine.getTargetHealthFactor();

        // Verificación: Valor por defecto es 1.25e18
        assertEq(targetHF, 1.25e18);
    }

    /**
     * @notice Verifica que getInsuranceFundBalance retorna el balance correcto
     * @dev El fondo crece con las fees de mint
     */
    function test_GetInsuranceFundBalance_ReturnsCorrectBalance() public {
        // Setup: Usuario mintea TSC (genera fees)
        vm.startPrank(user);
        engine.depositCollateral(20 ether);
        engine.mintTsc(10000e18); // Fee: 10000 * 0.2% = 20 TSC
        vm.stopPrank();

        // Acción: Obtener balance del insurance fund
        uint256 insuranceBalance = engine.getInsuranceFundBalance();

        // Verificación: Debe tener las fees acumuladas
        uint256 expectedFee = (10000e18 * 20) / 10000; // 20 TSC
        assertEq(insuranceBalance, expectedFee);
    }

    /**
     * @notice Verifica que getMintFee retorna la fee actual
     * @dev Valor por defecto = 20 basis points (0.2%)
     */
    function test_GetMintFee_ReturnsCurrentFee() public view {
        // Acción: Obtener mint fee
        uint256 mintFee = engine.getMintFee();

        // Verificación: Valor por defecto es 20 bps
        assertEq(mintFee, 20);
    }

    /**
     * @notice Verifica que getWeth retorna la dirección correcta del contrato WETH
     * @dev Variable inmutable i_weth
     */
    function test_GetWeth_ReturnsWethAddress() public view {
        // Acción: Obtener dirección WETH
        address wethAddress = address(engine.getWeth());

        // Verificación: Debe coincidir con el mock deployado
        assertEq(wethAddress, address(weth));
    }

    /**
     * @notice Verifica que getPriceFeed retorna la dirección correcta del price feed
     * @dev Variable inmutable i_priceFeed
     */
    function test_GetPriceFeed_ReturnsPriceFeedAddress() public view {
        // Acción: Obtener dirección del price feed
        address priceFeedAddress = address(engine.getPriceFeed());

        // Verificación: Debe coincidir con el mock deployado
        assertEq(priceFeedAddress, address(priceFeed));
    }
}
