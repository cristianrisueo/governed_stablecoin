// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TestStableCoin
 * @author cristianrisueo
 * @notice Token ERC20 que representa la stablecoin del protocolo
 * @dev Este token solo puede ser acuñado y quemado por el contrato Engine
 *
 * Colateral: WETH (Wrapped Ether)
 * Estabilidad: Anclada al USD (1 TEC = 1 USD)
 *
 * Este contrato es el token ERC20 que los usuarios reciben al depositar colateral.
 * No contiene lógica de negocio, solo maneja la acuñación y quema controlada.
 */
contract TestStableCoin is ERC20Burnable, Ownable {
    /**
     * @dev Error que se lanza cuando se intenta quemar más tokens de los que se tienen
     */
    error TestStableCoin__BurnAmountExceedsBalance();

    /**
     * @dev Error que se lanza cuando se intenta acuñar a la dirección cero
     */
    error TestStableCoin__NotZeroAddress();

    /**
     * @dev Error que se lanza cuando se intenta acuñar una cantidad cero
     */
    error TestStableCoin__MustBeMoreThanZero();

    /**
     * @notice Constructor del token TestStableCoin
     * @dev Inicializa el token ERC20 con nombre y símbolo
     * @dev El deployer se convierte en el owner inicial (será transferido al Engine)
     */
    constructor() ERC20("TestStableCoin", "TSC") Ownable(msg.sender) {}

    /**
     * @notice Quema tokens del balance del caller
     * @param _amount Cantidad de tokens a quemar
     * @dev Override de la función burn para añadir validaciones custom
     * @dev Revierte si el balance es insuficiente o el monto a quemar cero
     */
    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        if (_amount <= 0) {
            revert TestStableCoin__MustBeMoreThanZero();
        }

        if (balance < _amount) {
            revert TestStableCoin__BurnAmountExceedsBalance();
        }

        super.burn(_amount);
    }

    /**
     * @notice Acuña nuevos tokens y los asigna a una dirección
     * @param _to Dirección que recibirá los tokens acuñados
     * @param _amount Cantidad de tokens a acuñar
     * @dev Solo puede ser llamada por el owner (TestStableCoinEngine)
     * @dev Revierte si la dirección de destino es cero o el monto es cero
     * @return true si la acuñación fue exitosa
     */
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert TestStableCoin__NotZeroAddress();
        }

        if (_amount <= 0) {
            revert TestStableCoin__MustBeMoreThanZero();
        }

        _mint(_to, _amount);
        return true;
    }
}
