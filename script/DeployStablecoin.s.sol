// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {TestStableCoin} from "../src/stablecoin/TestStableCoin.sol";
import {TestStableCoinEngine} from "../src/stablecoin/TestStableCoinEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

/**
 * @title DeployStablecoin
 * @author cristianrisueo
 * @notice Script de despliegue del protocolo completo de stablecoin
 * @dev Maneja el despliegue en el orden correcto:
 * 1. Obtiene configuración de red (todo en sepolia con las direcciones reales, no mocks)
 * 2. Despliega TestStableCoin
 * 3. Despliega TestStableCoinEngine
 * 4. Transfiere ownership del token al Engine
 * 5. Retorna las direcciones desplegadas
 */
contract DeployStablecoin is Script {
    //* Función principal de despliegue

    /**
     * @notice Ejecuta el despliegue completo del sistema en Sepolia
     * @dev Esta función se llama automáticamente con `forge script`
     * @return testStableCoin Dirección del contrato TestStableCoin desplegado
     * @return testStableCoinEngine Dirección del contrato TestStableCoinEngine desplegado
     * @return helperConfig Instancia del HelperConfig usado
     */
    function run() external returns (TestStableCoin, TestStableCoinEngine, HelperConfig) {
        // Paso 1: Obtiene la configuración de Sepolia
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getSepoliaConfig();

        console2.log("===========================================");
        console2.log("Iniciando despliegue del protocolo TestStableCoin");
        console2.log("===========================================");
        console2.log("Red detectada - Chain ID:", block.chainid);
        console2.log("WETH address:", config.wethAddress);
        console2.log("PriceFeed address:", config.priceFeedAddress);
        console2.log("Deployer address:", msg.sender);
        console2.log("");

        // Paso 2: Inicia el broadcast para despliegues
        vm.startBroadcast();

        // Paso 3: Despliega TestStableCoin
        console2.log("Desplegando TestStableCoin...");
        TestStableCoin testStableCoin = new TestStableCoin();
        console2.log("TestStableCoin desplegado en:", address(testStableCoin));
        console2.log("");

        // Paso 4: Despliega TestStableCoinEngine con msg.sender como owner inicial
        console2.log("Desplegando TestStableCoinEngine...");
        TestStableCoinEngine testStableCoinEngine =
            new TestStableCoinEngine(config.wethAddress, address(testStableCoin), config.priceFeedAddress, msg.sender);
        console2.log("TestStableCoinEngine desplegado en:", address(testStableCoinEngine));
        console2.log("Owner inicial del Engine:", msg.sender);
        console2.log("");

        // Paso 5: Transfiere el ownership del token al Engine. CRÍTICO, el engine debe ser owner
        console2.log("Transfiriendo ownership de TSC al Engine...");
        testStableCoin.transferOwnership(address(testStableCoinEngine));
        console2.log("Ownership transferido exitosamente");
        console2.log("");

        // Paso 6: Finaliza el broadcast
        vm.stopBroadcast();

        // Paso 7: Realiza validaciones post-despliegue
        _validateDeployment(testStableCoin, testStableCoinEngine, config);

        console2.log("===========================================");
        console2.log("Despliegue completado exitosamente!");
        console2.log("===========================================");
        console2.log("");
        console2.log("Direcciones importantes:");
        console2.log("  TestStableCoin:", address(testStableCoin));
        console2.log("  TestStableCoinEngine:", address(testStableCoinEngine));
        console2.log("  WETH:", config.wethAddress);
        console2.log("  ETH/USD PriceFeed:", config.priceFeedAddress);
        console2.log("");

        return (testStableCoin, testStableCoinEngine, helperConfig);
    }

    //* Función interna de validación

    /**
     * @dev Valida que el despliegue se haya realizado correctamente
     * @param tsc Instancia del TestStableCoin desplegado
     * @param engine Instancia del TestStableCoinEngine desplegado
     * @param config Configuración de red usada
     */
    function _validateDeployment(
        TestStableCoin tsc,
        TestStableCoinEngine engine,
        HelperConfig.NetworkConfig memory config
    ) private view {
        console2.log("Validando despliegue...");

        // Valida que los contratos tengan código (no sean EOAs)
        require(address(tsc).code.length > 0, "TSC no tiene codigo");
        require(address(engine).code.length > 0, "Engine no tiene codigo");

        // Valida ownership del token
        require(tsc.owner() == address(engine), "Engine no es owner del TSC");
        console2.log("  [OK] Engine es owner del token");

        // Valida que el Engine tenga las direcciones correctas
        require(engine.getWeth() == config.wethAddress, "Engine tiene WETH address incorrecta");
        console2.log("  [OK] WETH address configurada correctamente");

        require(engine.getStablecoin() == address(tsc), "Engine tiene TSC address incorrecta");
        console2.log("  [OK] TSC address configurada correctamente");

        require(engine.getPriceFeed() == config.priceFeedAddress, "Engine tiene PriceFeed address incorrecta");
        console2.log("  [OK] PriceFeed address configurada correctamente");

        // Valida las constantes del Engine
        require(engine.getLiquidationThreshold() == 50, "Liquidation threshold incorrecta");
        require(engine.getLiquidationBonus() == 10, "Liquidation bonus incorrecta");
        require(engine.getMinHealthFactor() == 1e18, "Min health factor incorrecta");
        console2.log("  [OK] Constantes del Engine correctas");

        console2.log("Validacion completada - Todo correcto!");
        console2.log("");
    }
}
