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
 * @dev Tests que verifican cálculos complejos de estado (no getters triviales)
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
}
