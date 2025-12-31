// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title TSCTimelockTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para el Timelock del protocolo
 * @dev Tests que verifican la configuración inicial del TimelockController
 */
contract TSCTimelockTest is Test {
    // Contrato bajo test
    TimelockController public timelock;

    // Direcciones de prueba
    address public deployer;
    address public governor;

    // Constantes
    uint256 public constant MIN_DELAY = 2 days; // 172800 segundos
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

    /**
     * @notice Configuración inicial ejecutada antes de cada test
     */
    function setUp() public {
        // Setup de direcciones
        deployer = address(this);
        governor = makeAddr("governor");

        // Setup de roles
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);

        proposers[0] = governor; // Solo el Governor puede proponer
        executors[0] = address(0); // address(0) = cualquiera puede ejecutar

        // Deployment del Timelock
        timelock = new TimelockController(MIN_DELAY, proposers, executors, deployer);
    }

    /**
     * @notice Verifica que el constructor asigna el rol PROPOSER correctamente
     * @dev Solo el Governor debe poder crear propuestas en el Timelock
     */
    function test_Constructor_SetsProposerRole() public view {
        // Acción: Verificar que el Governor tiene el rol PROPOSER
        bool hasRole = timelock.hasRole(PROPOSER_ROLE, governor);

        // Verificación: Governor debe tener el rol
        assertTrue(hasRole);

        // Verificación adicional: Deployer NO debe tener el rol (es solo admin)
        bool deployerHasRole = timelock.hasRole(PROPOSER_ROLE, deployer);
        assertFalse(deployerHasRole);
    }

    /**
     * @notice Verifica que el constructor asigna el rol EXECUTOR correctamente
     * @dev address(0) significa que cualquiera puede ejecutar propuestas aprobadas
     */
    function test_Constructor_SetsExecutorRole() public view {
        // Acción: Verificar que address(0) tiene el rol EXECUTOR
        bool hasRole = timelock.hasRole(EXECUTOR_ROLE, address(0));

        // Verificación: address(0) debe tener el rol (ejecución pública)
        assertTrue(hasRole);
    }
}
