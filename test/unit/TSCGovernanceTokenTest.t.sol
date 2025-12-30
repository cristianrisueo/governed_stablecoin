// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TSCGovernanceToken} from "../../src/governance/TSCGovernanceToken.sol";

/**
 * @title TSCGovernanceTokenTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para el token de gobernanza TSCG
 * @dev Tests que verifican funcionalidad ERC20Votes y mint controlado
 */
contract TSCGovernanceTokenTest is Test {
    // Contrato bajo test
    TSCGovernanceToken public tscg;

    // Direcciones de prueba
    address public deployer;
    address public user;

    // Constantes
    uint256 public constant INITIAL_SUPPLY = 1000000e18; // 1 millón de tokens

    // Eventos
    event TokensMinted(address indexed to, uint256 amount);

    /**
     * @notice Configuración inicial ejecutada antes de cada test
     */
    function setUp() public {
        // Setup de direcciones
        deployer = address(this);
        user = makeAddr("user");

        // Deployment del token con supply inicial
        tscg = new TSCGovernanceToken(INITIAL_SUPPLY);
    }

    /**
     * @notice Verifica que el constructor mintea el supply inicial al deployer
     * @dev El deployer debe recibir todos los tokens iniciales
     */
    function test_Constructor_MintsInitialSupply() public view {
        // Verificación: El deployer tiene el supply inicial
        assertEq(tscg.balanceOf(deployer), INITIAL_SUPPLY);

        // Verificación: Total supply es correcto
        assertEq(tscg.totalSupply(), INITIAL_SUPPLY);
    }

    /**
     * @notice Verifica que el constructor establece nombre y símbolo correctos
     * @dev Nombre: "TestStableCoin Governance", Símbolo: "TSCG"
     */
    function test_Constructor_SetsCorrectNameAndSymbol() public view {
        // Verificación: Nombre correcto
        assertEq(tscg.name(), "TestStableCoin Governance");

        // Verificación: Símbolo correcto
        assertEq(tscg.symbol(), "TSCG");
    }

    /**
     * @notice Verifica que el deployer es establecido como owner
     * @dev Hereda de Ownable
     */
    function test_Constructor_SetsDeployerAsOwner() public view {
        // Verificación: El owner es el deployer
        assertEq(tscg.owner(), deployer);
    }

    /**
     * @notice Verifica que mint incrementa el total supply
     * @dev Solo el owner puede mintear
     */
    function test_Mint_IncreasesTotalSupply() public {
        // Setup: Cantidad a mintear
        uint256 mintAmount = 500000e18;
        uint256 totalSupplyBefore = tscg.totalSupply();

        // Acción: Owner mintea tokens
        tscg.mint(user, mintAmount);

        // Verificación: Total supply incrementó
        assertEq(tscg.totalSupply(), totalSupplyBefore + mintAmount);

        // Verificación: Usuario recibió los tokens
        assertEq(tscg.balanceOf(user), mintAmount);
    }

    /**
     * @notice Verifica que mint emite el evento TokensMinted
     * @dev Debe emitir con to y amount correctos
     */
    function test_Mint_EmitsEvent() public {
        // Setup: Cantidad a mintear
        uint256 mintAmount = 1000e18;

        // Acción + Verificación: Debe emitir evento
        vm.expectEmit(true, false, false, true);
        emit TokensMinted(user, mintAmount);

        tscg.mint(user, mintAmount);
    }

    /**
     * @notice Verifica que solo el owner puede mintear
     * @dev Usuarios no autorizados no pueden mintear tokens
     */
    function test_Mint_RevertsWhen_NotOwner() public {
        // Setup: Usuario no owner intenta mintear
        uint256 mintAmount = 1000e18;

        // Acción + Verificación: Debe revertir
        vm.prank(user);
        vm.expectRevert(); // OwnableUnauthorizedAccount(user)
        tscg.mint(user, mintAmount);
    }
}
