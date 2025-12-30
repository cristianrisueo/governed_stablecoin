// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestStableCoinEngine} from "../../../src/stablecoin/TestStableCoinEngine.sol";
import {TestStableCoin} from "../../../src/stablecoin/TestStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";

/**
 * @title EngineLiquidationTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para el sistema de liquidaciones
 * @dev Tests simplificados que verifican liquidaciones y edge cases críticos
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
    address public liquidator;

    // Constantes
    uint8 public constant DECIMALS = 8;
    int256 public constant INITIAL_PRICE = 2000e8;

    /**
     * @notice Configuración inicial ejecutada antes de cada test
     */
    function setUp() public {
        // Establecer timestamp inicial para evitar underflow en el constructor
        vm.warp(16 days);

        // Setup de direcciones
        owner = makeAddr("owner");
        user = makeAddr("user");
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
        weth.mint(liquidator, 100 ether);

        // Aprobar WETH al Engine
        vm.prank(user);
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
}
