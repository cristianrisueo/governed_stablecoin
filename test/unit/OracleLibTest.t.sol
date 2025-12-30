// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OracleLib} from "../../src/stablecoin/libraries/OracleLib.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLibTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para la librería OracleLib
 * @dev Tests que verifican la validación de freshness de precios del oracle
 */
contract OracleLibTest is Test {
    using OracleLib for AggregatorV3Interface;

    // Mock del price feed
    MockV3Aggregator public mockPriceFeed;
    AggregatorV3Interface public priceFeed;

    // Constantes
    uint256 public constant TIMEOUT = 3 hours;
    int256 public constant MOCK_PRICE = 2000e8; // $2000 con 8 decimales

    /**
     * @notice Configuración inicial ejecutada antes de cada test
     */
    function setUp() public {
        // Establecer timestamp inicial para evitar underflow
        vm.warp(4 hours);

        // Deployment del mock price feed
        mockPriceFeed = new MockV3Aggregator();
        priceFeed = AggregatorV3Interface(address(mockPriceFeed));

        // Configurar precio inicial
        mockPriceFeed.updateAnswer(MOCK_PRICE);
    }

    /**
     * @notice Verifica que retorna el precio cuando está actualizado
     * @dev El precio debe retornarse correctamente cuando el timestamp es reciente
     */
    function test_StaleCheck_ReturnsPrice_WhenFresh() public {
        // Setup: Establecer timestamp actual (fresh)
        mockPriceFeed.updateRoundData(
            1, // roundId
            MOCK_PRICE,
            block.timestamp, // startedAt
            block.timestamp, // updatedAt - ahora mismo
            1 // answeredInRound
        );

        // Acción: Obtener precio con verificación de freshness
        int256 price = priceFeed.staleCheckLatestRoundData();

        // Verificación: El precio debe coincidir con el mock
        assertEq(price, MOCK_PRICE);
    }

    /**
     * @notice Verifica que revierte cuando el precio tiene más de 3 horas
     * @dev Debe lanzar OracleLib__StalePrice cuando updatedAt < block.timestamp - TIMEOUT
     */
    function test_StaleCheck_RevertsWhen_PriceStale() public {
        // Setup: Establecer timestamp antiguo (más de 3 horas)
        uint256 staleTimestamp = block.timestamp - TIMEOUT - 1;
        mockPriceFeed.updateRoundData(1, MOCK_PRICE, staleTimestamp, staleTimestamp, 1);

        // Acción + Verificación: Debe revertir con error específico
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        priceFeed.staleCheckLatestRoundData();
    }

    /**
     * @notice Boundary test en el límite exacto de 3 horas
     * @dev Verifica el comportamiento cuando updatedAt = block.timestamp - TIMEOUT
     */
    function test_StaleCheck_WorksAt_ExactTimeout() public {
        // Setup: Establecer timestamp exactamente en el límite (3 horas atrás)
        uint256 exactLimitTimestamp = block.timestamp - TIMEOUT;
        mockPriceFeed.updateRoundData(1, MOCK_PRICE, exactLimitTimestamp, exactLimitTimestamp, 1);

        // Acción: Obtener precio en el límite exacto
        int256 price = priceFeed.staleCheckLatestRoundData();

        // Verificación: Debe permitir el precio en el límite exacto
        assertEq(price, MOCK_PRICE);
    }

    /**
     * @notice Verifica que el timeout es 3 horas
     * @dev Valida la constante TIMEOUT definida en OracleLib
     */
    function test_GetTimeout_Returns3Hours() public pure {
        // Verificación: El timeout debe ser exactamente 3 horas
        assertEq(OracleLib.getTimeout(), 3 hours);
    }
}

/**
 * @title MockV3Aggregator
 * @notice Mock simplificado de Chainlink AggregatorV3Interface para testing
 * @dev Permite controlar manualmente los valores retornados por latestRoundData
 */
contract MockV3Aggregator is AggregatorV3Interface {
    // Variables de estado para simular datos del oracle
    uint80 private s_roundId;
    int256 private s_answer;
    uint256 private s_startedAt;
    uint256 private s_updatedAt;
    uint80 private s_answeredInRound;

    uint8 public constant decimals = 8;
    string public constant description = "Mock ETH/USD";
    uint256 public constant version = 4;

    /**
     * @notice Actualiza solo el precio (answer)
     * @param answer Nuevo precio a retornar
     */
    function updateAnswer(int256 answer) external {
        s_answer = answer;
        s_updatedAt = block.timestamp;
        s_roundId++;
    }

    /**
     * @notice Actualiza todos los datos del round (para control completo en tests)
     * @param roundId ID del round
     * @param answer Precio
     * @param startedAt Timestamp de inicio
     * @param updatedAt Timestamp de actualización
     * @param answeredInRound Round en que se respondió
     */
    function updateRoundData(
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) external {
        s_roundId = roundId;
        s_answer = answer;
        s_startedAt = startedAt;
        s_updatedAt = updatedAt;
        s_answeredInRound = answeredInRound;
    }

    /**
     * @notice Retorna los datos del último round
     * @return roundId ID del round
     * @return answer Precio actual
     * @return startedAt Timestamp de inicio
     * @return updatedAt Timestamp de última actualización
     * @return answeredInRound Round en que se respondió
     */
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (s_roundId, s_answer, s_startedAt, s_updatedAt, s_answeredInRound);
    }

    // Funciones no utilizadas en estos tests pero requeridas por la interfaz
    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("Not implemented");
    }
}
