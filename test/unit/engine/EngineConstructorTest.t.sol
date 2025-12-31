// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestStableCoinEngine} from "../../../src/stablecoin/TestStableCoinEngine.sol";
import {TestStableCoin} from "../../../src/stablecoin/TestStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";

/**
 * @title EngineConstructorTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para el constructor del TestStableCoinEngine
 * @dev Tests que verifican la inicialización correcta del contrato
 */
contract EngineConstructorTest is Test {
    // Contratos mock
    ERC20Mock public weth;
    TestStableCoin public tsc;
    MockV3Aggregator public priceFeed;
    TestStableCoinEngine public engine;

    // Direcciones de prueba
    address public owner;

    // Constantes para el price feed
    uint8 public constant DECIMALS = 8;
    int256 public constant INITIAL_PRICE = 2000e8; // $2000

    /**
     * @notice Configuración inicial ejecutada antes de cada test
     */
    function setUp() public {
        // Establecer timestamp inicial para evitar underflow en el constructor
        vm.warp(16 days);

        // Setup de direcciones
        owner = makeAddr("owner");

        // Deployment de contratos mock
        weth = new ERC20Mock();
        tsc = new TestStableCoin();
        priceFeed = new MockV3Aggregator(DECIMALS, INITIAL_PRICE);
    }

    /**
     * @notice Verifica que el constructor inicializa correctamente todas las variables
     * @dev Valida variables inmutables y parámetros gobernables iniciales
     */
    function test_Constructor_InitializesCorrectly() public {
        // Acción: Deployment del Engine
        engine = new TestStableCoinEngine(address(weth), address(tsc), address(priceFeed), owner);

        // Verificación: Variables inmutables correctamente asignadas
        assertEq(address(engine.getWeth()), address(weth));
        assertEq(address(engine.getPriceFeed()), address(priceFeed));

        // Verificación: Parámetros gobernables en valores por defecto
        assertEq(engine.getLiquidationThreshold(), 50); // 50%
        assertEq(engine.getLiquidationBonus(), 10); // 10%
        assertEq(engine.getTargetHealthFactor(), 0.90e18); // 0.90
        assertEq(engine.getMintFee(), 20); // 20 basis points

        // Verificación: El owner es el especificado
        assertEq(engine.owner(), owner);

        // Verificación: El insurance fund comienza en 0
        assertEq(engine.getInsuranceFundBalance(), 0);
    }

    /**
     * @notice Verifica que el constructor revierte cuando la dirección de WETH es zero
     * @dev Previene deployment con configuración inválida
     */
    function test_Constructor_RevertsWhen_WethAddressZero() public {
        // Acción + Verificación: Debe revertir con error de dirección inválida
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__InvalidAddress.selector);
        new TestStableCoinEngine(address(0), address(tsc), address(priceFeed), owner);
    }

    /**
     * @notice Verifica que el constructor revierte cuando la dirección del price feed es zero
     * @dev Previene deployment con configuración inválida
     */
    function test_Constructor_RevertsWhen_PriceFeedAddressZero() public {
        // Acción + Verificación: Debe revertir con error de dirección inválida
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__InvalidAddress.selector);
        new TestStableCoinEngine(address(weth), address(tsc), address(0), owner);
    }
}
