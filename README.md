# TSC - Test Stablecoin Protocol

Protocolo de stablecoin algorítmica overcollateralizada con gobernanza on-chain. Similar a MakerDAO/DAI.

## Arquitectura del Sistema

```
┌─────────────────────────────────────────────────────────────────┐
│                      GOBERNANZA (DAO)                           │
│  ┌──────────────────┐    ┌─────────────┐    ┌───────────────┐  │
│  │ TSCGovernanceToken│───▶│ TSCGovernor │───▶│  TSCTimeLock  │  │
│  │   (Voting Power)  │    │ (Votación)  │    │ (Delay 2 días)│  │
│  └────────┬─────────┘    └─────────────┘    └───────┬───────┘  │
│           │                                         │           │
│           ▼                                         │           │
│  ┌──────────────────┐                               │           │
│  │   TSCGTreasury   │                               │           │
│  │ (55% tokens TSCG)│                               │           │
│  │ Venta controlada │                               │           │
│  └──────────────────┘                               │           │
└─────────────────────────────────────────────────────┼───────────┘
                                                      │ owner
                                                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                     PROTOCOLO STABLECOIN                        │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              TestStableCoinEngine                         │  │
│  │  - Depósitos/Retiros de WETH                             │  │
│  │  - Minteo/Burning de TSC (+ mint fee → Insurance Fund)   │  │
│  │  - Liquidaciones Parciales                                │  │
│  │  - Cálculo de Health Factor                              │  │
│  │  - Insurance Fund (cobertura bad debt)                   │  │
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
       └─ Calcula mint fee (0.2% por defecto)
       └─ s_insuranceFund += feeAmount (en USD)
       └─ s_stablecoinMinted[user] += tscAmount
       └─ TestStableCoin.mint(user, tscAmount)
       └─ Usuario recibe TSC
```

**Requisito:** Ratio de colateralización mínimo 200% (por defecto)
- Para acuñar $100 TSC → necesitas $200 en WETH

**Mint Fee:** 0.2% (20 basis points) se cobra en cada minteo
- Este fee alimenta el Insurance Fund para cubrir bad debt en liquidaciones

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

## Flujo de Liquidación (Parcial)

El sistema implementa **liquidaciones parciales** que calculan exactamente cuánta deuda cubrir para restaurar el Health Factor al **Target Health Factor** (1.25 por defecto).

```
Cuando Health Factor < 1.0, cualquiera puede liquidar:

liquidate(userAddress)
│
├─▶ Verificar HF < 1.0 (si no, revert)
│
├─▶ Calcular deuda a cubrir (_calculateDebtToCover)
│   └─ Calcula la cantidad exacta para restaurar HF al target (1.25)
│   └─ No liquida más de lo necesario
│
├─▶ CASO A: Liquidación Parcial (colateral suficiente)
│   ├─ Calcular colateral a recibir
│   │   └─ colateral = debtToCover + (debtToCover × bonus 10%)
│   ├─ Liquidador paga deuda (envía TSC)
│   │   └─ Se quema el TSC
│   └─ Liquidador recibe colateral (WETH)
│
└─▶ CASO B: Liquidación Total con Insurance (bad debt)
    ├─ Si colateral insuficiente para cubrir deuda + bonus
    ├─ Se liquida todo el colateral del usuario
    ├─ Insurance Fund cubre el déficit al liquidador
    └─ Evento BadDebtTotalLiquidation emitido
```

**Ejemplo Liquidación Parcial:**
- Usuario: 10 WETH ($20,000), deuda $16,000 TSC, HF = 0.625
- Sistema calcula: liquidar $8,000 para restaurar HF a 1.25
- Liquidador paga: 8,000 TSC
- Liquidador recibe: 4 WETH + 0.4 WETH bonus = 4.4 WETH (~$8,800)
- Usuario tras liquidación: 5.6 WETH, $8,000 deuda, HF = 1.25

**Protección Anti-Zombie:** Tras cada liquidación se verifica que el HF final >= Target HF (1.25), evitando posiciones que serían inmediatamente re-liquidables.

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

| Parámetro | Valor Actual | Rango | Cambio Máx/Propuesta | Descripción |
|-----------|-------------|-------|---------------------|-------------|
| Liquidation Threshold | 50 | 20-80 | ±5 | % de colateral válido como respaldo |
| Liquidation Bonus | 10 | 5-20 | ±2 | % incentivo para liquidadores |
| Target Health Factor | 1.25 | 1.1-1.5 | ±0.1 | HF objetivo tras liquidación |
| Mint Fee | 20 bp | 0-100 bp | ±5 bp | Fee que alimenta Insurance Fund |

### Rate Limiting (Protección Anti-Ataques)

Para prevenir ataques de gobernanza y manipulación rápida de parámetros:

```
┌─────────────────────────────────────────────────────────────┐
│                    RATE LIMITING                            │
│                                                             │
│  ⏱️  Cooldown: 15 días entre cambios del mismo parámetro    │
│                                                             │
│  📊 Límites por propuesta:                                  │
│     • Threshold: máximo ±5 puntos                          │
│     • Bonus: máximo ±2 puntos                              │
│     • Target HF: máximo ±0.1                               │
│     • Mint Fee: máximo ±5 basis points                     │
│                                                             │
│  🛡️  Esto evita que una propuesta maliciosa pueda          │
│     cambiar drásticamente los parámetros del protocolo     │
└─────────────────────────────────────────────────────────────┘
```

---

## Treasury (TSCGTreasury)

El Treasury gestiona el 55% del supply de tokens TSCG (550,000 tokens) para distribución controlada a la comunidad.

```
┌─────────────────────────────────────────────────────────────┐
│                      TSCGTreasury                           │
│                                                             │
│  💰 Tokens: 550,000 TSCG (55% del supply inicial)          │
│  💵 Precio: 0.001 WETH por TSCG (gobernable)               │
│                                                             │
│  Flujo de compra:                                           │
│  Usuario ──▶ buyTSCG(amount) ──▶ Envía WETH ──▶ Recibe TSCG│
│                                                             │
│  Funciones (solo Timelock/owner):                           │
│  • updatePrice(): Ajustar precio TSCG                       │
│  • withdrawWETH(): Retirar WETH acumulado                   │
│  • withdrawTSCG(): Gestionar tokens restantes               │
└─────────────────────────────────────────────────────────────┘
```

**Propósito:** Distribución gradual y controlada de tokens de gobernanza, permitiendo que más usuarios participen en la DAO mientras se mantiene estabilidad de precio.

---

## Insurance Fund

Fondo de seguro que protege a liquidadores y al protocolo contra bad debt.

```
┌─────────────────────────────────────────────────────────────┐
│                    INSURANCE FUND                           │
│                                                             │
│  📥 ENTRADA: Mint Fee (0.2%) en cada acuñación de TSC      │
│     └─ Usuario mintea 1000 TSC → 2 TSC van al fondo        │
│                                                             │
│  📤 SALIDA: Cobertura de bad debt en liquidaciones         │
│     └─ Cuando colateral < deuda + bonus                    │
│     └─ Insurance compensa al liquidador                    │
│                                                             │
│  📊 Consulta: getInsuranceFundBalance()                    │
└─────────────────────────────────────────────────────────────┘
```

**Ejemplo Bad Debt:**
- Usuario: 0.5 WETH ($750), deuda $800 TSC, HF < 1.0
- Colateral solo cubre $750, pero deuda es $800 + 10% bonus = $880
- Insurance Fund cubre los $130 faltantes al liquidador

---

## Estructura de Contratos

```
src/
├── stablecoin/
│   ├── TestStableCoin.sol           # Token ERC20 de la stablecoin
│   ├── TestStableCoinEngine.sol     # Lógica principal del protocolo
│   │                                 # (liquidaciones parciales, insurance fund)
│   └── libraries/
│       └── OracleLib.sol            # Protección contra precios obsoletos
│
└── governance/
    ├── TSCGovernanceToken.sol       # Token de votación (ERC20Votes)
    ├── TSCGovernor.sol              # Contrato de votación
    ├── TSCTimeLock.sol              # Delay de seguridad (2 días)
    └── TSCGTreasury.sol             # Treasury con 55% tokens TSCG
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

| Mecanismo | Descripción |
|-----------|-------------|
| **ReentrancyGuard** | Todas las funciones de mutación protegidas contra reentrancy |
| **Ownable** | Engine controlado por Timelock (gobernanza descentralizada) |
| **OracleLib** | Revierte si precio > 3 horas de antigüedad |
| **Health Factor** | Siempre verificado antes de permitir operaciones |
| **Target Health Factor** | Liquidaciones restauran HF a 1.25 (evita posiciones zombie) |
| **TimeLock** | 2 días de delay para cambios críticos en parámetros |
| **Rate Limiting** | 15 días cooldown + límites máximos por propuesta |
| **Insurance Fund** | Cobertura de bad debt para proteger liquidadores |
| **Partial Liquidations** | Liquida solo lo necesario, minimizando pérdidas del usuario |
