// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestStableCoinEngine} from "../../../src/stablecoin/TestStableCoinEngine.sol";
import {TestStableCoin} from "../../../src/stablecoin/TestStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";

/**
 * @title EngineHealthFactorTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para el cálculo del health factor
 * @dev Tests que verifican la correcta implementación de la fórmula de health factor
 */
contract EngineHealthFactorTest is Test {
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
    uint256 public constant PRECISION = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50; // 50%

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

        // Dar WETH al usuario para pruebas
        weth.mint(user, 100 ether);

        // Usuario aprueba WETH al Engine
        vm.prank(user);
        weth.approve(address(engine), type(uint256).max);
    }

    /**
     * @notice Verifica que el health factor retorna max uint256 cuando no hay deuda
     * @dev Cuando totalTscMinted = 0, HF debe ser type(uint256).max para evitar división por cero
     */
    function test_HealthFactor_ReturnsMaxUint_WhenNoDebt() public {
        // Setup: Usuario deposita colateral pero no mintea nada
        vm.prank(user);
        engine.depositCollateral(10 ether);

        // Acción: Obtener health factor
        uint256 healthFactor = engine.getHealthFactor(user);

        // Verificación: Debe ser máximo cuando no hay deuda
        assertEq(healthFactor, type(uint256).max);
    }

    /**
     * @notice Verifica que el health factor se calcula correctamente en caso normal
     * @dev HF = (collateral * threshold / 100) * 1e18 / debt
     */
    function test_HealthFactor_CalculatesCorrectly_NormalCase() public {
        // Setup: Usuario deposita 10 ETH y mintea TSC
        // 10 ETH * $2000 = $20,000 colateral
        // $20,000 * 50% = $10,000 adjusted

        vm.startPrank(user);
        engine.depositCollateral(10 ether);
        engine.mintTsc(5000e18);
        vm.stopPrank();

        // Acción: Obtener health factor
        uint256 healthFactor = engine.getHealthFactor(user);

        // Verificación: HF debe ser mayor que 1 (posición saludable)
        // Con threshold 50%, el usuario puede mintear hasta $10,000
        // Ha minteado ~$4990 (5000 - fee), así que HF > 2
        assertGt(healthFactor, 2e18);
    }

    /**
     * @notice Verifica que HF < 1 cuando la posición está infracollateralizada
     * @dev Esto debería permitir liquidaciones
     */
    function test_HealthFactor_Below1_WhenUndercollateralized() public {
        // Setup: Usuario deposita 10 ETH y mintea una cantidad alta
        vm.startPrank(user);
        engine.depositCollateral(10 ether);

        // Mintear cantidad que dejará HF < 1
        // Colateral: $20,000, ajustado = $10,000
        // Para HF = 0.5, necesitamos deuda = $20,000
        // Pero el engine no permitirá esto, así que simularemos caída de precio

        // Primero minteamos cantidad segura
        engine.mintTsc(5000e18);
        vm.stopPrank();

        // Simular caída drástica del precio de ETH: $2000 -> $600
        priceFeed.updateAnswer(600e8);

        // Acción: Obtener health factor después de caída de precio
        // Nuevo colateral: 10 ETH * $600 = $6,000
        // Ajustado: $6,000 * 50 / 100 = $3,000
        // Deuda: ~5000 TSC (después de fee, ~4990)
        // HF = 3,000 / 4,990 ≈ 0.60
        uint256 healthFactor = engine.getHealthFactor(user);

        // Verificación: HF debe ser menor a 1
        assertLt(healthFactor, 1e18);
    }

    /**
     * @notice Verifica que HF > 1 cuando la posición está sobrecollateralizada
     * @dev Esto es el caso normal y seguro
     */
    function test_HealthFactor_Above1_WhenOvercollateralized() public {
        // Setup: Usuario deposita mucho colateral y mintea poco
        vm.startPrank(user);
        engine.depositCollateral(20 ether); // $40,000
        engine.mintTsc(1000e18); // ~$1000 de deuda
        vm.stopPrank();

        // Acción: Obtener health factor
        // Colateral ajustado: $40,000 * 50 / 100 = $20,000
        // Deuda: ~998 TSC (después de fee)
        // HF = 20,000 / 998 ≈ 20.04
        uint256 healthFactor = engine.getHealthFactor(user);

        // Verificación: HF debe ser mucho mayor a 1
        assertGt(healthFactor, 1e18);
        assertGt(healthFactor, 19e18); // Debe ser al menos 19
    }

    /**
     * @notice Verifica que el cálculo usa el liquidation threshold correcto
     * @dev El threshold afecta directamente el colateral ajustado
     */
    function test_CalculateHealthFactor_UsesLiquidationThreshold() public {
        // Setup: Crear posición
        vm.startPrank(user);
        engine.depositCollateral(10 ether); // $20,000
        engine.mintTsc(5000e18);
        vm.stopPrank();

        // Acción: Obtener HF con threshold = 50
        uint256 hfBefore = engine.getHealthFactor(user);

        // Verificar que el threshold actual es 50
        assertEq(engine.getLiquidationThreshold(), 50);

        // Verificación: El HF debe reflejar el threshold de 50%
        // Con $20,000 colateral y threshold 50%: ajustado = $10,000
        // Con ~4990 deuda: HF ≈ 2.0
        assertGe(hfBefore, 1.99e18);
        assertLe(hfBefore, 2.01e18);
    }

    /**
     * @notice Verifica que el cálculo usa precisión de 18 decimales
     * @dev PRECISION = 1e18 se usa en la fórmula final
     */
    function test_CalculateHealthFactor_UsesPrecision() public {
        // Setup: Crear posición simple
        vm.startPrank(user);
        engine.depositCollateral(1 ether); // $2,000
        engine.mintTsc(500e18); // $500
        vm.stopPrank();

        // Acción: Obtener HF
        // Colateral ajustado: $2,000 * 50 / 100 = $1,000
        // Deuda: ~499 TSC (500 - 0.2% fee)
        // HF = 1,000 * 1e18 / 499 ≈ 2.004e18
        uint256 healthFactor = engine.getHealthFactor(user);

        // Verificación: El resultado debe tener precisión de 18 decimales
        assertGe(healthFactor, 1.99e18);
        assertLe(healthFactor, 2.05e18);

        // Verificación adicional: No debe ser un número entero simple
        assertGt(healthFactor, 1e18); // Mayor que 1.0
        assertLt(healthFactor, 100e18); // Pero razonable
    }
}
