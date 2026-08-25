# Changelog

Todo lo que cambió entre la versión del hackathon y la reescritura.

La v1 sigue disponible y sin tocar:
- Código: [`v1-hackathon`](https://github.com/0xDonPepe/crecimientoHack/tree/v1-hackathon)
- Tag: [`v1.0-hackathon`](https://github.com/0xDonPepe/crecimientoHack/releases/tag/v1.0-hackathon)

---

## [2.0.0] — 2026-08-25

Reescritura completa. La idea original se conserva intacta; lo que cambia es que
ahora funciona, se puede salir de una posición, y hay tests que lo demuestran.

### Bugs críticos corregidos

Cada uno tiene un test de regresión en
[`contracts/test/V1Regression.t.sol`](contracts/test/V1Regression.t.sol).

#### 1. El colateral nunca llegaba a la cuenta de delegación

`depositAndMintStablecoin` hacía `transferFrom(msg.sender, address(this), amount)`,
así que los tokens se quedaban en el vault común. Pero quien llamaba `delegate()`
era la cuenta individual del usuario, que tenía balance cero.

En `ERC20Votes` el poder de voto lo aporta la dirección que **sostiene** los
tokens, y solo si esa dirección ha llamado `delegate()`. Una cuenta vacía delega
cero. El vault tampoco se auto-delegaba, así que el voto de todo el colateral
depositado simplemente desaparecía — es decir, la propuesta central del proyecto
("participa en DeFi sin perder tu voto") no ocurría on-chain.

Ahora el colateral viaja directo a la cuenta del usuario, y esa cuenta se
auto-delega al dueño en el momento de crearse.

> `test_Bug1_DepositingDoesNotCostVotingPower` deposita 400 tokens, emite 100
> gUSD, y comprueba que `getVotes` del usuario no se movió ni un wei.

#### 2. La stablecoin se emitía a una dirección que no podía moverla

`arbitrumStablecoin.mint(userAccount, ...)` acreditaba la stablecoin a la cuenta
de delegación, que no tenía ninguna función para transferir ERC20. Quedaba
atrapada permanentemente y el usuario nunca la veía — lo cual explica que el
`StablecoinComponent` del frontend, que leía `balanceOf(userAddress)`, siempre
mostrara 0 en la demo.

Ahora se emite al usuario.

#### 3. Error de escala de 10^18 en el cálculo de emisión

```solidity
uint arbPrice = uint(getArbPrice()) * (10 ** 10);  // 18 decimales
uint collateralValue = arbPrice * paramAmountToUse; // 18 + 18 = 36 decimales
uint stablecoinToMint = collateralValue / 2;        // se emite como si fueran 18
```

Faltaba dividir entre `1e18`. Por 1 token de colateral se emitían unos
3·10^17 stablecoins.

Ahora las convenciones de decimales están fijadas y documentadas en un solo
sitio, y el precio se normaliza siempre a 18 decimales.

#### 4. Cualquiera podía secuestrar la cuenta de delegación de otro

`createUserDelegationAccount(address)` era `public` y aceptaba cualquier
dirección, así que se podía sobrescribir `userDelegationAccount[víctima]`.

Ahora la creación es interna, va siempre sobre `msg.sender`, usa CREATE2 con la
dirección del usuario como salt (una cuenta por usuario, predecible y única), y
la cuenta no se puede reinicializar.

#### 5. El segundo depósito borraba el primero

`userLockedTokens[msg.sender] = paramAmountToUse` asignaba en vez de acumular,
mientras que `userArbCollateralUsed` sí usaba `+=`. Dos mappings midiendo lo
mismo y desincronizándose. Ahora hay un solo campo y acumula.

#### 6. No existía forma de salir

`returnGovernanceTokens` estaba escrita en la cuenta de delegación pero **nadie
la llamaba nunca**. No había repago, ni retiro, ni quema. El colateral entraba y
no volvía a salir.

Añadidos `repay`, `repayFor`, `withdraw` y `repayAndWithdraw`.

#### 7. `returns(uint)` que nunca retornaba

`depositAndMintStablecoin` declaraba un valor de retorno y no lo devolvía:
siempre 0, en silencio.

#### 8. Cero eventos en todo el sistema

Nada indexable, ningún frontend reactivo posible. Ahora hay eventos en cada
operación de estado.

#### 9. La stablecoin no tenía `burn`

Aunque se hubiera escrito el repago, no habría habido forma de cerrarlo.

#### 10. Precio hardcodeado en el vault de zkSync

```solidity
uint zkPrice = uint(12773200) * (10 ** 10);
```

Razonable en una testnet sin feed, pero es exactamente la clase de línea que no
debe quedarse en un repo público sin marcar. Ahora el feed se inyecta por
constructor y no hay ningún precio en el código.

### Seguridad

- **Validación del oráculo**: se rechazan precios `<= 0`, respuestas más viejas
  que `maxPriceAge`, y rondas atascadas (`answeredInRound < roundId`). La v1
  hacía `uint(answer)` directamente — sobre un `int` negativo eso da un número
  astronómico contra el que se podía emitir.
- **SafeERC20** en todas las transferencias; la v1 ignoraba el `bool` de retorno.
- **ReentrancyGuard** en todas las funciones que mueven fondos.
- **Custom errors** con parámetros en lugar de strings.
- **Checks-Effects-Interactions** en todo el flujo.
- Cotas duras en los parámetros de riesgo: el LTV máximo no puede superar el
  umbral de liquidación, y el bono de liquidación está limitado al 20%, de forma
  que ni el owner puede configurar algo que confisque posiciones sanas.
- **Ownable2Step** para que una transferencia de propiedad mal escrita no deje
  el contrato sin dueño.
- `pause()` congela depósito, emisión y liquidación, pero **nunca** repago ni
  retiro: pausar no debe poder secuestrar el colateral de nadie.

### Funcionalidad nueva

- **Liquidaciones** con health factor, umbral, bono del 10% y close factor del
  50%. Las posiciones insolventes se pueden vaciar en vez de revertir.
- **Delegación en vivo**: se puede cambiar el delegatee con deuda abierta, sin
  tocar la posición.
- **`repayFor`**: un tercero puede rescatar la posición de otro.
- **`positionOf`**: toda la posición en una sola llamada.
- **`predictAccountAddress`**: la dirección de la cuenta se conoce antes de crearla.
- Faucet de testnet en el mock.

### Arquitectura

- **Un solo contrato en vez de dos copias.** La v1 tenía `lockedArbCollateralVotingVault`
  y `lockedZkCollateralVotingVault` idénticos salvo renombres — y ya habían
  empezado a divergir (el de zk tenía el precio hardcodeado, el de arb no). Ahora
  el token y el feed se inyectan por constructor.
- **Cuentas de delegación como clones EIP-1167**, en vez de desplegar un contrato
  completo por usuario.
- **Los mocks de gobernanza pasan de 1,897 líneas a 26.** Eran OpenZeppelin v4
  aplanado a mano dentro de un repo cuyo `package.json` declaraba v5.
- Direcciones y parámetros fuera del bytecode; `immutable` donde corresponde.
- Convención de nombres estándar de Solidity (PascalCase).
- **Hardhat → Foundry.**

### Tests

De 0 a **83 tests**, todos pasando:

| Archivo | Tests | Qué cubre |
|---|---|---|
| `V1Regression.t.sol` | 17 | Un test por cada bug de la v1 |
| `Vault.t.sol` | 34 | Depósito, emisión, repago, retiro, delegación, admin, pausa |
| `Liquidation.t.sol` | 13 | Liquidaciones, bono, close factor, insolvencia |
| `Oracle.t.sol` | 13 | Precios rancios, negativos, rondas atascadas, decimales |
| `Invariant.t.sol` | 6 | Invariantes contables sobre 16,384 llamadas cada uno |

Incluye fuzzing (1,024 runs por defecto, 10,000 en CI) y una suite de
invariantes con handler.

**Un hallazgo del fuzzer quedó documentado en el código**: liquidar solo mejora
el health factor si el colateral todavía cubre la deuda más el bono, es decir si
`HF > umbral × (1 + bono)` = 0.825. Por debajo de esa frontera cada liquidación
extrae más valor del que cancela y la posición se hunde más. No es un defecto
—Aave y Compound se comportan igual— pero es un límite que conviene conocer al
elegir el bono, así que está derivado y probado explícitamente en
`Liquidation.t.sol`.

### Frontend

Reescrito de cero.

- **ethers v5 → v6.**
- **Create React App → Vite.**
- **Adiós al bucle infinito de RPC**: la v1 llamaba `getData()` en el cuerpo del
  render, así que cada render disparaba llamadas que provocaban otro render. Ahora
  la carga vive en un `useEffect` con dependencias explícitas.
- **Manejo de unidades**: no había un solo `parseUnits` en toda la v1, así que
  escribir "100" aprobaba 100 wei y los balances se mostraban en wei crudo.
- **ABIs generados desde los artifacts** por `contracts/export-abis.sh`, en vez de
  ~1,400 líneas pegadas a mano (de las 1,700 que tenía `src/`).
- **Errores legibles**: los custom errors de Solidity se decodifican contra el ABI
  y se traducen a español. La v1 no tenía ningún `try/catch`.
- **Detección de red** con botón para cambiarla.
- Estados de carga y de transacción pendiente, en vez de `window.location.reload()`
  después de cada tx.
- Panel de posición con LTV, health factor con color y delegatee actual.
- `<body>` anidado dentro del JSX, eliminado.

### Repo

- **`hardhat.config.js` no existía**: el repo no compilaba al clonarlo.
- Añadidos `.gitignore` (la v1 no tenía: `cache/` y el `build/` de React estaban
  commiteados), `LICENSE` (MIT) y CI en GitHub Actions con fmt, build, lint y tests.
- Eliminado el boilerplate de Hardhat (`Lock.js` en `test/` y en `ignition/`).
- Eliminados los dos archivos `readMe` cuyo contenido era `.`
- README con arquitectura, instrucciones y parámetros reales.

---

## [1.0.0] — 2024-08-25

Versión del hackathon Crecimiento, escrita en un fin de semana.
Ver [`v1-hackathon`](https://github.com/0xDonPepe/crecimientoHack/tree/v1-hackathon).
