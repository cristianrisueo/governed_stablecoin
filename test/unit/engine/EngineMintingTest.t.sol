// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestStableCoinEngine} from "../../../src/stablecoin/TestStableCoinEngine.sol";
import {TestStableCoin} from "../../../src/stablecoin/TestStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";

/**
 * @title EngineMintingTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para operaciones de minting y burning de TSC
 * @dev Tests que verifican mint, burn y cálculo de fees
 */
contract EngineMintingTest is Test {
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
    uint256 public constant DEFAULT_MINT_FEE = 20; // 20 basis points = 0.2%

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

        // Usuario deposita colateral
        vm.prank(user);
        engine.depositCollateral(20 ether); // $40,000 de colateral
    }

    /**
     * @notice Verifica que mintTsc incrementa la deuda del usuario
     * @dev Valida que s_stablecoinMinted[user] aumenta correctamente
     */
    function test_MintTsc_IncreasesUserDebt() public {
        // Setup: Cantidad a mintear
        uint256 mintAmount = 5000e18;

        // Acción: Usuario mintea TSC
        vm.prank(user);
        engine.mintTsc(mintAmount);

        // Verificación: La deuda debe incrementar (monto neto después de fee)
        uint256 fee = (mintAmount * DEFAULT_MINT_FEE) / 10000;
        uint256 netAmount = mintAmount - fee;
        assertEq(engine.getStablecoinMinted(user), netAmount);
    }

    /**
     * @notice Verifica que mintTsc mintea el monto neto correcto
     * @dev El usuario recibe amount - fee en su wallet
     */
    function test_MintTsc_MintsCorrectNetAmount() public {
        // Setup: Cantidad a mintear
        uint256 mintAmount = 10000e18;

        // Acción: Mintear TSC
        vm.prank(user);
        engine.mintTsc(mintAmount);

        // Verificación: Usuario recibe monto neto (después de fee)
        uint256 fee = (mintAmount * DEFAULT_MINT_FEE) / 10000; // 0.2%
        uint256 expectedBalance = mintAmount - fee;
        assertEq(tsc.balanceOf(user), expectedBalance);
    }

    /**
     * @notice Verifica que la mint fee va al insurance fund
     * @dev El fondo de seguro debe incrementar con cada mint
     */
    function test_MintTsc_IncreasesInsuranceFund() public {
        // Setup: Balance inicial del insurance fund
        uint256 insuranceBefore = engine.getInsuranceFundBalance();
        uint256 mintAmount = 5000e18;

        // Acción: Mintear TSC
        vm.prank(user);
        engine.mintTsc(mintAmount);

        // Verificación: El insurance fund debe incrementar
        uint256 expectedFee = (mintAmount * DEFAULT_MINT_FEE) / 10000;
        assertEq(engine.getInsuranceFundBalance(), insuranceBefore + expectedFee);
    }

    /**
     * @notice Verifica que mintTsc revierte cuando amount = 0
     * @dev Valida el modifier moreThanZero
     */
    function test_MintTsc_RevertsWhen_AmountZero() public {
        // Acción + Verificación: Debe revertir
        vm.prank(user);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__NeedsMoreThanZero.selector);
        engine.mintTsc(0);
    }

    /**
     * @notice Verifica que mintTsc revierte cuando rompe el health factor
     * @dev No se puede mintear TSC si deja HF < 1
     */
    function test_MintTsc_RevertsWhen_BreaksHealthFactor() public {
        // Acción + Verificación: Intentar mintear demasiado
        // Con $40,000 colateral y threshold 50%, máximo es ~$20,000
        vm.prank(user);
        vm.expectRevert(); // BreaksHealthFactor
        engine.mintTsc(25000e18); // Intentar mintear $25,000
    }

    /**
     * @notice Verifica que la fee se calcula correctamente (20 bps por defecto)
     * @dev Fee = amount * 20 / 10000 = amount * 0.002
     */
    function test_MintTsc_CalculatesFeeCorrectly() public {
        // Setup: Diferentes montos para verificar cálculo
        uint256 mintAmount1 = 1000e18;
        uint256 mintAmount2 = 7500e18;

        // Acción: Primer mint
        vm.prank(user);
        engine.mintTsc(mintAmount1);

        uint256 expectedFee1 = (mintAmount1 * 20) / 10000; // 2e18
        assertEq(engine.getInsuranceFundBalance(), expectedFee1);

        // Acción: Segundo mint
        vm.prank(user);
        engine.mintTsc(mintAmount2);

        // Verificación: Fee acumulada correctamente
        uint256 expectedFee2 = (mintAmount2 * 20) / 10000; // 15e18
        assertEq(engine.getInsuranceFundBalance(), expectedFee1 + expectedFee2);
    }

    /**
     * @notice Verifica que burnTsc decrementa la deuda del usuario
     * @dev Valida que s_stablecoinMinted[user] disminuye
     */
    function test_BurnTsc_DecreasesUserDebt() public {
        // Setup: Usuario mintea primero
        vm.prank(user);
        engine.mintTsc(5000e18);

        uint256 debtBefore = engine.getStablecoinMinted(user);

        // Acción: Usuario aprueba y quema TSC
        uint256 burnAmount = 2000e18;
        vm.startPrank(user);
        tsc.approve(address(engine), burnAmount);
        engine.burnTsc(burnAmount);
        vm.stopPrank();

        // Verificación: La deuda debe decrementar
        assertEq(engine.getStablecoinMinted(user), debtBefore - burnAmount);
    }

    /**
     * @notice Verifica que burnTsc transfiere TSC desde el usuario
     * @dev El Engine recibe los tokens antes de quemarlos
     */
    function test_BurnTsc_TransfersTscFromUser() public {
        // Setup: Usuario mintea TSC
        vm.prank(user);
        engine.mintTsc(5000e18);

        uint256 userBalanceBefore = tsc.balanceOf(user);
        uint256 burnAmount = 1000e18;

        // Acción: Aprobar y quemar
        vm.startPrank(user);
        tsc.approve(address(engine), burnAmount);
        engine.burnTsc(burnAmount);
        vm.stopPrank();

        // Verificación: Balance del usuario decrementó
        assertEq(tsc.balanceOf(user), userBalanceBefore - burnAmount);
    }

    /**
     * @notice Verifica que burnTsc quema los tokens efectivamente
     * @dev El total supply debe decrementar
     */
    function test_BurnTsc_BurnsTokens() public {
        // Setup: Usuario mintea TSC
        vm.prank(user);
        engine.mintTsc(5000e18);

        uint256 totalSupplyBefore = tsc.totalSupply();
        uint256 burnAmount = 2000e18;

        // Acción: Quemar tokens
        vm.startPrank(user);
        tsc.approve(address(engine), burnAmount);
        engine.burnTsc(burnAmount);
        vm.stopPrank();

        // Verificación: Total supply decrementó
        assertEq(tsc.totalSupply(), totalSupplyBefore - burnAmount);
    }

    /**
     * @notice Verifica que burnTsc revierte cuando amount = 0
     * @dev Valida el modifier moreThanZero
     */
    function test_BurnTsc_RevertsWhen_AmountZero() public {
        // Setup: Usuario con deuda
        vm.prank(user);
        engine.mintTsc(5000e18);

        // Acción + Verificación: Debe revertir
        vm.prank(user);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__NeedsMoreThanZero.selector);
        engine.burnTsc(0);
    }
}
