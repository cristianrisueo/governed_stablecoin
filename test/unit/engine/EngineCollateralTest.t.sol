// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestStableCoinEngine} from "../../../src/stablecoin/TestStableCoinEngine.sol";
import {TestStableCoin} from "../../../src/stablecoin/TestStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";

/**
 * @title EngineCollateralTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para operaciones de colateral
 * @dev Tests que verifican depósito, retiro y funciones combinadas de colateral
 */
contract EngineCollateralTest is Test {
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
    int256 public constant INITIAL_PRICE = 2000e8;

    // Eventos
    event CollateralDeposited(address indexed user, uint256 indexed amountCollateral);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, uint256 amountCollateral);

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
     * @notice Verifica que depositCollateral incrementa el balance del usuario
     * @dev Valida que s_collateralDeposited[user] aumenta correctamente
     */
    function test_DepositCollateral_IncreasesUserBalance() public {
        // Setup: Cantidad a depositar
        uint256 depositAmount = 10 ether;

        // Acción: Usuario deposita colateral
        vm.prank(user);
        engine.depositCollateral(depositAmount);

        // Verificación: El balance de colateral debe incrementar
        assertEq(engine.getCollateralBalanceOfUser(user), depositAmount);
    }

    /**
     * @notice Verifica que depositCollateral transfiere WETH desde el usuario
     * @dev Valida que el balance de WETH cambia correctamente
     */
    function test_DepositCollateral_TransfersWethFromUser() public {
        // Setup: Balances iniciales
        uint256 depositAmount = 10 ether;
        uint256 userBalanceBefore = weth.balanceOf(user);
        uint256 engineBalanceBefore = weth.balanceOf(address(engine));

        // Acción: Depositar colateral
        vm.prank(user);
        engine.depositCollateral(depositAmount);

        // Verificación: WETH se transfirió correctamente
        assertEq(weth.balanceOf(user), userBalanceBefore - depositAmount);
        assertEq(weth.balanceOf(address(engine)), engineBalanceBefore + depositAmount);
    }

    /**
     * @notice Verifica que depositCollateral revierte cuando amount = 0
     * @dev Valida el modifier moreThanZero
     */
    function test_DepositCollateral_RevertsWhen_AmountZero() public {
        // Acción + Verificación: Debe revertir con error específico
        vm.prank(user);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(0);
    }

    /**
     * @notice Verifica que depositCollateral revierte cuando transferFrom falla
     * @dev Simula fallo de transferencia (sin aprobación)
     */
    function test_DepositCollateral_RevertsWhen_TransferFails() public {
        // Setup: Nuevo usuario sin aprobación
        address userNoApproval = makeAddr("userNoApproval");
        weth.mint(userNoApproval, 10 ether);

        // Acción + Verificación: Debe revertir cuando transferFrom falla
        // Nota: ERC20Mock revierte con ERC20InsufficientAllowance en lugar de retornar false
        vm.prank(userNoApproval);
        vm.expectRevert(); // ERC20InsufficientAllowance
        engine.depositCollateral(5 ether);
    }

    /**
     * @notice Verifica que redeemCollateral decrementa el balance del usuario
     * @dev Valida que s_collateralDeposited[user] disminuye correctamente
     */
    function test_RedeemCollateral_DecreasesUserBalance() public {
        // Setup: Usuario deposita primero
        uint256 depositAmount = 10 ether;
        vm.prank(user);
        engine.depositCollateral(depositAmount);

        // Acción: Usuario retira parte del colateral
        uint256 redeemAmount = 3 ether;
        vm.prank(user);
        engine.redeemCollateral(redeemAmount);

        // Verificación: El balance debe decrementar
        assertEq(engine.getCollateralBalanceOfUser(user), depositAmount - redeemAmount);
    }

    /**
     * @notice Verifica que redeemCollateral transfiere WETH al usuario
     * @dev Valida que el usuario recibe sus tokens WETH de vuelta
     */
    function test_RedeemCollateral_TransfersWethToUser() public {
        // Setup: Usuario deposita colateral
        uint256 depositAmount = 10 ether;
        vm.prank(user);
        engine.depositCollateral(depositAmount);

        uint256 userBalanceBefore = weth.balanceOf(user);

        // Acción: Usuario retira colateral
        uint256 redeemAmount = 5 ether;
        vm.prank(user);
        engine.redeemCollateral(redeemAmount);

        // Verificación: Usuario recibe WETH
        assertEq(weth.balanceOf(user), userBalanceBefore + redeemAmount);
    }

    /**
     * @notice Verifica que redeemCollateral revierte cuando amount = 0
     * @dev Valida el modifier moreThanZero
     */
    function test_RedeemCollateral_RevertsWhen_AmountZero() public {
        // Setup: Usuario con colateral
        vm.prank(user);
        engine.depositCollateral(10 ether);

        // Acción + Verificación: Debe revertir
        vm.prank(user);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateral(0);
    }

    /**
     * @notice Verifica que redeemCollateral revierte cuando rompe el health factor
     * @dev No se puede retirar colateral si deja HF < 1
     */
    function test_RedeemCollateral_RevertsWhen_BreaksHealthFactor() public {
        // Setup: Usuario deposita y mintea al límite
        vm.startPrank(user);
        engine.depositCollateral(10 ether); // $20,000
        engine.mintTsc(9000e18); // Casi al límite (threshold 50%)
        vm.stopPrank();

        // Acción + Verificación: Intentar retirar demasiado colateral debe revertir
        vm.prank(user);
        vm.expectRevert(); // BreaksHealthFactor
        engine.redeemCollateral(8 ether); // Esto rompería el HF
    }

    /**
     * @notice Verifica que depositAndMint ejecuta ambas operaciones
     * @dev Función de conveniencia que combina depósito y mint
     */
    function test_DepositAndMint_ExecutesBothOperations() public {
        // Setup: Cantidades
        uint256 collateralAmount = 10 ether;
        uint256 mintAmount = 5000e18;

        // Acción: Depositar y mintear en una transacción
        vm.prank(user);
        engine.depositCollateralAndMintTsc(collateralAmount, mintAmount);

        // Verificación: Colateral depositado
        assertEq(engine.getCollateralBalanceOfUser(user), collateralAmount);

        // Verificación: TSC minteado (menos fee)
        uint256 fee = (mintAmount * 20) / 10000; // 0.2% fee
        uint256 expectedBalance = mintAmount - fee;
        assertEq(tsc.balanceOf(user), expectedBalance);
    }

    /**
     * @notice Verifica que depositAndMint revierte cuando rompe el health factor
     * @dev La combinación no debe permitir HF < 1
     */
    function test_DepositAndMint_RevertsWhen_HealthFactorBroken() public {
        // Acción + Verificación: Intentar mintear demasiado para el colateral
        vm.prank(user);
        vm.expectRevert(); // BreaksHealthFactor
        engine.depositCollateralAndMintTsc(1 ether, 10000e18); // $2000 colateral, $10000 mint
    }

    /**
     * @notice Verifica que redeemForTsc ejecuta ambas operaciones
     * @dev Función de conveniencia que combina burn y redeem
     */
    function test_RedeemForTsc_ExecutesBothOperations() public {
        // Setup: Usuario tiene colateral y deuda
        vm.startPrank(user);
        engine.depositCollateral(10 ether);
        engine.mintTsc(5000e18);

        // Aprobar TSC al Engine para burn
        tsc.approve(address(engine), type(uint256).max);

        // Acción: Quemar TSC y retirar colateral
        uint256 burnAmount = 2000e18;
        uint256 redeemAmount = 3 ether;
        engine.redeemCollateralForTsc(redeemAmount, burnAmount);
        vm.stopPrank();

        // Verificación: Colateral reducido
        assertEq(engine.getCollateralBalanceOfUser(user), 7 ether);

        // Verificación: Deuda reducida
        uint256 originalDebt = 5000e18 - ((5000e18 * 20) / 10000); // Menos fee original
        uint256 expectedDebt = originalDebt - burnAmount;
        assertEq(engine.getStablecoinMinted(user), expectedDebt);
    }
}
