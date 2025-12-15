// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author cristianrisueo
 * @notice DecentralizedStableCoin engine contract, handles logic for minting and redeeming
 * @dev A minimal engine similar to DAI but without fees, governance and backed only by
 * wETH and wBTC
 */
contract DSCEngine is ReentrancyGuard {
    //* Errors

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAdressessMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();

    //* State variables

    uint256 private constant FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    DecentralizedStableCoin private immutable i_dsc;

    mapping(address token => address priceFeed) s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountMinted) s_DSCMinted;
    address[] private s_collateralTokens;

    //* Events

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    //* Modifiers

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert DSCEngine__NeedsMoreThanZero();
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    //* Constructor

    /**
     * @notice Initializes the DSCEngine with collateral tokens and their price feeds
     * @dev Maps each collateral token to its corresponding Chainlink price feed and stores a
     * reference to the DSC token
     *
     * @param tokenAddresses Array of ERC20 token addresses to be accepted as collateral
     * (e.g., WETH, WBTC)
     *
     * @param priceFeedAddresses Array of Chainlink price feed addresses corresponding to each
     * collateral token (e.g., ETH/USD, BTC/USD)
     *
     * @param dscAddress Address of the already-deployed DecentralizedStableCoin contract that
     * this engine will control
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // Checks if both lengths match, the one of token addresses and its respective price feed
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAdressessMustBeSameLength();
        }

        // Fills the mapping with each contract address and its price feed address and adds the contract
        // address to the array
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        // Sets the stable coin contract instance
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //* Public functions

    /**
     * @notice Returns the total value in USD of the underying assets of the user deposited as collateral
     * @dev Loops through s_collateralTokens, s_collateralDeposited and using price feed retrieves the value
     * @param user The user address to get the total value of collateral in USD
     */
    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalColateralValueInUsd;

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address collateralToken = s_collateralTokens[i];
            uint256 collateralAmountDeposited = s_collateralDeposited[user][collateralToken];

            totalColateralValueInUsd += getUsdValue(collateralToken, collateralAmountDeposited);
        }

        return totalColateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        // Gets the asset price in USD, 8 decimals precision
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        // Returns the total token value (weird maths for precision here)
        return ((uint256(price) * FEED_PRECISION) * amount) / PRECISION;
    }

    //* External functions

    /**
     * @notice Deposits collateral into the protocol
     * @dev Deposits the collateral and emits an event informing of the deposit
     * @param tokenCollateralAddress The address of the token to deposit as collateral (wETH or wBTC)
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        isAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // Updates the (double) mapping of sender => (token => amount)
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;

        // Emits a collateral deposited event
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        // Makes the transaction of the collateral token from the sender to this contract
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    /**
     * @notice Mints new DSC tokens if user pass the health factor
     * @dev Checks health factor and then mints the DSC tokens using the contract
     * @param amountToMint The amount of tokens to mint, also included in health factor checks
     */
    function mintDsc(uint256 amountToMint) external moreThanZero(amountToMint) nonReentrant {
        // Updates the minted balance mapping
        s_DSCMinted[msg.sender] += amountToMint;

        // Checks the health factor just in case the user wants to mint above the allowed
        _revertIfHealthFactorIsBroken(msg.sender);

        // Calls DSC contract to actually mint the tokens (DSCEngine is the owner)
        bool minted = i_dsc.mint(msg.sender, amountToMint);
        if (!minted) revert DSCEngine__MintFailed();
    }

    //* Internal functions

    /**
     * @dev Checks the user's health factor (if has enough collateral) and reverts if not enough
     * @param user The user address to check the health factor from
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) revert DSCEngine__BreaksHealthFactor(healthFactor);
    }

    //* Private functions

    /**
     * @dev Returns how close is to liquidation. If goes below 1.5 they can be liquidated
     * @param user The user address to check the heath factor from
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        uint256 collateralValueAdjusted = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralValueAdjusted * PRECISION) / totalDscMinted;
    }

    /**
     * @dev Returns both, the total DSC minted by the caller and the total value of the assets of that user in USD
     * @param user The address of the user we're going to check the info from
     * @return totalDscMinted Quantity of DSC stablecoin minted ($1 pegged)
     * @return collateralValueInUsd Value in USD of user's collateral
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }
}
