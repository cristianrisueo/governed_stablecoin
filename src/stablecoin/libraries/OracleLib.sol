// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author cristianrisueo
 * @notice Librería para manejar las interacciones con Chainlink Price Feeds de forma segura
 * @dev Proporciona funciones para verificar que los datos del oráculo no estén obsoletos (stale)
 *
 * Esta librería protege el protocolo contra:
 * - Precios obsoletos (stale prices)
 * - Fallos en la actualización del oráculo
 * - Datos corruptos del price feed
 */
library OracleLib {
    /**
     * @dev Error que se lanza cuando el precio del oráculo está obsoleto
     */
    error OracleLib__StalePrice();

    /**
     * @dev Tiempo máximo permitido desde la última actualización del precio
     * @dev Si el precio tiene más de 3 horas de antigüedad, se considera obsoleto
     */
    uint256 private constant TIMEOUT = 3 hours;

    /**
     * @notice Obtiene los datos más recientes del price feed con verificación de obsolescencia
     * @param priceFeed El contrato AggregatorV3Interface de Chainlink a consultar
     * @dev Revierte si el precio está obsoleto (más de TIMEOUT desde última actualización)
     * @return answer El precio actual (con 8 decimales para ETH/USD)
     */
    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed) public view returns (int256) {
        // Únicamente necesitamos obtener el precio y la fecha de actualización, el resto lo omitimos
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();

        /**
         * Verificación crítica de seguridad:
         * Si han pasado más de TIMEOUT segundos desde la última actualización,
         * consideramos que el precio está obsoleto y revertimos la transacción.
         * Esto previene que se usen precios desactualizados en cálculos críticos.
         */
        uint256 secondsSince = block.timestamp - updatedAt;

        if (secondsSince > TIMEOUT) {
            revert OracleLib__StalePrice();
        }

        return answer;
    }

    /**
     * @notice Obtiene el timeout configurado para la verificación de precios
     * @return El tiempo máximo permitido en segundos
     */
    function getTimeout() public pure returns (uint256) {
        return TIMEOUT;
    }
}
