// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

/**
 * @title HelperConfig
 * @author cristianrisueo
 * @notice Gestiona la configuración para el despliegue en Sepolia
 * @dev Proporciona las direcciones de WETH y Chainlink price feed reales de Sepolia
 */
contract HelperConfig is Script {
    //* Structs

    /**
     * @notice Configuración de red que contiene todas las direcciones necesarias
     * @param wethAddress Dirección del token WETH en Sepolia
     * @param priceFeedAddress Dirección del contrato chainlink price feed ETH/USD en Sepolia
     */
    struct NetworkConfig {
        address wethAddress;
        address priceFeedAddress;
    }

    //* Variables de Estado

    /**
     * @dev Configuración activa para Sepolia
     */
    NetworkConfig public activeNetworkConfig;

    //* Constantes - Direcciones de Sepolia

    /**
     * @dev Dirección del contrato WETH en Sepolia testnet
     * @dev Fuente: https://sepolia.etherscan.io/token/0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9
     */
    address constant SEPOLIA_WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;

    /**
     * @dev Dirección del Chainlink ETH/USD price feed en Sepolia
     * @dev Fuente: https://sepolia.etherscan.io/address/0x694AA1769357215DE4FAC081bf1f309aDC325306
     * @dev Decimales: 8
     */
    address constant SEPOLIA_ETH_USD_PRICE_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    //* Constructor

    /**
     * @notice Constructor que configura las direcciones de Sepolia
     */
    constructor() {
        activeNetworkConfig = getSepoliaConfig();
    }

    //* Funciones de Configuración

    /**
     * @notice Obtiene la configuración para Sepolia testnet
     * @dev Usa direcciones reales de WETH y Chainlink en Sepolia
     * @return config Configuración con direcciones reales
     */
    function getSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({wethAddress: SEPOLIA_WETH, priceFeedAddress: SEPOLIA_ETH_USD_PRICE_FEED});
    }
}
