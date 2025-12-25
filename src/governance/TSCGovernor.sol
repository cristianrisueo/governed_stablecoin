// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title TSCGovernor
 * @author cristianrisueo
 * @notice Contrato principal de gobernanza para el protocolo TestStableCoin
 * @dev Implementa el sistema completo de votación on-chain usando OpenZeppelin Governor
 *
 * GOVERNOR CONTRACT. Permite a los holders de tokens TSCG:
 * 1. Crear propuestas de cambios al protocolo
 * 2. Votar en propuestas (For/Against/Abstain)
 * 3. Ejecutar propuestas aprobadas (tras pasar por Timelock)
 *
 * EXTENSIONES UTILIZADAS:
 * - Governor: Base contract con lógica core de proposals y votación
 * - GovernorSettings: Parámetros configurables (voting delay, voting period, proposal threshold)
 * - GovernorCountingSimple: Sistema de votación simple (For=1, Against=0, Abstain=2)
 * - GovernorVotes: Integración con ERC20Votes (TSCGovernanceToken) para contar voting power
 * - GovernorVotesQuorumFraction: Quorum basado en % del total supply (ej: 5%)
 * - GovernorTimelockControl: Integración con Timelock para delay de seguridad
 *
 * FLUJO DE UNA PROPUESTA:
 * 1. CREACIÓN: Usuario con suficientes tokens crea propuesta (propose)
 * 2. DELAY: Espera votingDelay antes de que comience la votación (ej: 1 bloque)
 * 3. VOTACIÓN: Período de votingPeriod donde holders votan (ej: 1 semana = 50400 bloques)
 * 4. VERIFICACIÓN: Si pasa quorum + mayoría → Succeeded, sino → Defeated
 * 5. QUEUE: Propuesta aprobada se encola en Timelock (queue)
 * 6. TIMELOCK: Espera minDelay en Timelock (ej: 2 días)
 * 7. EJECUCIÓN: Cualquiera ejecuta la propuesta (execute)
 *
 * PARÁMETROS DE CONFIGURACIÓN:
 * - Voting Delay: 1 bloque (7200 en producción = 1 día con bloques de 12 seg)
 * - Voting Period: 50400 bloques ≈ 1 semana (50400 * 12 seg)
 * - Proposal Threshold: 1000 TSCG = 0.1% si supply = 1M TSCG
 * - Quorum: 5% del total supply de TSCG tokens
 *
 * EJEMPLO DE PROPUESTA:
 * "Cambiar el liquidation threshold de 50% a 60%"
 * - targets: [TestStableCoinEngineAddress]
 * - values: [0] (no enviar ETH)
 * - calldatas: [abi.encodeWithSignature("updateLiquidationThreshold(uint256)", 60)]
 * - description: "TIP-001: Increase liquidation threshold to 60%"
 */
contract TSCGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /**
     * @notice Constructor que inicializa el Governor con todos sus parámetros
     * @param token Dirección del token de governance (TSCGovernanceToken)
     * @param timelock Dirección del Timelock contract
     * @param initialVotingDelay Bloques de espera antes de que comience la votación (dev: 1, pro: 7200 = 1 día)
     * @param initialVotingPeriod Bloques de duración de la votación (dev: 3, pro: 50400 = 1 semana)
     * @param initialProposalThreshold Tokens mínimos requeridos para crear propuesta (dev: 0, pro: 1000 TSCG)
     * @param quorumPercentage Porcentaje del supply requerido para quorum (5)
     */
    constructor(
        IVotes token,
        TimelockController timelock,
        uint48 initialVotingDelay,
        uint32 initialVotingPeriod,
        uint256 initialProposalThreshold,
        uint256 quorumPercentage
    )
        Governor("TSCGovernor")
        GovernorSettings(initialVotingDelay, initialVotingPeriod, initialProposalThreshold)
        GovernorVotes(token)
        GovernorVotesQuorumFraction(quorumPercentage)
        GovernorTimelockControl(timelock)
    {}

    //* Overrides requeridos por los contratos heredados

    /**
     * @dev Override requerido por GovernorSettings
     * @return Número de bloques de delay antes de que comience la votación
     */
    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    /**
     * @dev Override requerido por GovernorSettings
     * @return Número de bloques de duración de la votación
     */
    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    /**
     * @dev Override requerido por GovernorVotesQuorumFraction
     * @param blockNumber Número de bloque para consultar el quorum
     * @return Número mínimo de votos requeridos para que una propuesta sea válida
     */
    function quorum(uint256 blockNumber) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return super.quorum(blockNumber);
    }

    /**
     * @dev Override requerido por GovernorTimelockControl
     * @param proposalId ID de la propuesta
     * @return Estado actual de la propuesta (Pending, Active, Canceled, Defeated, Succeeded, Queued, Expired, Executed)
     */
    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    /**
     * @dev Override requerido por GovernorSettings
     * @return Número mínimo de tokens requeridos para crear una propuesta
     */
    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    /**
     * @dev Override requerido cuando usas GovernorTimelockControl
     * Determina si una propuesta necesita ser encolada en el Timelock
     * @return True porque TODAS las propuestas deben pasar por Timelock
     */
    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    /**
     * @dev Override requerido por GovernorTimelockControl
     * Ejecuta las operaciones aprobadas (llamadas a otros contratos)
     */
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /**
     * @dev Override requerido por GovernorTimelockControl
     * Encola las operaciones en el Timelock después de que una propuesta es aprobada
     */
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /**
     * @dev Override requerido por GovernorTimelockControl
     * Cancela propuestas (solo si el proposer ya no tiene suficientes tokens)
     */
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /**
     * @dev Override requerido por GovernorTimelockControl
     * Devuelve la dirección que ejecuta las propuestas (el Timelock)
     */
    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
