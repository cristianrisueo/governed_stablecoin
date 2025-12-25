// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title TSCTimelock
 * @author cristianrisueo
 * @notice Contrato de Timelock para el protocolo TestStableCoin
 * @dev Implementa TimelockController de OpenZeppelin para delay entre aprobación y ejecución de propuestas
 *
 * ¿POR QUÉ EXISTE EL TIMELOCK?
 * Imagina que una propuesta maliciosa pasa (ej: "drenar todo el colateral"):
 * - Sin Timelock: Se ejecuta inmediatamente → usuarios no pueden reaccionar
 * - Con Timelock: Hay 2 días entre aprobación y ejecución → usuarios pueden salir
 *
 * FLUJO COMPLETO:
 * 1. Propuesta pasa en Governor (51% votan a favor)
 * 2. Propuesta se ENCOLA (queue) en el Timelock
 * 3. Espera minDelay (ej: 2 días = 172800 segundos)
 * 4. Cualquiera puede EJECUTAR la propuesta
 * 5. Cambios se aplican en TestStableCoinEngine
 *
 * ROLES EN TIMELOCK:
 * - PROPOSER_ROLE: Quien puede realizar propuestas (solo el Governor contract)
 * - EXECUTOR_ROLE: Quien puede ejecutar propuestas aprobadas tras el delay (address(0) = cualquiera)
 * - ADMIN_ROLE: Quien puede gestionar roles (deployer inicialmente, se revoca automáticamente en DeployDAO.s.sol)
 *
 * OWNERSHIP:
 * - Este contrato será el owner de TestStableCoinEngine
 * - Solo el Timelock puede ejecutar funciones protegidas con onlyOwner en el Engine
 * - Garantiza que cambios en el protocolo requieren votación + delay de seguridad
 */
contract TSCTimelock is TimelockController {
    /**
     * @notice Constructor que configura el Timelock
     * @param minDelay Tiempo mínimo (en segundos) entre queue y ejecución
     * @param proposers Array de addresses que pueden proponer (debería ser solo [Governor])
     * @param executors Array de addresses que pueden ejecutar ([] = nadie, [address(0)] = cualquiera)
     * @param admin Address con ADMIN_ROLE inicial (típicamente deployer, luego se revoca)
     *
     * DECISIONES DE DISEÑO:
     * - minDelay = 2 días (172800 seg): Balance entre seguridad y agilidad
     * - proposers = [Governor address]: Solo el Governor, una vez pasó votación, puede proponer
     * - executors = [address(0)]: Cualquiera puede ejecutar propuestas que ya pasaron el delay
     * - admin = Inicialmente msg.sender (deployer): Se revoca en deployment para self-governance
     */
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {}
}
