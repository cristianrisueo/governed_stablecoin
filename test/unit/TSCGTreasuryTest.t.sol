// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TSCGTreasury} from "../../src/governance/TSCGTreasury.sol";
import {TSCGovernanceToken} from "../../src/governance/TSCGovernanceToken.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title TSCGTreasuryTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para el Treasury de TSCG
 * @dev Tests que verifican compra de tokens, actualización de precio y withdrawals
 */
contract TSCGTreasuryTest is Test {
    // Contratos
    TSCGTreasury public treasury;
    TSCGovernanceToken public tscg;
    ERC20Mock public weth;

    // Direcciones de prueba
    address public owner;
    address public buyer;

    // Constantes
    uint256 public constant INITIAL_SUPPLY = 1000000e18;
    uint256 public constant INITIAL_PRICE = 0.001 ether; // 1e15 wei

    // Eventos
    event TSCGPurchased(address indexed buyer, uint256 tscgAmount, uint256 wethPaid);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event WETHWithdrawn(address indexed to, uint256 amount);
    event TSCGWithdrawn(address indexed to, uint256 amount);

    /**
     * @notice Configuración inicial ejecutada antes de cada test
     */
    function setUp() public {
        // Setup de direcciones
        owner = makeAddr("owner");
        buyer = makeAddr("buyer");

        // Deployment de contratos
        tscg = new TSCGovernanceToken(INITIAL_SUPPLY);
        weth = new ERC20Mock();

        vm.prank(owner);
        treasury = new TSCGTreasury(address(tscg), address(weth), INITIAL_PRICE);

        // Transferir TSCG al Treasury para ventas
        tscg.transfer(address(treasury), 500000e18);

        // Dar WETH al comprador
        weth.mint(buyer, 100 ether);

        // Comprador aprueba WETH al Treasury
        vm.prank(buyer);
        weth.approve(address(treasury), type(uint256).max);
    }

    /**
     * @notice Verifica que el constructor inicializa correctamente
     * @dev Valida direcciones y precio inicial
     */
    function test_Constructor_InitializesCorrectly() public view {
        // Verificación: Precio inicial correcto
        assertEq(treasury.getTSCGPrice(), INITIAL_PRICE);

        // Verificación: Balance de TSCG en Treasury
        assertEq(treasury.getTSCGBalance(), 500000e18);

        // Verificación: Owner es correcto
        assertEq(treasury.owner(), owner);
    }

    /**
     * @notice Verifica que el constructor revierte con dirección TSCG inválida
     * @dev address(0) no es válido para tscgToken
     */
    function test_Constructor_RevertsWhen_TSCGAddressZero() public {
        // Acción + Verificación: Debe revertir
        vm.expectRevert(TSCGTreasury.TSCGTreasury__InvalidAddress.selector);
        new TSCGTreasury(address(0), address(weth), INITIAL_PRICE);
    }

    /**
     * @notice Verifica que el constructor revierte con dirección WETH inválida
     * @dev address(0) no es válido para weth
     */
    function test_Constructor_RevertsWhen_WethAddressZero() public {
        // Acción + Verificación: Debe revertir
        vm.expectRevert(TSCGTreasury.TSCGTreasury__InvalidAddress.selector);
        new TSCGTreasury(address(tscg), address(0), INITIAL_PRICE);
    }

    /**
     * @notice Verifica que el constructor revierte con precio cero
     * @dev initialPrice debe ser > 0
     */
    function test_Constructor_RevertsWhen_PriceZero() public {
        // Acción + Verificación: Debe revertir
        vm.prank(owner);
        vm.expectRevert(TSCGTreasury.TSCGTreasury__NeedsMoreThanZero.selector);
        new TSCGTreasury(address(tscg), address(weth), 0);
    }

    /**
     * @notice Verifica que buyTSCG transfiere WETH desde el comprador
     * @dev El comprador paga en WETH
     */
    function test_BuyTSCG_TransfersWethFromBuyer() public {
        // Setup: Cantidad a comprar
        uint256 tscgAmount = 1000e18; // 1000 TSCG
        uint256 expectedWethCost = treasury.calculateWETHCost(tscgAmount);

        uint256 buyerWethBefore = weth.balanceOf(buyer);

        // Acción: Comprar TSCG
        vm.prank(buyer);
        treasury.buyTSCG(tscgAmount);

        // Verificación: WETH del comprador decrementó
        assertEq(weth.balanceOf(buyer), buyerWethBefore - expectedWethCost);
    }

    /**
     * @notice Verifica que buyTSCG transfiere TSCG al comprador
     * @dev El comprador recibe TSCG
     */
    function test_BuyTSCG_TransfersTSCGToBuyer() public {
        // Setup: Cantidad a comprar
        uint256 tscgAmount = 1000e18;

        // Acción: Comprar TSCG
        vm.prank(buyer);
        treasury.buyTSCG(tscgAmount);

        // Verificación: Comprador recibió TSCG
        assertEq(tscg.balanceOf(buyer), tscgAmount);
    }

    /**
     * @notice Verifica que buyTSCG calcula correctamente el costo en WETH
     * @dev Costo = (tscgAmount * precio) / 1e18
     */
    function test_BuyTSCG_CalculatesCorrectWethCost() public {
        // Setup: Cantidad a comprar
        uint256 tscgAmount = 5000e18; // 5000 TSCG
        // Costo: 5000 * 0.001 ether = 5 ether

        uint256 expectedCost = (tscgAmount * INITIAL_PRICE) / 1e18;
        assertEq(expectedCost, 5 ether);

        uint256 treasuryWethBefore = treasury.getWETHBalance();

        // Acción: Comprar TSCG
        vm.prank(buyer);
        treasury.buyTSCG(tscgAmount);

        // Verificación: Treasury recibió WETH correcto
        assertEq(treasury.getWETHBalance(), treasuryWethBefore + expectedCost);
    }

    /**
     * @notice Verifica que buyTSCG emite el evento correcto
     * @dev Debe emitir TSCGPurchased con parámetros correctos
     */
    function test_BuyTSCG_EmitsEvent() public {
        // Setup: Cantidad a comprar
        uint256 tscgAmount = 1000e18;
        uint256 wethCost = treasury.calculateWETHCost(tscgAmount);

        // Acción + Verificación: Debe emitir evento
        vm.expectEmit(true, false, false, true);
        emit TSCGPurchased(buyer, tscgAmount, wethCost);

        vm.prank(buyer);
        treasury.buyTSCG(tscgAmount);
    }

    /**
     * @notice Verifica que buyTSCG revierte cuando amount = 0
     * @dev No se puede comprar 0 tokens
     */
    function test_BuyTSCG_RevertsWhen_AmountZero() public {
        // Acción + Verificación: Debe revertir
        vm.prank(buyer);
        vm.expectRevert(TSCGTreasury.TSCGTreasury__NeedsMoreThanZero.selector);
        treasury.buyTSCG(0);
    }

    /**
     * @notice Verifica que buyTSCG revierte cuando Treasury no tiene suficiente TSCG
     * @dev Previene compras mayores al balance
     */
    function test_BuyTSCG_RevertsWhen_InsufficientTreasuryBalance() public {
        // Setup: Intentar comprar más de lo disponible
        uint256 treasuryBalance = treasury.getTSCGBalance();
        uint256 tooMuch = treasuryBalance + 1;

        // Acción + Verificación: Debe revertir
        vm.prank(buyer);
        vm.expectRevert(TSCGTreasury.TSCGTreasury__InsufficientTSCGBalance.selector);
        treasury.buyTSCG(tooMuch);
    }

    /**
     * @notice Verifica que updatePrice actualiza correctamente el precio
     * @dev Solo el owner puede actualizar
     */
    function test_UpdatePrice_UpdatesCorrectly() public {
        // Setup: Nuevo precio
        uint256 newPrice = 0.002 ether;

        // Acción: Owner actualiza precio
        vm.prank(owner);
        treasury.updatePrice(newPrice);

        // Verificación: Precio actualizado
        assertEq(treasury.getTSCGPrice(), newPrice);
    }

    /**
     * @notice Verifica que updatePrice emite el evento correcto
     * @dev Debe emitir PriceUpdated con valores old y new
     */
    function test_UpdatePrice_EmitsEvent() public {
        // Setup: Nuevo precio
        uint256 oldPrice = INITIAL_PRICE;
        uint256 newPrice = 0.0015 ether;

        // Acción + Verificación: Debe emitir evento
        vm.expectEmit(false, false, false, true);
        emit PriceUpdated(oldPrice, newPrice);

        vm.prank(owner);
        treasury.updatePrice(newPrice);
    }

    /**
     * @notice Verifica que solo el owner puede actualizar el precio
     * @dev No owner no puede cambiar precio
     */
    function test_UpdatePrice_RevertsWhen_NotOwner() public {
        // Acción + Verificación: Debe revertir
        vm.prank(buyer);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        treasury.updatePrice(0.002 ether);
    }

    /**
     * @notice Verifica que updatePrice revierte cuando precio es cero
     * @dev Precio debe ser > 0
     */
    function test_UpdatePrice_RevertsWhen_PriceZero() public {
        // Acción + Verificación: Debe revertir
        vm.prank(owner);
        vm.expectRevert(TSCGTreasury.TSCGTreasury__NeedsMoreThanZero.selector);
        treasury.updatePrice(0);
    }

    /**
     * @notice Verifica que withdrawWETH transfiere correctamente
     * @dev Owner puede retirar WETH acumulado
     */
    function test_WithdrawWETH_TransfersCorrectly() public {
        // Setup: Comprador compra TSCG para acumular WETH en Treasury
        vm.prank(buyer);
        treasury.buyTSCG(10000e18); // Genera WETH en Treasury

        uint256 treasuryWethBalance = treasury.getWETHBalance();
        address recipient = makeAddr("recipient");

        // Acción: Owner retira WETH
        vm.prank(owner);
        treasury.withdrawWETH(recipient, treasuryWethBalance);

        // Verificación: Recipient recibió WETH
        assertEq(weth.balanceOf(recipient), treasuryWethBalance);

        // Verificación: Treasury quedó vacío
        assertEq(treasury.getWETHBalance(), 0);
    }

    /**
     * @notice Verifica que solo el owner puede retirar WETH
     * @dev Protege fondos del Treasury
     */
    function test_WithdrawWETH_RevertsWhen_NotOwner() public {
        // Acción + Verificación: Debe revertir
        vm.prank(buyer);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        treasury.withdrawWETH(buyer, 1 ether);
    }

    /**
     * @notice Verifica que withdrawTSCG transfiere correctamente
     * @dev Owner puede retirar TSCG no vendido
     */
    function test_WithdrawTSCG_TransfersCorrectly() public {
        // Setup: Recipient
        address recipient = makeAddr("recipient");
        uint256 withdrawAmount = 100000e18;

        // Acción: Owner retira TSCG
        vm.prank(owner);
        treasury.withdrawTSCG(recipient, withdrawAmount);

        // Verificación: Recipient recibió TSCG
        assertEq(tscg.balanceOf(recipient), withdrawAmount);
    }

    /**
     * @notice Verifica que solo el owner puede retirar TSCG
     * @dev Protege tokens del Treasury
     */
    function test_WithdrawTSCG_RevertsWhen_NotOwner() public {
        // Acción + Verificación: Debe revertir
        vm.prank(buyer);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        treasury.withdrawTSCG(buyer, 1000e18);
    }
}
