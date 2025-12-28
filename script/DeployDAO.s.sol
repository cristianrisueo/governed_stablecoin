// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {TSCGovernanceToken} from "../src/governance/TSCGovernanceToken.sol";
import {TSCTimelock} from "../src/governance/TSCTimeLock.sol";
import {TSCGovernor} from "../src/governance/TSCGovernor.sol";
import {TSCGTreasury} from "../src/governance/TSCGTreasury.sol";
import {TestStableCoinEngine} from "../src/stablecoin/TestStableCoinEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

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
 * - El deployer debe ser el owner actual del Engine
 * - Después de ejecutar, el Timelock será el owner del Engine (transferencia inmediata con Ownable)
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

    /**
     * @dev Precio inicial de TSCG: 0.001 WETH por token
     * 1 TSCG = 0.001 WETH (1e15 wei)
     */
    uint256 public constant INITIAL_TSCG_PRICE = 0.001 ether;

    /**
     * @dev Asignación inicial de TSCG al Treasury: 550,000 tokens (55% del supply)
     * Estos tokens estarán disponibles para compra por usuarios
     */
    uint256 public constant TREASURY_TSCG_ALLOCATION = 550_000 ether;

    //* Función principal de despliegue

    /**
     * @notice Ejecuta el despliegue completo del sistema de gobernanza en Sepolia
     * @dev Esta función se llama automáticamente con `forge script`
     * @param engineAddress Dirección del TestStableCoinEngine ya desplegado
     * @return governanceToken Contrato del token de gobernanza desplegado
     * @return timelock Contrato del Timelock desplegado
     * @return governor Contrato del Governor desplegado
     * @return treasury Contrato del Treasury para distribución de TSCG desplegado
     */
    function run(address engineAddress)
        external
        returns (TSCGovernanceToken governanceToken, TSCTimelock timelock, TSCGovernor governor, TSCGTreasury treasury)
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

        // Paso 7: Despliega TSCGTreasury
        console2.log("Desplegando TSCGTreasury...");

        // Obtiene dirección WETH desde HelperConfig
        HelperConfig helperConfig = new HelperConfig();
        (address wethAddress,) = helperConfig.activeNetworkConfig();

        treasury = new TSCGTreasury(address(governanceToken), wethAddress, INITIAL_TSCG_PRICE);
        console2.log("  TSCGTreasury desplegado en:", address(treasury));
        console2.log("  WETH address:", wethAddress);
        console2.log("  Precio inicial TSCG:", INITIAL_TSCG_PRICE, "wei (0.001 WETH)");
        console2.log("");

        // Paso 8: Transfiere TSCG al Treasury
        console2.log("Transfiriendo TSCG al Treasury...");
        bool transferSuccess = governanceToken.transfer(address(treasury), TREASURY_TSCG_ALLOCATION);
        require(transferSuccess, "Transfer de TSCG al Treasury fallo");
        console2.log("  [OK]", TREASURY_TSCG_ALLOCATION / 1e18, "TSCG transferidos al Treasury");
        console2.log("");

        // Paso 9: Transfiere ownership del Treasury al Timelock
        console2.log("Transfiriendo ownership del Treasury al Timelock...");
        treasury.transferOwnership(address(timelock));
        console2.log("  [OK] Treasury ownership transferido al Timelock");
        console2.log("");

        // Paso 10: Transfiere el ownership del Engine al Timelock
        console2.log("Transfiriendo ownership del Engine al Timelock...");
        engine.transferOwnership(address(timelock));
        console2.log("  [OK] Engine ownership transferido exitosamente");
        console2.log("");

        // Paso 11: Finaliza el broadcast
        vm.stopBroadcast();

        // Paso 12: Realiza validaciones post-despliegue
        _validateDeployment(governanceToken, timelock, governor, treasury, engine);

        console2.log("===========================================");
        console2.log("Despliegue de gobernanza completado!");
        console2.log("===========================================");
        console2.log("");
        console2.log("Direcciones desplegadas:");
        console2.log("  TSCGovernanceToken:", address(governanceToken));
        console2.log("  TSCTimelock:", address(timelock));
        console2.log("  TSCGovernor:", address(governor));
        console2.log("  TSCGTreasury:", address(treasury));
        console2.log("");
        console2.log("Sistema de gobernanza completamente configurado!");
        console2.log("  El Timelock es ahora el owner del Engine y Treasury.");
        console2.log("  Cambios en parametros requieren propuesta + votacion + 2 dias delay");
        console2.log("");
        console2.log("Distribucion de TSCG:");
        console2.log("  Deployer:", (INITIAL_SUPPLY - TREASURY_TSCG_ALLOCATION) / 1e18, "TSCG");
        console2.log("  Treasury:", TREASURY_TSCG_ALLOCATION / 1e18, "TSCG (disponible para compra)");
        console2.log("");

        return (governanceToken, timelock, governor, treasury);
    }

    //* Función interna de validación

    /**
     * @dev Valida que el despliegue se haya realizado correctamente
     * @param token Instancia del TSCGovernanceToken desplegado
     * @param timelock Instancia del TSCTimelock desplegado
     * @param governor Instancia del TSCGovernor desplegado
     * @param treasury Instancia del TSCGTreasury desplegado
     * @param engine Instancia del TestStableCoinEngine existente
     */
    function _validateDeployment(
        TSCGovernanceToken token,
        TSCTimelock timelock,
        TSCGovernor governor,
        TSCGTreasury treasury,
        TestStableCoinEngine engine
    ) private view {
        console2.log("Validando despliegue...");

        // Valida que los contratos tengan código
        require(address(token).code.length > 0, "GovernanceToken no tiene codigo");
        require(address(timelock).code.length > 0, "Timelock no tiene codigo");
        require(address(governor).code.length > 0, "Governor no tiene codigo");
        require(address(treasury).code.length > 0, "Treasury no tiene codigo");

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

        // Valida owner del Engine
        require(engine.owner() == address(timelock), "Timelock no es owner del Engine");
        console2.log("  [OK] Timelock es owner del Engine");

        // Valida parámetros del Governor
        require(governor.votingDelay() == VOTING_DELAY, "Voting delay incorrecto");
        require(governor.votingPeriod() == VOTING_PERIOD, "Voting period incorrecto");
        require(governor.proposalThreshold() == PROPOSAL_THRESHOLD, "Proposal threshold incorrecto");
        console2.log("  [OK] Parametros del Governor correctos");

        // Valida Treasury
        require(treasury.getTSCGPrice() == INITIAL_TSCG_PRICE, "Precio TSCG incorrecto");
        require(treasury.getTSCGBalance() == TREASURY_TSCG_ALLOCATION, "Balance TSCG en Treasury incorrecto");
        require(treasury.owner() == address(timelock), "Timelock no es owner del Treasury");
        console2.log("  [OK] Treasury configurado correctamente");

        console2.log("Validacion completada - Todo correcto!");
        console2.log("");
    }
}
