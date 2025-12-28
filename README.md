# TSC - Test Stablecoin Protocol

Protocolo de stablecoin algorítmica overcollateralizada con gobernanza on-chain. Similar a MakerDAO/DAI.

## Arquitectura del Sistema

```
┌─────────────────────────────────────────────────────────────────┐
│                      GOBERNANZA (DAO)                           │
│  ┌──────────────────┐    ┌─────────────┐    ┌───────────────┐  │
│  │ TSCGovernanceToken│───▶│ TSCGovernor │───▶│  TSCTimeLock  │  │
│  │   (Voting Power)  │    │ (Votación)  │    │ (Delay 2 días)│  │
│  └──────────────────┘    └─────────────┘    └───────┬───────┘  │
└─────────────────────────────────────────────────────┼──────────┘
                                                      │ owner
                                                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                     PROTOCOLO STABLECOIN                        │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              TestStableCoinEngine                         │  │
│  │  - Depósitos/Retiros de WETH                             │  │
│  │  - Minteo/Burning de TSC                                 │  │
│  │  - Liquidaciones                                          │  │
│  │  - Cálculo de Health Factor                              │  │
│  └──────────────────────┬───────────────────────────────────┘  │
│                         │ owner                                 │
│                         ▼                                       │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              TestStableCoin (ERC20)                       │  │
│  │  - Solo el Engine puede mint/burn                        │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Chainlink Oracle (ETH/USD) + OracleLib (protección 3h stale)  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Flujo de Minteo (Acuñar TSC)

```
Usuario quiere acuñar 100 TSC

1. depositCollateralAndMintTsc(wethAmount, tscAmount)
   │
   ├─▶ depositCollateral(wethAmount)
   │   └─ Transfiere WETH del usuario al Engine
   │   └─ s_collateralDeposited[user] += wethAmount
   │
   └─▶ mintTsc(tscAmount)
       └─ Verifica Health Factor >= 1.0
       └─ s_stablecoinMinted[user] += tscAmount
       └─ TestStableCoin.mint(user, tscAmount)
       └─ Usuario recibe TSC
```

**Requisito:** Ratio de colateralización mínimo 200% (por defecto)
- Para acuñar $100 TSC → necesitas $200 en WETH

---

## Flujo de Burning (Quemar TSC)

```
Usuario quiere recuperar su WETH

1. redeemCollateralForTsc(wethAmount, tscAmount)
   │
   ├─▶ burnTsc(tscAmount)
   │   └─ Usuario envía TSC al Engine
   │   └─ Engine quema el TSC
   │   └─ s_stablecoinMinted[user] -= tscAmount
   │
   └─▶ redeemCollateral(wethAmount)
       └─ Verifica Health Factor >= 1.0 post-retiro
       └─ s_collateralDeposited[user] -= wethAmount
       └─ Transfiere WETH al usuario
```

---

## Health Factor

```
                    Valor Colateral (USD) × Liquidation Threshold
Health Factor = ─────────────────────────────────────────────────
                              Deuda Total (TSC)

Ejemplo:
- Colateral: 1 WETH = $2,000
- Deuda: 800 TSC
- Threshold: 50%

HF = ($2,000 × 0.5) / $800 = $1,000 / $800 = 1.25 ✓ SEGURO

Si ETH baja a $1,500:
HF = ($1,500 × 0.5) / $800 = $750 / $800 = 0.93 ✗ LIQUIDABLE
```

**HF < 1.0** = Posición puede ser liquidada

---

## Flujo de Liquidación

```
Cuando Health Factor < 1.0, cualquiera puede liquidar:

liquidate(userAddress, debtToCover)
│
├─▶ Verificar HF < 1.0 (si no, revert)
│
├─▶ Calcular colateral a recibir
│   └─ colateral = debtToCover + (debtToCover × bonus)
│   └─ Bonus por defecto: 10%
│
├─▶ Liquidador paga deuda (envía TSC)
│   └─ Se quema el TSC
│
└─▶ Liquidador recibe colateral (WETH)
    └─ Obtiene ganancia del 10%
```

**Ejemplo:**
- Usuario: 1 WETH ($1,500), deuda 800 TSC, HF = 0.93
- Liquidador paga: 800 TSC
- Liquidador recibe: ~$880 en WETH (800 + 10% bonus)

---

## Sistema de Gobernanza

### Flujo de una Propuesta

```
1. PROPONER
   └─ Requiere >= 1000 TSCG tokens
   └─ Ejemplo: "Cambiar liquidation threshold a 60%"

2. ESPERAR
   └─ Voting Delay: 1 bloque

3. VOTAR
   └─ Período: ~1 semana (50,400 bloques)
   └─ Opciones: For / Against / Abstain
   └─ Quorum requerido: 5% del supply

4. ENCOLAR (si aprobada)
   └─ Se envía al TimeLock

5. ESPERAR DELAY
   └─ 2 días de seguridad
   └─ Permite a usuarios retirarse si no están de acuerdo

6. EJECUTAR
   └─ Cualquiera puede ejecutar
   └─ TimeLock llama al Engine con los nuevos parámetros
```

### Parámetros Gobernables

| Parámetro | Valor Actual | Rango | Descripción |
|-----------|-------------|-------|-------------|
| Liquidation Threshold | 50 | 20-80 | % de colateral válido como respaldo |
| Liquidation Bonus | 10 | 5-20 | % incentivo para liquidadores |

---

## Estructura de Contratos

```
src/
├── stablecoin/
│   ├── TestStableCoin.sol           # Token ERC20 de la stablecoin
│   ├── TestStableCoinEngine.sol     # Lógica principal del protocolo
│   └── libraries/
│       └── OracleLib.sol            # Protección contra precios obsoletos
│
└── governance/
    ├── TSCGovernanceToken.sol       # Token de votación (ERC20Votes)
    ├── TSCGovernor.sol              # Contrato de votación
    └── TSCTimeLock.sol              # Delay de seguridad (2 días)
```

---

## Direcciones en Sepolia

| Contrato | Dirección |
|----------|-----------|
| WETH | `0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9` |
| ETH/USD Chainlink | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |

---

## Ownership y Permisos

```
TSCGovernanceToken
     │ (vota)
     ▼
TSCGovernor ───▶ TSCTimeLock ───▶ TestStableCoinEngine ───▶ TestStableCoin
                 (owner)          (owner)
```

- **TestStableCoin**: Solo el Engine puede mint/burn
- **TestStableCoinEngine**: Solo el TimeLock puede cambiar parámetros
- **TSCTimeLock**: Solo el Governor puede proponer cambios
- **TSCGovernor**: Holders de TSCGovernanceToken votan

---

## Comandos Útiles

```bash
# Compilar
forge build

# Tests
forge test

# Deploy Stablecoin (paso 1)
forge script script/DeployStablecoin.s.sol --rpc-url sepolia --broadcast

# Deploy DAO (paso 2) - requiere dirección del Engine
forge script script/DeployDAO.s.sol --sig "run(address)" <ENGINE_ADDRESS> --rpc-url sepolia --broadcast
```

### Orden de Deployment

```
1. DeployStablecoin.s.sol
   └─ Despliega: TestStableCoin + TestStableCoinEngine
   └─ Owner del Engine: deployer (temporal)

2. DeployDAO.s.sol (con dirección del Engine)
   └─ Despliega: TSCGovernanceToken + TSCTimelock + TSCGovernor
   └─ Configura roles del Timelock
   └─ Transfiere ownership del Engine al Timelock
```

---

## Seguridad

- **ReentrancyGuard**: Todas las funciones de mutación protegidas contra reentrancy
- **Ownable**: Engine controlado por Timelock (gobernanza descentralizada)
- **OracleLib**: Revierte si precio > 3 horas de antigüedad
- **Health Factor**: Siempre verificado antes de permitir operaciones
- **TimeLock**: 2 días de delay para cambios críticos en parámetros del protocolo
