// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Votes, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TSCGovernanceToken
 * @author cristianrisueo
 * @notice Token de governance para el protocolo TestStableCoin
 * @dev Implementa ERC20Votes que añade capacidad de voting a un ERC20 estándar
 *
 * CARACTERÍSTICAS CLAVE:
 * - ERC20Votes: Permite delegar voting power sin transferir tokens
 * - Snapshots: El voting power se congela en el momento de la propuesta (previene flashloan attacks)
 * - Checkpoints: Sistema eficiente de gas para trackear historical balances
 * - Ownable: Control de acceso para la función mint (solo para desarrollo/testing)
 */
contract TSCGovernanceToken is ERC20Votes, Ownable {
    //* Eventos

    /**
     * @dev Evento emitido cuando se mintean nuevos tokens de governance
     * @param to Dirección del usuario al que se le mintean los tokens
     * @param amount Cantidad de tokens minteados (en wei)
     */
    event TokensMinted(address indexed to, uint256 amount);

    /**
     * @notice Constructor que inicializa el token de governance
     * @dev EIP712 es necesario para ERC20Permit (firmas off-chain de approvals)
     * @param initialSupply Supply inicial de tokens que se mintearán al deployer
     *
     * NOTA IMPORTANTE:
     * - El supply inicial se mintea al deployer (quien también es el owner inicial)
     * - La función mint() tiene access control (onlyOwner) para desarrollo/testing
     * - En producción, considera eliminar mint() y usar solo supply fijo
     */
    constructor(uint256 initialSupply)
        ERC20("TestStableCoin Governance", "TSCG")
        EIP712("TestStableCoin Governance", "1")
        Ownable(msg.sender)
    {
        _mint(msg.sender, initialSupply);
    }

    /**
     * @notice Mintea tokens de governance (SOLO PARA DESARROLLO/TESTING)
     * @param to Dirección que recibirá los tokens
     * @param amount Cantidad de tokens a mintear
     *
     * SEGURIDAD:
     * - Solo el owner puede mintear tokens (protección contra manipulación de votaciones)
     * - En producción, considera eliminar esta función completamente
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }
}
