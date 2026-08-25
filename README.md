# stableGov

Emite una stablecoin contra tu token de gobernanza **sin renunciar a tu voto**.

[![CI](https://github.com/0xDonPepe/crecimientoHack/actions/workflows/ci.yml/badge.svg)](https://github.com/0xDonPepe/crecimientoHack/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-83%20passing-brightgreen.svg)](contracts/test)

---

## El problema

Si tienes tokens de gobernanza (ARB, ZK, UNI…), tienes dos opciones y son
excluyentes: los usas en DeFi como colateral, o los dejas quietos para votar.
Depositarlos en un protocolo de préstamo normal significa que el poder de voto
se va al protocolo, no a ti.

Ese coste de oportunidad hace que el capital de gobernanza se quede parado y que
la participación en las DAOs baje.

## La solución

Cuando depositas, el protocolo **no** guarda tu colateral en una bóveda común.
Despliega una cuenta que es solo tuya, mete ahí tus tokens, y hace que esa cuenta
delegue a quien tú digas.

Esto importa por un detalle de `ERC20Votes`: el poder de voto lo aporta la
dirección que **sostiene** los tokens, y solo si esa dirección ha llamado
`delegate()`. Una bóveda compartida mezcla el voto de todo el mundo o lo pierde;
una cuenta por usuario lo mantiene separado y atribuible.

Contra ese colateral emites `gUSD`, hasta el 50% de su valor. Tu voto no se mueve.

```
                 ┌──────────────────────────┐
   depositas     │  CollateralVotingVault   │   emite gUSD
  ───────────────┤  · contabilidad          ├────────────────►  tu wallet
                 │  · LTV y liquidaciones   │
                 │  · precio (Chainlink)    │
                 └────────────┬─────────────┘
                              │ clona (EIP-1167)
                              ▼
                 ┌──────────────────────────┐
                 │  DelegationAccount       │   delega ──────►  tú, o quien
                 │  (una por usuario)       │                   tú decidas
                 │  custodia TU colateral   │
                 └──────────────────────────┘
```

## Estado del repo

> Este proyecto nació en el hackathon **Crecimiento** (agosto 2024), escrito en
> un fin de semana. En agosto de 2026 se revisó a fondo y se reescribió por
> completo.
>
> La versión original se conserva intacta en la rama
> [`v1-hackathon`](https://github.com/0xDonPepe/crecimientoHack/tree/v1-hackathon)
> y en el tag [`v1.0-hackathon`](https://github.com/0xDonPepe/crecimientoHack/releases/tag/v1.0-hackathon).
>
> **El [CHANGELOG](CHANGELOG.md) documenta los 10 bugs que tenía la v1** —
> incluidos tres que impedían que la idea funcionara— y todo lo que se añadió.
> Cada bug tiene su test de regresión en
> [`V1Regression.t.sol`](contracts/test/V1Regression.t.sol).

⚠️ **Sin auditar.** Es un proyecto de aprendizaje. No lo uses con dinero real.

## Cómo funciona

| Parámetro | Valor | Qué significa |
|---|---|---|
| LTV máximo | 50% | Lo más que puedes emitir contra tu colateral |
| Umbral de liquidación | 75% | A partir de aquí tu posición es liquidable |
| Bono de liquidación | 10% | Descuento que se lleva quien te liquida |
| Close factor | 50% | Máximo de tu deuda cubrible en una liquidación |
| Antigüedad máx. del precio | 1 hora | Más viejo que esto y el protocolo se bloquea |

El **health factor** resume tu posición: `valor del colateral × 0.75 / deuda`.
Por debajo de `1.0` eres liquidable. Emitir el máximo te deja en `1.5`.

### Ciclo completo

```solidity
token.approve(address(vault), amount);
vault.depositAndMint(100e18, 30e18);   // 100 MGOV → 30 gUSD

vault.delegate(miDelegadoFavorito);    // el voto se mueve, la deuda no

stablecoin.approve(address(vault), type(uint256).max);
vault.repayAndWithdraw(30e18, 100e18); // recuperas todo tu colateral
```

## Estructura

```
contracts/                    Foundry
  src/
    CollateralVotingVault.sol   el CDP: depósito, emisión, repago, liquidación
    DelegationAccount.sol       bóveda por usuario que custodia y delega
    GovStablecoin.sol           ERC20 que solo el vault emite y quema
    interfaces/                 IAggregatorV3 (Chainlink)
    mocks/                      token de gobernanza y feed para pruebas
  test/
    V1Regression.t.sol          un test por cada bug de la v1
    Vault.t.sol                 mecánica del CDP
    Liquidation.t.sol           liquidaciones y fuzzing
    Oracle.t.sol                validación del oráculo
    Invariant.t.sol             invariantes contables
  script/Deploy.s.sol         despliegue parametrizado por entorno
  export-abis.sh              genera los ABIs del frontend

frontend/                     React 18 + Vite + ethers v6
  src/hooks/                    useWallet, useVault
  src/components/Panels.jsx     paneles de la dApp
  src/lib/errors.js             decodifica custom errors a español
  src/abi/                      generados, no editar a mano
```

## Correr el proyecto

### Contratos

Necesitas [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
cd contracts
forge install          # instala forge-std y OpenZeppelin v5
forge build
forge test             # 83 tests
forge test -vvv        # con trazas
forge coverage
```

### Frontend

```bash
cd frontend
cp .env.example .env   # pon aquí las direcciones desplegadas
npm install
npm run dev
```

### Desplegar

En una red con feed de Chainlink del token:

```bash
cd contracts
export COLLATERAL_TOKEN=0x...
export PRICE_FEED=0x...
export VAULT_OWNER=0x...
forge script script/Deploy.s.sol:Deploy --rpc-url arbitrum --broadcast --verify
```

En testnet, desplegando también un token y un feed de prueba:

```bash
forge script script/Deploy.s.sol:DeployTestnet --rpc-url arbitrum_sepolia --broadcast
```

Después, regenera los ABIs del frontend:

```bash
./export-abis.sh
```

## Decisiones de diseño

**Una cuenta por usuario, no una bóveda compartida.** Es lo que permite que el
voto siga siendo tuyo. Se despliega como clon EIP-1167 para que abrir posición
cueste poco gas, y con CREATE2 para que la dirección se pueda calcular antes de
existir.

**Pausar no bloquea la salida.** `pause()` congela depósito, emisión y
liquidación, pero `repay` y `withdraw` siguen abiertos. Un botón de pánico no
debería poder secuestrar el colateral de nadie.

**Repagar funciona con el oráculo caído.** Solo las operaciones que necesitan
valorar la posición dependen del precio. Si el feed muere, todo el mundo puede
seguir cerrando su posición.

**Las posiciones insolventes se vacían en vez de revertir.** Si el colateral ya
no cubre ni la deuda cubierta más el bono, el liquidador se lleva lo que queda y
el resto se reconoce como deuda mala. Sin ese tope, una posición mala quedaría
imposible de cerrar para siempre.

**Frontera de rescate.** Liquidar solo mejora el health factor si
`HF > umbral × (1 + bono)` = 0.825. Por debajo, cada liquidación hunde más la
posición. Lo encontró el fuzzer; está derivado y probado en
[`Liquidation.t.sol`](contracts/test/Liquidation.t.sol).

## Qué falta

Cosas conscientemente fuera de alcance, en orden de importancia:

- **Tasa de estabilidad.** Hoy la deuda no devenga interés, así que no hay
  incentivo económico para cerrar posiciones ni ingresos para el protocolo.
- **Mecanismo de peg.** `gUSD` es un token de deuda sobrecolateralizada, no una
  stablecoin con anclaje. Sin redención directa ni módulo de estabilidad, su
  precio de mercado puede desviarse del dólar.
- **Oráculo de un solo feed.** Sin fuente de respaldo ni TWAP.
- **Auditoría.**
- Delegación parcial a varios delegatees, y soporte de `delegateBySig`.

## Créditos

Hecho por [0xDonPepe](https://github.com/0xDonPepe) para el hackathon Crecimiento.

- [Video de la demo original (2024)](https://youtu.be/4a0A2Ecvg9w)
- [Código de la v1](https://github.com/0xDonPepe/crecimientoHack/tree/v1-hackathon)

## Licencia

[MIT](LICENSE)
