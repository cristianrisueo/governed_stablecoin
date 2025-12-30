// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TSCGovernor} from "../../src/governance/TSCGovernor.sol";
import {TSCGovernanceToken} from "../../src/governance/TSCGovernanceToken.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title TSCGovernorTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para el contrato Governor
 * @dev Tests simples de getters para configuración del Governor
 */
contract TSCGovernorTest is Test {
    // Contratos
    TSCGovernor public governor;
    TSCGovernanceToken public tscg;
    TimelockController public timelock;

    // Direcciones de prueba
    address public deployer;

    // Parámetros de configuración
    uint48 public constant VOTING_DELAY = 1; // 1 bloque en desarrollo
    uint32 public constant VOTING_PERIOD = 50400; // ~1 semana
    uint256 public constant PROPOSAL_THRESHOLD = 1000e18; // 1000 TSCG
    uint256 public constant QUORUM_PERCENTAGE = 5; // 5%
    uint256 public constant MIN_DELAY = 2 days; // Timelock delay

    /**
     * @notice Configuración inicial ejecutada antes de cada test
     */
    function setUp() public {
        // Setup de direcciones
        deployer = address(this);

        // Deployment del token de gobernanza
        tscg = new TSCGovernanceToken(1000000e18); // 1M supply

        // Setup del Timelock
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(1); // Placeholder, se actualizará al Governor
        executors[0] = address(0); // address(0) = cualquiera puede ejecutar

        timelock = new TimelockController(MIN_DELAY, proposers, executors, deployer);

        // Deployment del Governor
        governor = new TSCGovernor(
            tscg,
            timelock,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_PERCENTAGE
        );
    }

    /**
     * @notice Verifica que votingDelay retorna el valor correcto
     * @dev Debe retornar el initialVotingDelay del constructor
     */
    function test_VotingDelay_ReturnsCorrectValue() public view {
        // Acción: Obtener voting delay
        uint256 delay = governor.votingDelay();

        // Verificación: Debe ser el valor configurado
        assertEq(delay, VOTING_DELAY);
    }

    /**
     * @notice Verifica que votingPeriod retorna el valor correcto
     * @dev Debe retornar el initialVotingPeriod del constructor
     */
    function test_VotingPeriod_ReturnsCorrectValue() public view {
        // Acción: Obtener voting period
        uint256 period = governor.votingPeriod();

        // Verificación: Debe ser el valor configurado
        assertEq(period, VOTING_PERIOD);
    }

    /**
     * @notice Verifica que proposalThreshold retorna el valor correcto
     * @dev Tokens mínimos requeridos para crear propuesta
     */
    function test_ProposalThreshold_ReturnsCorrectValue() public view {
        // Acción: Obtener proposal threshold
        uint256 threshold = governor.proposalThreshold();

        // Verificación: Debe ser el valor configurado
        assertEq(threshold, PROPOSAL_THRESHOLD);
    }

    /**
     * @notice Verifica que quorum calcula correctamente el 5% del supply
     * @dev Quorum = (totalSupply * quorumPercentage) / 100
     */
    function test_Quorum_CalculatesCorrectly() public {
        // Setup: Delegar tokens para que se creen checkpoints
        tscg.delegate(deployer);

        // Avanzar un bloque para que el checkpoint sea válido
        vm.roll(block.number + 1);

        // Acción: Obtener quorum en bloque anterior (donde hay checkpoint)
        uint256 quorumVotes = governor.quorum(block.number - 1);

        // Verificación: 5% de 1M = 50,000 TSCG
        uint256 totalSupply = 1000000e18;
        uint256 expectedQuorum = (totalSupply * QUORUM_PERCENTAGE) / 100;
        assertEq(quorumVotes, expectedQuorum);
    }

    /**
     * @notice Verifica que proposalNeedsQueuing retorna true
     * @dev Todas las propuestas deben pasar por Timelock
     */
    function test_ProposalNeedsQueuing_ReturnsTrue() public {
        // Setup: Crear una propuesta dummy
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(tscg);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature("transfer(address,uint256)", deployer, 0);

        // Dar tokens al deployer y delegar para poder proponer
        tscg.delegate(deployer);
        vm.roll(block.number + 1);

        // Crear propuesta
        uint256 proposalId = governor.propose(targets, values, calldatas, "Test proposal");

        // Acción: Verificar si necesita queuing
        bool needsQueuing = governor.proposalNeedsQueuing(proposalId);

        // Verificación: Debe ser true (todas las propuestas pasan por Timelock)
        assertTrue(needsQueuing);
    }
}
