// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin
 * @author cristianrisueo
 * @notice Stablecoin implementation
 * @dev This contract is just the stablecoin ERC20 implementation of our stablecoin
 * Pegged to USD, minted algorithmically and with wETH and wBTC as collateral.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    /**
     * @notice Mints new tokens and assigns them to a specified address
     * @dev Only the owner (DSCEngine) can mint tokens. The recipient address must not
     * be zero and the amount must be greater than zero
     * @param _to The address that will receive the newly minted tokens
     * @param _amount The amount of tokens to mint
     * @return bool True if the mint operation was successful
     */
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        // Checks that address and amount are not zero
        if (_to == address(0)) revert DecentralizedStableCoin__NotZeroAddress();
        if (_amount <= 0) revert DecentralizedStableCoin__MustBeMoreThanZero();

        // Mints and sends the tokens DSC tokens
        _mint(_to, _amount);

        // Returns true if everything is ok
        return true;
    }

    /**
     * @notice Burns (removes from circulation) tokens from the caller's balance
     * @dev Only the owner can burn tokens. The amount must be greater than zero
     * and the caller must have sufficient balance
     * @param _amount The amount of tokens to burn
     */
    function burn(uint256 _amount) public override onlyOwner {
        // Gets the caller balance (DSCEngine)
        uint256 balance = balanceOf(msg.sender);

        // Checks if the amount to burn is grater than zero and if the contract
        // has enough balance
        if (_amount <= 0) revert DecentralizedStableCoin__MustBeMoreThanZero();
        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }

        // Burns those DSC tokens from the DSCEngine contract balance
        super.burn(_amount);
    }
}
