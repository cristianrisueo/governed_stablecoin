// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TestStableCoinEngine} from "../../../src/stablecoin/TestStableCoinEngine.sol";
import {TestStableCoin} from "../../../src/stablecoin/TestStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";

/**
 * @title EngineGovernanceTest
 * @author cristianrisueo
 * @notice Suite de tests unitarios para funciones de gobernanza del Engine
 * @dev Tests que verifican actualizaciones de parámetros gobernables con rate limiting
 */
contract EngineGovernanceTest is Test {
    // Contratos
    TestStableCoinEngine public engine;
    TestStableCoin public tsc;
    ERC20Mock public weth;
    MockV3Aggregator public priceFeed;

    // Direcciones de prueba
    address public owner;
    address public nonOwner;

    // Constantes
    uint8 public constant DECIMALS = 8;
    int256 public constant INITIAL_PRICE = 2000e8;
    uint256 public constant MIN_COOLDOWN = 15 days;

    // Eventos
    event LiquidationThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event LiquidationBonusUpdated(uint256 oldBonus, uint256 newBonus);
    event TargetHealthFactorUpdated(uint256 oldTarget, uint256 newTarget);
    event MintFeeUpdated(uint256 oldFee, uint256 newFee);

    /**
     * @notice Configuración inicial ejecutada antes de cada test
     */
    function setUp() public {
        // Establecer timestamp inicial para evitar underflow en el constructor
        vm.warp(16 days);

        // Setup de direcciones
        owner = makeAddr("owner");
        nonOwner = makeAddr("nonOwner");

        // Deployment de contratos
        weth = new ERC20Mock();
        tsc = new TestStableCoin();
        priceFeed = new MockV3Aggregator(DECIMALS, INITIAL_PRICE);
        engine = new TestStableCoinEngine(address(weth), address(tsc), address(priceFeed), owner);
    }

    // ============================================
    // Tests de updateLiquidationThreshold
    // ============================================

    /**
     * @notice Verifica que updateThreshold actualiza correctamente el valor
     * @dev El threshold debe cambiar al nuevo valor especificado
     */
    function test_UpdateThreshold_UpdatesCorrectly() public {
        // Setup: Nuevo threshold válido (50 -> 52)
        uint256 newThreshold = 52;

        // Acción: Owner actualiza threshold
        vm.prank(owner);
        engine.updateLiquidationThreshold(newThreshold);

        // Verificación: Threshold actualizado
        assertEq(engine.getLiquidationThreshold(), newThreshold);
    }

    /**
     * @notice Verifica que updateThreshold revierte cuando no es el owner
     * @dev Solo el owner (Timelock) puede cambiar parámetros
     */
    function test_UpdateThreshold_RevertsWhen_NotOwner() public {
        // Acción + Verificación: Debe revertir
        vm.prank(nonOwner);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        engine.updateLiquidationThreshold(52);
    }

    /**
     * @notice Verifica que updateThreshold revierte cuando el valor es menor a 20
     * @dev Threshold mínimo = 20 (mayor riesgo, más capital efficient)
     */
    function test_UpdateThreshold_RevertsWhen_BelowMin() public {
        // Acción + Verificación: Threshold < 20 debe revertir
        vm.prank(owner);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__InvalidGovernanceParameter.selector);
        engine.updateLiquidationThreshold(19);
    }

    /**
     * @notice Verifica que updateThreshold revierte cuando el valor es mayor a 80
     * @dev Threshold máximo = 80 (más seguro, menos capital efficient)
     */
    function test_UpdateThreshold_RevertsWhen_AboveMax() public {
        // Acción + Verificación: Threshold > 80 debe revertir
        vm.prank(owner);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__InvalidGovernanceParameter.selector);
        engine.updateLiquidationThreshold(81);
    }

    /**
     * @notice Verifica que updateThreshold revierte cuando el cambio excede ±5
     * @dev MAX_THRESHOLD_CHANGE = 5 (previene cambios drásticos)
     */
    function test_UpdateThreshold_RevertsWhen_ChangeExceedsMax() public {
        // Acción + Verificación: Cambio de 50 -> 56 (+6) debe revertir
        vm.prank(owner);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__ChangeExceedsMaximum.selector);
        engine.updateLiquidationThreshold(56);
    }

    /**
     * @notice Verifica que updateThreshold revierte si no ha pasado el cooldown
     * @dev MIN_CHANGE_COOLDOWN = 15 días entre actualizaciones
     */
    function test_UpdateThreshold_RevertsWhen_CooldownNotElapsed() public {
        // Setup: Primera actualización
        vm.prank(owner);
        engine.updateLiquidationThreshold(52);

        // Acción + Verificación: Intentar actualizar inmediatamente debe revertir
        vm.prank(owner);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__CooldownNotElapsed.selector);
        engine.updateLiquidationThreshold(50);
    }

    /**
     * @notice Verifica que updateThreshold actualiza el timestamp
     * @dev Permite nueva actualización después de 15 días
     */
    function test_UpdateThreshold_UpdatesTimestamp() public {
        // Setup: Primera actualización
        vm.prank(owner);
        engine.updateLiquidationThreshold(52);

        // Avanzar tiempo 15 días
        vm.warp(block.timestamp + MIN_COOLDOWN);

        // Acción: Segunda actualización (debe funcionar)
        vm.prank(owner);
        engine.updateLiquidationThreshold(50);

        // Verificación: Threshold volvió al original
        assertEq(engine.getLiquidationThreshold(), 50);
    }

    // ============================================
    // Tests de updateLiquidationBonus
    // ============================================

    /**
     * @notice Verifica que updateBonus actualiza correctamente el valor
     * @dev El bonus debe cambiar al nuevo valor especificado
     */
    function test_UpdateBonus_UpdatesCorrectly() public {
        // Setup: Nuevo bonus válido (10 -> 12)
        uint256 newBonus = 12;

        // Acción: Owner actualiza bonus
        vm.prank(owner);
        engine.updateLiquidationBonus(newBonus);

        // Verificación: Bonus actualizado
        assertEq(engine.getLiquidationBonus(), newBonus);
    }

    /**
     * @notice Verifica que updateBonus revierte cuando el valor es menor a 5
     * @dev Bonus mínimo = 5% (menos incentivo para liquidadores)
     */
    function test_UpdateBonus_RevertsWhen_BelowMin() public {
        // Acción + Verificación: Bonus < 5 debe revertir
        vm.prank(owner);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__InvalidGovernanceParameter.selector);
        engine.updateLiquidationBonus(4);
    }

    /**
     * @notice Verifica que updateBonus revierte cuando el valor es mayor a 20
     * @dev Bonus máximo = 20% (más incentivo, más costoso para liquidados)
     */
    function test_UpdateBonus_RevertsWhen_AboveMax() public {
        // Acción + Verificación: Bonus > 20 debe revertir
        vm.prank(owner);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__InvalidGovernanceParameter.selector);
        engine.updateLiquidationBonus(21);
    }

    /**
     * @notice Verifica que updateBonus revierte cuando el cambio excede ±2
     * @dev MAX_BONUS_CHANGE = 2 (previene cambios drásticos)
     */
    function test_UpdateBonus_RevertsWhen_ChangeExceedsMax() public {
        // Acción + Verificación: Cambio de 10 -> 13 (+3) debe revertir
        vm.prank(owner);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__ChangeExceedsMaximum.selector);
        engine.updateLiquidationBonus(13);
    }

    /**
     * @notice Verifica que updateBonus revierte si no ha pasado el cooldown
     * @dev MIN_CHANGE_COOLDOWN = 15 días entre actualizaciones
     */
    function test_UpdateBonus_RevertsWhen_CooldownNotElapsed() public {
        // Setup: Primera actualización
        vm.prank(owner);
        engine.updateLiquidationBonus(12);

        // Acción + Verificación: Intentar actualizar inmediatamente debe revertir
        vm.prank(owner);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__CooldownNotElapsed.selector);
        engine.updateLiquidationBonus(10);
    }

    // ============================================
    // Tests de updateTargetHealthFactor
    // ============================================

    /**
     * @notice Verifica que updateTargetHF actualiza correctamente el valor
     * @dev El target HF debe cambiar al nuevo valor especificado
     */
    function test_UpdateTargetHF_UpdatesCorrectly() public {
        // Setup: Nuevo target válido (0.90e18 -> 0.85e18)
        uint256 newTarget = 0.85e18;

        // Acción: Owner actualiza target HF
        vm.prank(owner);
        engine.updateTargetHealthFactor(newTarget);

        // Verificación: Target actualizado
        assertEq(engine.getTargetHealthFactor(), newTarget);
    }

    /**
     * @notice Verifica que updateTargetHF revierte cuando el valor es menor a 0.75e18
     * @dev Target HF mínimo = 0.75 (liquidaciones muy agresivas)
     */
    function test_UpdateTargetHF_RevertsWhen_BelowMin() public {
        // Acción + Verificación: Target < 0.75e18 debe revertir
        vm.prank(owner);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__InvalidGovernanceParameter.selector);
        engine.updateTargetHealthFactor(0.74e18);
    }

    /**
     * @notice Verifica que updateTargetHF revierte cuando el valor es mayor a 1.0e18
     * @dev Target HF máximo = 1.0 (liquidaciones parciales imposibles si mayor)
     */
    function test_UpdateTargetHF_RevertsWhen_AboveMax() public {
        // Acción + Verificación: Target > 1.0e18 debe revertir
        vm.prank(owner);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__InvalidGovernanceParameter.selector);
        engine.updateTargetHealthFactor(1.01e18);
    }

    /**
     * @notice Verifica que updateTargetHF revierte cuando el cambio excede ±0.05e18
     * @dev MAX_TARGET_HF_CHANGE = 0.05e18 (previene cambios drásticos)
     */
    function test_UpdateTargetHF_RevertsWhen_ChangeExceedsMax() public {
        // Acción + Verificación: Cambio de 0.90 -> 0.96 (+0.06) debe revertir
        vm.prank(owner);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__ChangeExceedsMaximum.selector);
        engine.updateTargetHealthFactor(0.96e18);
    }

    // ============================================
    // Tests de updateMintFee
    // ============================================

    /**
     * @notice Verifica que updateMintFee actualiza correctamente el valor
     * @dev La fee debe cambiar al nuevo valor especificado
     */
    function test_UpdateMintFee_UpdatesCorrectly() public {
        // Setup: Nueva fee válida (20 bps -> 25 bps)
        uint256 newFee = 25;

        // Acción: Owner actualiza mint fee
        vm.prank(owner);
        engine.updateMintFee(newFee);

        // Verificación: Fee actualizada
        assertEq(engine.getMintFee(), newFee);
    }

    /**
     * @notice Verifica que updateMintFee revierte cuando el valor es menor a 5 bps
     * @dev Fee mínima = 5 bps = 0.05% (menos seguro, más atractivo)
     */
    function test_UpdateMintFee_RevertsWhen_BelowMin() public {
        // Acción + Verificación: Fee < 5 bps debe revertir
        vm.prank(owner);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__InvalidGovernanceParameter.selector);
        engine.updateMintFee(4);
    }

    /**
     * @notice Verifica que updateMintFee revierte cuando el cambio excede ±5 bps
     * @dev MAX_MINT_FEE_CHANGE = 5 bps (previene cambios drásticos)
     */
    function test_UpdateMintFee_RevertsWhen_ChangeExceedsMax() public {
        // Acción + Verificación: Cambio de 20 -> 26 (+6 bps) debe revertir
        vm.prank(owner);
        vm.expectRevert(TestStableCoinEngine.TestStableCoinEngine__ChangeExceedsMaximum.selector);
        engine.updateMintFee(26);
    }
}
