// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {TSCGovernanceToken} from "../src/governance/TSCGovernanceToken.sol";
import {TSCTimelock} from "../src/governance/TSCTimeLock.sol";
import {TSCGovernor} from "../src/governance/TSCGovernor.sol";
import {TestStableCoinEngine} from "../src/stablecoin/TestStableCoinEngine.sol";

/**
 * @title DeployDAO
 * @author cristianrisueo
 * @notice Script de despliegue del sistema de gobernanza completo
 * @dev Maneja el despliegue en el orden correcto:
 * 1. Despliega TSCGovernanceToken (token de votación)
 * 2. Despliega TSCTimelock (delay de seguridad)
 * 3. Despliega TSCGovernor (sistema de votación)
 * 4. Configura roles del Timelock
 * 5. Transfiere ownership del Engine al Timelock
 *
 * FLUJO DE OWNERSHIP FINAL:
 * Holders TSCG → TSCGovernor → TSCTimelock → TestStableCoinEngine → TestStableCoin
 *
 * IMPORTANTE:
 * - Este script requiere la dirección del TestStableCoinEngine ya desplegado
 * - El deployer debe ser el owner actual del Engine para transferir ownership
 * - Después de ejecutar, el Timelock será el owner del Engine
 */
contract DeployDAO is Script {
    //* Configuración de Gobernanza

    /**
     * @dev Supply inicial del token de gobernanza (1 millón de tokens)
     * Estos tokens se mintean al deployer, quien luego los distribuye
     */
    uint256 public constant INITIAL_SUPPLY = 1_000_000 ether;

    /**
     * @dev Delay del Timelock: 2 días = 172800 segundos
     * Tiempo entre aprobación de propuesta y ejecución
     */
    uint256 public constant MIN_DELAY = 2 days;

    /**
     * @dev Voting delay: 1 bloque
     * Bloques de espera antes de que comience la votación
     */
    uint48 public constant VOTING_DELAY = 1;

    /**
     * @dev Voting period: ~1 semana (50400 bloques con 12 seg/bloque)
     * Duración del período de votación
     */
    uint32 public constant VOTING_PERIOD = 50400;

    /**
     * @dev Proposal threshold: 1000 tokens (0.1% del supply)
     * Tokens mínimos requeridos para crear una propuesta
     */
    uint256 public constant PROPOSAL_THRESHOLD = 1000 ether;

    /**
     * @dev Quorum: 5% del supply total
     * Porcentaje mínimo de participación para que una propuesta sea válida
     */
    uint256 public constant QUORUM_PERCENTAGE = 5;

    //* Función principal de despliegue

    /**
     * @notice Ejecuta el despliegue completo del sistema de gobernanza en Sepolia
     * @dev Esta función se llama automáticamente con `forge script`
     * @param engineAddress Dirección del TestStableCoinEngine ya desplegado
     * @return governanceToken Contrato del token de gobernanza desplegado
     * @return timelock Contrato del Timelock desplegado
     * @return governor Contrato del Governor desplegado
     */
    function run(address engineAddress)
        external
        returns (TSCGovernanceToken governanceToken, TSCTimelock timelock, TSCGovernor governor)
    {
        // Paso 1: Obtiene referencia al Engine
        TestStableCoinEngine engine = TestStableCoinEngine(engineAddress);

        console2.log("===========================================");
        console2.log("Iniciando despliegue del sistema de gobernanza");
        console2.log("===========================================");
        console2.log("Red detectada - Chain ID:", block.chainid);
        console2.log("Engine address:", engineAddress);
        console2.log("Engine owner actual:", engine.owner());
        console2.log("Deployer address:", msg.sender);
        console2.log("");

        // Paso 2: Inicia el broadcast para despliegues
        vm.startBroadcast();

        // Paso 3: Despliega TSCGovernanceToken
        console2.log("Desplegando TSCGovernanceToken...");
        governanceToken = new TSCGovernanceToken(INITIAL_SUPPLY);
        console2.log("  TSCGovernanceToken desplegado en:", address(governanceToken));
        console2.log("  Supply inicial:", INITIAL_SUPPLY / 1e18, "TSCG");
        console2.log("");

        // Paso 4: Despliega TSCTimelock
        // Inicialmente sin proposers (se añade el Governor después)
        // Executors = [address(0)] significa que cualquiera puede ejecutar
        console2.log("Desplegando TSCTimelock...");
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0); // Cualquiera puede ejecutar
        timelock = new TSCTimelock(MIN_DELAY, proposers, executors, msg.sender);
        console2.log("  TSCTimelock desplegado en:", address(timelock));
        console2.log("  Min delay:", MIN_DELAY / 1 days, "dias");
        console2.log("");

        // Paso 5: Despliega TSCGovernor
        console2.log("Desplegando TSCGovernor...");
        governor = new TSCGovernor(
            governanceToken, timelock, VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD, QUORUM_PERCENTAGE
        );
        console2.log("  TSCGovernor desplegado en:", address(governor));
        console2.log("  Voting delay:", VOTING_DELAY, "bloques");
        console2.log("  Voting period:", VOTING_PERIOD, "bloques (~1 semana)");
        console2.log("  Proposal threshold:", PROPOSAL_THRESHOLD / 1e18, "TSCG");
        console2.log("  Quorum:", QUORUM_PERCENTAGE, "%");
        console2.log("");

        // Paso 6: Configura roles del Timelock
        console2.log("Configurando roles del Timelock...");

        // 6.1: Asigna PROPOSER_ROLE al Governor
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        timelock.grantRole(proposerRole, address(governor));
        console2.log("  [OK] PROPOSER_ROLE asignado al Governor");

        // 6.2: Revoca ADMIN_ROLE del deployer (descentralización completa)
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        timelock.revokeRole(adminRole, msg.sender);
        console2.log("  [OK] ADMIN_ROLE revocado del deployer");
        console2.log("");

        // Paso 7: Transfiere el ownership del Engine al Timelock
        console2.log("Transfiriendo ownership del Engine al Timelock...");
        engine.transferOwnership(address(timelock));
        console2.log("  [OK] Transferencia iniciada (Ownable2Step - pendiente de aceptacion)");
        console2.log("");

        // Paso 8: Finaliza el broadcast
        vm.stopBroadcast();

        // Paso 9: Realiza validaciones post-despliegue
        _validateDeployment(governanceToken, timelock, governor, engine);

        console2.log("===========================================");
        console2.log("Despliegue de gobernanza completado!");
        console2.log("===========================================");
        console2.log("");
        console2.log("Direcciones desplegadas:");
        console2.log("  TSCGovernanceToken:", address(governanceToken));
        console2.log("  TSCTimelock:", address(timelock));
        console2.log("  TSCGovernor:", address(governor));
        console2.log("");
        console2.log("IMPORTANTE - Paso pendiente:");
        console2.log("  El Timelock debe aceptar ownership del Engine.");
        console2.log("  Esto requiere una propuesta de gobernanza que llame a:");
        console2.log("  engine.acceptOwnership()");
        console2.log("");

        return (governanceToken, timelock, governor);
    }

    //* Función interna de validación

    /**
     * @dev Valida que el despliegue se haya realizado correctamente
     * @param token Instancia del TSCGovernanceToken desplegado
     * @param timelock Instancia del TSCTimelock desplegado
     * @param governor Instancia del TSCGovernor desplegado
     * @param engine Instancia del TestStableCoinEngine existente
     */
    function _validateDeployment(
        TSCGovernanceToken token,
        TSCTimelock timelock,
        TSCGovernor governor,
        TestStableCoinEngine engine
    ) private view {
        console2.log("Validando despliegue...");

        // Valida que los contratos tengan código
        require(address(token).code.length > 0, "GovernanceToken no tiene codigo");
        require(address(timelock).code.length > 0, "Timelock no tiene codigo");
        require(address(governor).code.length > 0, "Governor no tiene codigo");

        // Valida supply del token de gobernanza
        require(token.totalSupply() == INITIAL_SUPPLY, "Supply incorrecto");
        console2.log("  [OK] TSCGovernanceToken supply correcto");

        // Valida que el Governor tenga PROPOSER_ROLE en el Timelock
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        require(timelock.hasRole(proposerRole, address(governor)), "Governor no tiene PROPOSER_ROLE");
        console2.log("  [OK] Governor tiene PROPOSER_ROLE en Timelock");

        // Valida que el admin role fue revocado (descentralización)
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        require(!timelock.hasRole(adminRole, msg.sender), "Deployer todavia tiene ADMIN_ROLE");
        console2.log("  [OK] ADMIN_ROLE revocado correctamente");

        // Valida pending owner del Engine
        require(engine.pendingOwner() == address(timelock), "Timelock no es pending owner del Engine");
        console2.log("  [OK] Timelock es pending owner del Engine");

        // Valida parámetros del Governor
        require(governor.votingDelay() == VOTING_DELAY, "Voting delay incorrecto");
        require(governor.votingPeriod() == VOTING_PERIOD, "Voting period incorrecto");
        require(governor.proposalThreshold() == PROPOSAL_THRESHOLD, "Proposal threshold incorrecto");
        console2.log("  [OK] Parametros del Governor correctos");

        console2.log("Validacion completada - Todo correcto!");
        console2.log("");
    }
}
