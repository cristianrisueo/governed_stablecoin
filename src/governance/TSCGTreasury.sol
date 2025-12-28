// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TSCGovernanceToken} from "./TSCGovernanceToken.sol";

/**
 * @title TSCGTreasury
 * @author cristianrisueo
 * @notice Treasury del protocolo TSC para distribución de tokens de gobernanza TSCG
 * @dev Permite a usuarios comprar tokens TSCG usando WETH a un precio fijo gobernable
 *
 * FUNCIONALIDAD PRINCIPAL:
 * - Intercambio WETH → TSCG a precio fijo
 * - Precio inicial: 1 TSCG = 0.001 WETH
 * - Precio ajustable vía gobernanza (TSCTimelock como owner)
 *
 * MECANISMO DE DISTRIBUCIÓN:
 * 1. Usuario aprueba WETH al Treasury
 * 2. Usuario llama buyTSCG(amount)
 * 3. Treasury transfiere WETH del usuario
 * 4. Treasury transfiere TSCG al usuario
 *
 * GOBERNANZA:
 * - Owner (Timelock) puede:
 *   - Actualizar precio de TSCG
 *   - Retirar WETH acumulado
 *   - Retirar TSCG no vendido
 *
 * OWNERSHIP CHAIN:
 * TSCG Holders → TSCGovernor → TSCTimelock (owner) → TSCGTreasury
 */
contract TSCGTreasury is Ownable {
    //* Errores

    /**
     * @dev Error lanzado cuando se proporciona una dirección inválida (address(0))
     */
    error TSCGTreasury__InvalidAddress();

    /**
     * @dev Error lanzado cuando se intenta operar con cantidad cero
     */
    error TSCGTreasury__NeedsMoreThanZero();

    /**
     * @dev Error lanzado cuando el Treasury no tiene suficiente balance de TSCG
     */
    error TSCGTreasury__InsufficientTSCGBalance();

    /**
     * @dev Error lanzado cuando una transferencia de tokens falla
     */
    error TSCGTreasury__TransferFailed();

    //* Variables de Estado

    /**
     * @dev Token de gobernanza TSCG (inmutable)
     */
    TSCGovernanceToken public immutable i_tscgToken;

    /**
     * @dev Token WETH usado para comprar TSCG (inmutable)
     */
    IERC20 public immutable i_weth;

    /**
     * @dev Precio de 1 TSCG en WETH (wei). Este valor es ajustable vía gobernanza
     * Ejemplo: 0.001 ether = 1e15 wei significa que 1 TSCG cuesta 0.001 WETH
     */
    uint256 private s_tscgPriceInWeth;

    //* Eventos

    /**
     * @notice Emitido cuando un usuario compra tokens TSCG
     * @param buyer Dirección del comprador
     * @param tscgAmount Cantidad de TSCG comprados (18 decimales)
     * @param wethPaid Cantidad de WETH pagados (18 decimales)
     */
    event TSCGPurchased(address indexed buyer, uint256 tscgAmount, uint256 wethPaid);

    /**
     * @notice Emitido cuando el precio de TSCG es actualizado por gobernanza
     * @param oldPrice Precio anterior en WETH (wei)
     * @param newPrice Nuevo precio en WETH (wei)
     */
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);

    /**
     * @notice Emitido cuando se retira WETH del Treasury
     * @param to Dirección destino
     * @param amount Cantidad de WETH retirados
     */
    event WETHWithdrawn(address indexed to, uint256 amount);

    /**
     * @notice Emitido cuando se retira TSCG del Treasury
     * @param to Dirección destino
     * @param amount Cantidad de TSCG retirados
     */
    event TSCGWithdrawn(address indexed to, uint256 amount);

    //* Constructor

    /**
     * @notice Constructor que inicializa el Treasury con tokens y precio inicial
     * @param tscgToken Dirección del token de gobernanza TSCG
     * @param weth Dirección del token WETH en la red actual (Sepolia: 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9)
     * @param initialPrice Precio inicial de 1 TSCG en WETH (wei). Ejemplo: 0.001 ether = 1e15
     * @dev El deployer será el owner inicial, luego se transfiere al Timelock
     */
    constructor(address tscgToken, address weth, uint256 initialPrice) Ownable(msg.sender) {
        if (tscgToken == address(0)) revert TSCGTreasury__InvalidAddress();
        if (weth == address(0)) revert TSCGTreasury__InvalidAddress();
        if (initialPrice == 0) revert TSCGTreasury__NeedsMoreThanZero();

        i_tscgToken = TSCGovernanceToken(tscgToken);
        i_weth = IERC20(weth);
        s_tscgPriceInWeth = initialPrice;
    }

    //* Funciones Externas

    /**
     * @notice Permite comprar tokens TSCG usando WETH a precio fijo
     * @param tscgAmount Cantidad de tokens TSCG a comprar (con 18 decimales)
     * @dev El usuario debe haber aprobado previamente WETH a este contrato
     *
     * FLUJO:
     * 1. Valida que tscgAmount > 0
     * 2. Valida que Treasury tiene suficiente TSCG
     * 3. Calcula WETH requerido basado en precio actual
     * 4. Transfiere WETH del usuario al Treasury
     * 5. Transfiere TSCG del Treasury al usuario
     * 6. Emite evento TSCGPurchased
     */
    function buyTSCG(uint256 tscgAmount) external {
        // Valida que la cantidad solicitada es mayor a cero
        if (tscgAmount == 0) revert TSCGTreasury__NeedsMoreThanZero();

        // Valida que Treasury tiene suficiente TSCG
        if (i_tscgToken.balanceOf(address(this)) < tscgAmount) {
            revert TSCGTreasury__InsufficientTSCGBalance();
        }

        // Calcula WETH a pagar: (tscgAmount * precio) / 1e18
        uint256 wethAmount = (tscgAmount * s_tscgPriceInWeth) / 1e18;

        // 1. Transfiere el WETH del usuario al Treasury
        bool wethSuccess = i_weth.transferFrom(msg.sender, address(this), wethAmount);
        if (!wethSuccess) revert TSCGTreasury__TransferFailed();

        // 2. Transfiere el TSCG del Treasury al usuario
        bool tscgSuccess = i_tscgToken.transfer(msg.sender, tscgAmount);
        if (!tscgSuccess) revert TSCGTreasury__TransferFailed();

        // Emite evento de compra exitosa
        emit TSCGPurchased(msg.sender, tscgAmount, wethAmount);
    }

    /**
     * @notice Actualiza el precio de TSCG en WETH
     * @param newPrice Nuevo precio de 1 TSCG en WETH (wei)
     * @dev Solo puede ser llamado por el owner (Timelock vía gobernanza)
     *
     * EJEMPLO DE USO VÍA GOBERNANZA:
     * - Crear propuesta para cambiar precio de 0.001 a 0.002 WETH
     * - Votar y aprobar propuesta
     * - Esperar 2 días (Timelock)
     * - Ejecutar: treasury.updatePrice(0.002 ether)
     */
    function updatePrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert TSCGTreasury__NeedsMoreThanZero();

        uint256 oldPrice = s_tscgPriceInWeth;
        s_tscgPriceInWeth = newPrice;

        emit PriceUpdated(oldPrice, newPrice);
    }

    /**
     * @notice Retira WETH acumulado del Treasury
     * @param to Dirección destino
     * @param amount Cantidad de WETH a retirar
     * @dev Solo puede ser llamado por el owner (Timelock vía gobernanza)
     * @dev Útil para gestionar fondos acumulados o migrar a nueva versión del Treasury
     */
    function withdrawWETH(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert TSCGTreasury__InvalidAddress();
        if (amount == 0) revert TSCGTreasury__NeedsMoreThanZero();

        bool success = i_weth.transfer(to, amount);
        if (!success) revert TSCGTreasury__TransferFailed();

        emit WETHWithdrawn(to, amount);
    }

    /**
     * @notice Retira TSCG no vendido del Treasury
     * @param to Dirección destino
     * @param amount Cantidad de TSCG a retirar
     * @dev Solo puede ser llamado por el owner (Timelock vía gobernanza)
     * @dev Útil para rebalanceo, quema, o migración de tokens
     */
    function withdrawTSCG(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert TSCGTreasury__InvalidAddress();
        if (amount == 0) revert TSCGTreasury__NeedsMoreThanZero();

        bool success = i_tscgToken.transfer(to, amount);
        if (!success) revert TSCGTreasury__TransferFailed();

        emit TSCGWithdrawn(to, amount);
    }

    //* Funciones View Públicas

    /**
     * @notice Obtiene el precio actual de TSCG en WETH
     * @return Precio de 1 TSCG en WETH (wei). Ejemplo: 1e15 = 0.001 WETH
     */
    function getTSCGPrice() external view returns (uint256) {
        return s_tscgPriceInWeth;
    }

    /**
     * @notice Calcula cuánto WETH cuesta una cantidad específica de TSCG
     * @param tscgAmount Cantidad de TSCG
     * @return Cantidad de WETH requerida
     * @dev Útil para interfaces frontend que necesitan mostrar el costo antes de comprar
     */
    function calculateWETHCost(uint256 tscgAmount) public view returns (uint256) {
        return (tscgAmount * s_tscgPriceInWeth) / 1e18;
    }

    /**
     * @notice Obtiene el balance de TSCG disponible en el Treasury
     * @return Balance de TSCG (18 decimales)
     * @dev Indica cuánto TSCG está disponible para comprar
     */
    function getTSCGBalance() external view returns (uint256) {
        return i_tscgToken.balanceOf(address(this));
    }

    /**
     * @notice Obtiene el balance de WETH en el Treasury
     * @return Balance de WETH (18 decimales)
     * @dev Indica cuánto WETH ha sido recaudado de ventas de TSCG
     */
    function getWETHBalance() external view returns (uint256) {
        return i_weth.balanceOf(address(this));
    }
}
