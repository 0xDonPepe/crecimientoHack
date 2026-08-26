# stableGov

Mint a stablecoin against your governance token **without giving up your vote**.

[![CI](https://github.com/0xDonPepe/crecimientoHack/actions/workflows/ci.yml/badge.svg)](https://github.com/0xDonPepe/crecimientoHack/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-83%20passing-brightgreen.svg)](contracts/test)

---

## The problem

If you hold governance tokens (ARB, ZK, UNI…) you have two options and they are
mutually exclusive: use them in DeFi as collateral, or keep them idle so you can
vote. Depositing them into a normal lending protocol means the voting power goes
to the protocol, not to you.

That opportunity cost leaves governance capital sitting still and pushes DAO
participation down.

## The solution

When you deposit, the protocol does **not** put your collateral in a shared
vault. It deploys an account that belongs to you alone, moves your tokens into
it, and has that account delegate to whoever you choose.

This matters because of one detail in `ERC20Votes`: voting power is credited to
the address that **holds** the tokens, and only if that address has called
`delegate()`. A shared vault pools everyone's votes together or loses them
outright; one account per user keeps them separate and attributable.

Against that collateral you mint `gUSD`, up to 50% of its value. Your vote never
moves.

```
                 ┌──────────────────────────┐
   you deposit   │  CollateralVotingVault   │   mints gUSD
  ───────────────┤  · accounting            ├────────────────►  your wallet
                 │  · LTV and liquidations  │
                 │  · price (Chainlink)     │
                 └────────────┬─────────────┘
                              │ clones (EIP-1167)
                              ▼
                 ┌──────────────────────────┐
                 │  DelegationAccount       │   delegates ───►  you, or
                 │  (one per user)          │                   whoever you pick
                 │  custodies YOUR tokens   │
                 └──────────────────────────┘
```

## Repo status

> This project started at the **Crecimiento** hackathon (August 2024), written
> over a single weekend. In August 2026 it was reviewed in depth and rewritten
> from scratch.
>
> The original version is preserved untouched on the
> [`v1-hackathon`](https://github.com/0xDonPepe/crecimientoHack/tree/v1-hackathon)
> branch and the [`v1.0-hackathon`](https://github.com/0xDonPepe/crecimientoHack/releases/tag/v1.0-hackathon)
> tag.
>
> **The [CHANGELOG](CHANGELOG.md) documents the 10 bugs v1 had** — including
> three that kept the idea from working at all — and everything that was added.
> Each bug has its own regression test in
> [`V1Regression.t.sol`](contracts/test/V1Regression.t.sol).

⚠️ **Unaudited.** This is a learning project. Do not use it with real money.

## How it works

| Parameter | Value | What it means |
|---|---|---|
| Max LTV | 50% | The most you can mint against your collateral |
| Liquidation threshold | 75% | Past this, your position can be liquidated |
| Liquidation bonus | 10% | Discount the liquidator receives |
| Close factor | 50% | Most of your debt coverable in one liquidation |
| Max price age | 1 hour | Staler than this and the protocol blocks |

The **health factor** summarizes your position:
`collateral value × 0.75 / debt`. Below `1.0` you are liquidatable. Minting the
maximum leaves you at `1.5`.

### Full cycle

```solidity
token.approve(address(vault), amount);
vault.depositAndMint(100e18, 30e18);   // 100 MGOV → 30 gUSD

vault.delegate(myFavoriteDelegate);    // votes move, debt does not

stablecoin.approve(address(vault), type(uint256).max);
vault.repayAndWithdraw(30e18, 100e18); // you get all your collateral back
```

## Layout

```
contracts/                    Foundry
  src/
    CollateralVotingVault.sol   the CDP: deposit, mint, repay, liquidate
    DelegationAccount.sol       per-user vault that custodies and delegates
    GovStablecoin.sol           ERC20 only the vault can mint and burn
    interfaces/                 IAggregatorV3 (Chainlink)
    mocks/                      governance token and price feed for tests
  test/
    V1Regression.t.sol          one test per v1 bug
    Vault.t.sol                 CDP mechanics
    Liquidation.t.sol           liquidations and fuzzing
    Oracle.t.sol                oracle validation
    Invariant.t.sol             accounting invariants
  script/Deploy.s.sol         deployment parameterized by environment
  export-abis.sh              generates the frontend ABIs

frontend/                     React 18 + Vite + ethers v6
  src/hooks/                    useWallet, useVault
  src/components/Panels.jsx     the dApp's panels
  src/lib/errors.js             decodes custom errors into plain English
  src/abi/                      generated, do not edit by hand
```

## Running it

### Contracts

You need [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
cd contracts
forge install          # installs forge-std and OpenZeppelin v5
forge build
forge test             # 83 tests
forge test -vvv        # with traces
forge coverage
```

### Frontend

```bash
cd frontend
cp .env.example .env   # put your deployed addresses here
npm install
npm run dev
```

### Deploying

On a network with a Chainlink feed for the token:

```bash
cd contracts
export COLLATERAL_TOKEN=0x...
export PRICE_FEED=0x...
export VAULT_OWNER=0x...
forge script script/Deploy.s.sol:Deploy --rpc-url arbitrum --broadcast --verify
```

On a testnet, deploying a mock token and feed as well:

```bash
forge script script/Deploy.s.sol:DeployTestnet --rpc-url arbitrum_sepolia --broadcast
```

Afterwards, regenerate the frontend ABIs:

```bash
./export-abis.sh
```

## Design decisions

**One account per user, not a shared vault.** This is what keeps the votes
yours. It is deployed as an EIP-1167 clone so opening a position stays cheap,
and with CREATE2 so the address can be computed before it exists.

**Pausing does not block the exit.** `pause()` freezes deposits, minting and
liquidations, but `repay` and `withdraw` stay open. A panic button should never
be able to hold anyone's collateral hostage.

**Repaying works with the oracle down.** Only operations that need to value the
position depend on the price. If the feed dies, everyone can still close out.

**Insolvent positions get drained rather than reverting.** Once the collateral
no longer covers even the covered debt plus bonus, the liquidator takes what is
left and the remainder is recognized as bad debt. Without that cap, a bad
position would be impossible to close forever.

**Salvage boundary.** Liquidating only improves the health factor while
`HF > threshold × (1 + bonus)` = 0.825. Below that, each liquidation sinks the
position further. The fuzzer found this; it is derived and tested in
[`Liquidation.t.sol`](contracts/test/Liquidation.t.sol).

## What's missing

Deliberately out of scope, in order of importance:

- **Stability fee.** Debt accrues no interest today, so there is no economic
  pressure to close positions and no revenue for the protocol.
- **Peg mechanism.** `gUSD` is an overcollateralized debt token, not a pegged
  stablecoin. With no direct redemption or stability module, its market price
  can drift from the dollar.
- **Single-feed oracle.** No fallback source, no TWAP.
- **An audit.**
- Partial delegation across several delegatees, and `delegateBySig` support.

## Credits

Built by [0xDonPepe](https://github.com/0xDonPepe) for the Crecimiento hackathon.

- [Original demo video (2024)](https://youtu.be/4a0A2Ecvg9w)
- [v1 source](https://github.com/0xDonPepe/crecimientoHack/tree/v1-hackathon)

## License

[MIT](LICENSE)
