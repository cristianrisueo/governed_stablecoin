// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {TestStableCoinEngine} from "../../../src/stablecoin/TestStableCoinEngine.sol";
import {TestStableCoin} from "../../../src/stablecoin/TestStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";

/**
 * @title EngineLiquidationTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para el sistema de liquidaciones
 * @dev Tests que cubren liquidaciones totales, bad debt, y edge cases críticos
 */
contract EngineLiquidationTest is Test {
    // Contratos
    TestStableCoinEngine public engine;
    TestStableCoin public tsc;
    ERC20Mock public weth;
    MockV3Aggregator public priceFeed;

    // Direcciones de prueba
    address public owner;
    address public user;
    address public user2;
    address public liquidator;

    // Constantes
    uint8 public constant DECIMALS = 8;
    int256 public constant INITIAL_PRICE = 2000e8;
    uint256 public constant PRECISION = 1e18;

    // Eventos
    event BadDebtTotalLiquidation(address indexed user, uint256 totalDebt, uint256 insuranceUsed);

    /**
     * @notice Configuración inicial ejecutada antes de cada test
     */
    function setUp() public {
        // Establecer timestamp inicial para evitar underflow en el constructor
        vm.warp(16 days);

        // Setup de direcciones
        owner = makeAddr("owner");
        user = makeAddr("user");
        user2 = makeAddr("user2");
        liquidator = makeAddr("liquidator");

        // Deployment de contratos
        weth = new ERC20Mock();
        tsc = new TestStableCoin();
        priceFeed = new MockV3Aggregator(DECIMALS, INITIAL_PRICE);
        engine = new TestStableCoinEngine(address(weth), address(tsc), address(priceFeed), owner);

        // Transferir ownership de TSC al Engine
        tsc.transferOwnership(address(engine));

        // Dar WETH a usuarios
        weth.mint(user, 100 ether);
        weth.mint(user2, 100 ether);
        weth.mint(liquidator, 100 ether);

        // Aprobar WETH al Engine
        vm.prank(user);
        weth.approve(address(engine), type(uint256).max);

        vm.prank(user2);
        weth.approve(address(engine), type(uint256).max);

        vm.prank(liquidator);
        weth.approve(address(engine), type(uint256).max);
    }

    /**
     * @notice Verifica que no se puede liquidar una posición saludable
     * @dev Si HF >= 1, la liquidación debe revertir
     */
    function test_Liquidate_RevertsWhen_HealthFactorOk() public {
        // Setup: Usuario con posición muy saludable
        vm.startPrank(user);
        engine.depositCollateral(20 ether); // $40,000
        engine.mintTsc(5000e18); // Solo $5000 de deuda
        vm.stopPrank();

        // Verificar que HF > 1
        uint256 healthFactor = engine.getHealthFactor(user);
        assertGt(healthFactor, 1e18);

        // Setup liquidador
        vm.startPrank(liquidator);
        engine.depositCollateral(10 ether);
        engine.mintTsc(3000e18);
        tsc.approve(address(engine), type(uint256).max);

        // Acción + Verificación: Debe revertir
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__HealthFactorOk.selector);
        engine.liquidate(user);
        vm.stopPrank();
    }

    /**
     * @notice Verifica que la liquidación total funciona cuando el usuario tiene colateral suficiente
     * @dev Cuando debtToCover=0 (partial no posible), se liquida toda la deuda
     */
    function test_Liquidate_TotalLiquidation_WhenSufficientCollateral() public {
        // Setup: Usuario deposita colateral y mintea
        vm.startPrank(user);
        engine.depositCollateral(10 ether); // $20,000
        engine.mintTsc(5000e18); // ~$4990 de deuda (con fee)
        vm.stopPrank();

        uint256 userDebtBefore = engine.getStablecoinMinted(user);

        // Simular caída de precio: $2000 -> $600 (70% drop)
        // Colateral: 10 ETH * $600 = $6,000
        // Ajustado: $6,000 * 50% = $3,000
        // Deuda: ~4990 TSC
        // HF = 3000 / 4990 ≈ 0.60 < 1 (liquidable)
        priceFeed.updateAnswer(600e8);

        uint256 hfAfterDrop = engine.getHealthFactor(user);
        assertLt(hfAfterDrop, 1e18);

        // Setup liquidador con suficiente TSC para pagar toda la deuda
        vm.startPrank(liquidator);
        engine.depositCollateral(50 ether); // $30,000 a $600/ETH
        engine.mintTsc(userDebtBefore + 1000e18); // Suficiente TSC para cubrir deuda
        tsc.approve(address(engine), type(uint256).max);

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);

        // Ejecutar liquidación
        engine.liquidate(user);
        vm.stopPrank();

        // Verificaciones post-liquidación
        // Usuario quedó sin deuda (liquidación total)
        assertEq(engine.getStablecoinMinted(user), 0);

        // Usuario perdió colateral pero no todo (solo deuda + bonus)
        uint256 userCollateralAfter = engine.getCollateralBalanceOfUser(user);
        assertLt(userCollateralAfter, 10 ether);

        // Liquidador recibió colateral
        uint256 liquidatorWethAfter = weth.balanceOf(liquidator);
        assertGt(liquidatorWethAfter, liquidatorWethBefore);

        // HF del usuario ahora es max (sin deuda)
        assertEq(engine.getHealthFactor(user), type(uint256).max);
    }

    /**
     * @notice Verifica que bad debt usa el insurance fund correctamente
     * @dev Cuando el colateral es insuficiente para cubrir deuda+bonus, el insurance fund cubre el déficit
     */
    function test_Liquidate_BadDebt_UsesInsuranceFund() public {
        // Setup: Generar un gran insurance fund con fees de otros usuarios
        // Necesitamos suficiente para cubrir el shortfall (~485 TSC)
        address feeGenerator = makeAddr("feeGenerator");
        weth.mint(feeGenerator, 500 ether);
        vm.startPrank(feeGenerator);
        weth.approve(address(engine), type(uint256).max);
        engine.depositCollateral(250 ether); // $500,000
        engine.mintTsc(250000e18); // Genera fee de 500 TSC al insurance fund (0.2% de 250k)
        vm.stopPrank();

        uint256 insuranceBefore = engine.getInsuranceFundBalance();
        assertGt(insuranceBefore, 490e18); // Verificar que tenemos suficiente para cubrir shortfall

        // Setup: Usuario mintea al límite
        // Con 2 ETH a $2000 = $4,000 colateral, ajustado = $2,000
        vm.startPrank(user);
        engine.depositCollateral(2 ether); // $4,000 colateral
        engine.mintTsc(1900e18); // ~$1896 deuda (muy cerca del límite)
        vm.stopPrank();

        uint256 userDebt = engine.getStablecoinMinted(user);

        // Setup liquidador con suficiente TSC ANTES del crash de precio
        vm.startPrank(liquidator);
        engine.depositCollateral(50 ether); // $100,000 a $2000/ETH
        engine.mintTsc(userDebt + 500e18); // Suficiente para cubrir deuda
        tsc.approve(address(engine), type(uint256).max);
        vm.stopPrank();

        // Crash de precio moderado: $2000 -> $800 (60% drop)
        // Colateral: 2 ETH * $800 = $1,600
        // Deuda: ~1896 TSC
        // Para cubrir deuda + 10% bonus = 1896 * 1.1 = 2085.6 USD en ETH = 2.607 ETH a $800
        // Usuario solo tiene 2 ETH ($1,600) - hay bad debt
        // Shortfall: 2085.6 - 1600 = 485.6 TSC (cubierto por insurance de 500 TSC)
        priceFeed.updateAnswer(800e8);

        uint256 hf = engine.getHealthFactor(user);
        assertLt(hf, 1e18); // Liquidable

        // Ejecutar liquidación (debería usar insurance fund porque hay bad debt)
        vm.prank(liquidator);
        engine.liquidate(user);

        // Verificaciones
        // Usuario quedó sin colateral (liquidación total)
        assertEq(engine.getCollateralBalanceOfUser(user), 0);

        // Usuario quedó sin deuda
        assertEq(engine.getStablecoinMinted(user), 0);

        // Insurance fund se redujo (cubrió el shortfall)
        uint256 insuranceAfter = engine.getInsuranceFundBalance();
        assertLt(insuranceAfter, insuranceBefore);
    }

    /**
     * @notice Verifica que liquidación revierte si insurance fund es insuficiente
     * @dev Protección contra bad debt sin cobertura
     */
    function test_Liquidate_BadDebt_RevertsWhen_InsufficientInsurance() public {
        // Setup: Usuario mintea al límite SIN insurance fund previo significativo
        vm.startPrank(user);
        engine.depositCollateral(5 ether); // $10,000
        engine.mintTsc(4900e18); // ~$4890 deuda (cerca del límite)
        vm.stopPrank();

        uint256 userDebt = engine.getStablecoinMinted(user);

        // Verificar que insurance fund tiene muy poco (solo las fees del user)
        uint256 insuranceFund = engine.getInsuranceFundBalance();
        assertLt(insuranceFund, 100e18);

        // Setup liquidador con suficiente TSC ANTES del crash
        vm.startPrank(liquidator);
        engine.depositCollateral(50 ether); // $100,000 a $2000/ETH
        engine.mintTsc(userDebt + 500e18);
        tsc.approve(address(engine), type(uint256).max);
        vm.stopPrank();

        // Crash EXTREMO: $2000 -> $100 (95% drop)
        // Colateral: 5 ETH * $100 = $500
        // Deuda: ~4890 TSC
        // Para cubrir deuda + bonus = 4890 * 1.1 = 5379 USD en ETH = 53.79 ETH a $100
        // Shortfall = 5379 - 500 = $4879 USD - MUCHO mayor que insurance fund
        priceFeed.updateAnswer(100e8);

        // Debe revertir por falta de insurance funds
        vm.prank(liquidator);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__InsufficientInsuranceFunds.selector);
        engine.liquidate(user);
    }

    /**
     * @notice Verifica que la liquidación lleva el HF al máximo cuando liquida toda la deuda
     * @dev Después de liquidación total, HF = max (sin deuda)
     */
    function test_Liquidate_ReachesMaxHealthFactor_WhenFullyLiquidated() public {
        // Setup: Usuario con posición moderada
        vm.startPrank(user);
        engine.depositCollateral(10 ether); // $20,000 a $2000
        engine.mintTsc(6000e18); // ~5988 TSC de deuda después de fee
        vm.stopPrank();

        uint256 userDebt = engine.getStablecoinMinted(user);

        // Caída de precio: $2000 -> $700
        // Colateral: 10 ETH * $700 = $7,000
        // Ajustado: $7,000 * 50% = $3,500
        // Deuda: ~5988 TSC
        // HF = 3500 / 5988 ≈ 0.58 < 1 (liquidable)
        priceFeed.updateAnswer(700e8);

        uint256 hfBeforeLiq = engine.getHealthFactor(user);
        assertLt(hfBeforeLiq, 1e18);

        // Setup liquidador con suficiente TSC
        vm.startPrank(liquidator);
        engine.depositCollateral(50 ether);
        engine.mintTsc(userDebt + 1000e18);
        tsc.approve(address(engine), type(uint256).max);

        // Ejecutar liquidación
        engine.liquidate(user);
        vm.stopPrank();

        // Verificar que HF llegó al máximo (sin deuda)
        uint256 hfAfterLiq = engine.getHealthFactor(user);
        assertEq(hfAfterLiq, type(uint256).max);

        // Verificar que no tiene deuda
        assertEq(engine.getStablecoinMinted(user), 0);
    }

    /**
     * @notice Verifica que la liquidación protege el HF del liquidador
     * @dev El liquidador no puede terminar con HF < 1 después de liquidar
     */
    function test_Liquidate_LiquidatorHealthFactor_Protected() public {
        // Setup: Usuario liquidable
        vm.startPrank(user);
        engine.depositCollateral(10 ether);
        engine.mintTsc(6000e18);
        vm.stopPrank();

        uint256 userDebt = engine.getStablecoinMinted(user);

        // Caída de precio
        priceFeed.updateAnswer(700e8);
        assertLt(engine.getHealthFactor(user), 1e18);

        // Setup liquidador con posición saludable y suficiente TSC
        vm.startPrank(liquidator);
        engine.depositCollateral(40 ether); // $28,000 a $700
        engine.mintTsc(userDebt + 2000e18); // Suficiente TSC
        tsc.approve(address(engine), type(uint256).max);

        // Verificar que liquidador tiene HF > 1
        uint256 liquidatorHF = engine.getHealthFactor(liquidator);
        assertGt(liquidatorHF, 1e18);

        // La liquidación debería funcionar
        engine.liquidate(user);

        // Verificar que el liquidador sigue saludable
        uint256 liquidatorHFAfter = engine.getHealthFactor(liquidator);
        assertGt(liquidatorHFAfter, 1e18);
        vm.stopPrank();
    }

    /**
     * @notice Verifica que múltiples liquidaciones secuenciales funcionan correctamente
     * @dev El estado se actualiza correctamente entre liquidaciones
     */
    function test_Liquidate_MultipleLiquidations_SequentialStateCorrect() public {
        // Setup: Dos usuarios en posiciones que serán liquidables
        vm.startPrank(user);
        engine.depositCollateral(10 ether);
        engine.mintTsc(6000e18);
        vm.stopPrank();

        vm.startPrank(user2);
        engine.depositCollateral(8 ether);
        engine.mintTsc(5000e18);
        vm.stopPrank();

        uint256 user1Debt = engine.getStablecoinMinted(user);
        uint256 user2Debt = engine.getStablecoinMinted(user2);

        // Caída de precio hace ambos liquidables
        priceFeed.updateAnswer(700e8);

        assertLt(engine.getHealthFactor(user), 1e18);
        assertLt(engine.getHealthFactor(user2), 1e18);

        // Setup liquidador con recursos suficientes para ambas liquidaciones
        vm.startPrank(liquidator);
        engine.depositCollateral(60 ether);
        engine.mintTsc(user1Debt + user2Debt + 3000e18); // Suficiente para ambas deudas
        tsc.approve(address(engine), type(uint256).max);

        // Primera liquidación
        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);
        engine.liquidate(user);

        uint256 liquidatorWethAfterFirst = weth.balanceOf(liquidator);
        assertGt(liquidatorWethAfterFirst, liquidatorWethBefore);

        // Verificar que user fue liquidado completamente
        assertEq(engine.getStablecoinMinted(user), 0);
        assertEq(engine.getHealthFactor(user), type(uint256).max);

        // Segunda liquidación
        engine.liquidate(user2);

        uint256 liquidatorWethAfterSecond = weth.balanceOf(liquidator);
        assertGt(liquidatorWethAfterSecond, liquidatorWethAfterFirst);

        // Verificar que user2 fue liquidado completamente
        assertEq(engine.getStablecoinMinted(user2), 0);
        assertEq(engine.getHealthFactor(user2), type(uint256).max);

        // Liquidador sigue saludable después de ambas
        assertGt(engine.getHealthFactor(liquidator), 1e18);
        vm.stopPrank();
    }
}
