// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestStableCoin} from "../../src/stablecoin/TestStableCoin.sol";

/**
 * @title TestStableCoinTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para el contrato TestStableCoin
 * @dev Tests que verifican funcionalidad básica del token ERC20
 */
contract TestStableCoinTest is Test {
    // Contratos bajo test
    TestStableCoin public tsc;

    // Direcciones de prueba
    address public owner;
    address public user;

    // Eventos a verificar
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @notice Configuración inicial ejecutada antes de cada test
     */
    function setUp() public {
        // Setup de direcciones
        owner = address(this);
        user = makeAddr("user");

        // Deployment del contrato
        tsc = new TestStableCoin();
    }

    /**
     * @notice Verifica que el constructor inicializa correctamente nombre y símbolo
     * @dev El nombre debe ser "TestStableCoin" y el símbolo "TSC"
     */
    function test_Constructor_InitializesNameAndSymbol() public view {
        // Verificación: Nombre correcto
        assertEq(tsc.name(), "TestStableCoin");

        // Verificación: Símbolo correcto
        assertEq(tsc.symbol(), "TSC");
    }

    /**
     * @notice Verifica que mint incrementa correctamente el total supply
     * @dev Solo el owner puede mintear tokens
     */
    function test_Mint_SuccessfullyMintsTokens() public {
        // Setup: Cantidad a mintear
        uint256 mintAmount = 1000e18;

        // Acción: Owner mintea tokens al usuario
        tsc.mint(user, mintAmount);

        // Verificación: El balance del usuario debe incrementar
        assertEq(tsc.balanceOf(user), mintAmount);

        // Verificación: El total supply debe incrementar
        assertEq(tsc.totalSupply(), mintAmount);
    }

    /**
     * @notice Verifica que solo el owner puede mintear tokens
     * @dev Debe revertir si alguien diferente al owner intenta mintear
     */
    function test_Mint_RevertsWhen_NotOwner() public {
        // Setup: Usuario no autorizado intenta mintear
        uint256 mintAmount = 1000e18;

        // Acción + Verificación: Debe revertir con error de Ownable
        vm.prank(user);
        vm.expectRevert(); // OwnableUnauthorizedAccount(user)
        tsc.mint(user, mintAmount);
    }

    /**
     * @notice Verifica que no se puede mintear a la dirección zero
     * @dev ERC20 no permite mintear a address(0)
     */
    function test_Mint_RevertsWhen_ToAddressZero() public {
        // Setup: Intentar mintear a address(0)
        uint256 mintAmount = 1000e18;

        // Acción + Verificación: Debe revertir con error específico
        vm.expectRevert(TestStableCoin.TestStableCoin__NotZeroAddress.selector);
        tsc.mint(address(0), mintAmount);
    }

    /**
     * @notice Verifica que no se puede mintear cantidad cero
     * @dev Validación del contrato TestStableCoin
     */
    function test_Mint_RevertsWhen_AmountIsZero() public {
        // Setup: Intentar mintear 0 tokens
        uint256 mintAmount = 0;

        // Acción + Verificación: Debe revertir con error específico
        vm.expectRevert(TestStableCoin.TestStableCoin__MustBeMoreThanZero.selector);
        tsc.mint(user, mintAmount);
    }

    /**
     * @notice Verifica que burn reduce correctamente el total supply
     * @dev Solo el owner puede quemar tokens
     */
    function test_Burn_SuccessfullyBurnsTokens() public {
        // Setup: Mintear tokens al owner primero
        uint256 mintAmount = 1000e18;
        tsc.mint(owner, mintAmount);

        // Acción: Owner quema sus tokens
        uint256 burnAmount = 400e18;
        tsc.burn(burnAmount);

        // Verificación: El balance del owner debe decrementar
        assertEq(tsc.balanceOf(owner), mintAmount - burnAmount);

        // Verificación: El total supply debe decrementar
        assertEq(tsc.totalSupply(), mintAmount - burnAmount);
    }

    /**
     * @notice Verifica que no se puede quemar más tokens de los que se tienen
     * @dev Debe revertir si amount > balance
     */
    function test_Burn_RevertsWhen_AmountExceedsBalance() public {
        // Setup: Mintear tokens al owner
        uint256 mintAmount = 1000e18;
        tsc.mint(owner, mintAmount);

        // Acción + Verificación: Owner intenta quemar más de lo que tiene
        uint256 burnAmount = mintAmount + 1;
        vm.expectRevert(TestStableCoin.TestStableCoin__BurnAmountExceedsBalance.selector);
        tsc.burn(burnAmount);
    }
}
