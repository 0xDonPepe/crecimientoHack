# Changelog

Everything that changed between the hackathon build and the rewrite.

v1 is still available and untouched:
- Source: [`v1-hackathon`](https://github.com/0xDonPepe/crecimientoHack/tree/v1-hackathon)
- Tag: [`v1.0-hackathon`](https://github.com/0xDonPepe/crecimientoHack/releases/tag/v1.0-hackathon)

---

## [2.0.0] — 2026-08-25

Full rewrite. The original idea is intact; what changed is that it now works,
you can exit a position, and there are tests that prove it.

### Critical bugs fixed

Each one has a regression test in
[`contracts/test/V1Regression.t.sol`](contracts/test/V1Regression.t.sol).

#### 1. Collateral never reached the delegation account

`depositAndMintStablecoin` did `transferFrom(msg.sender, address(this), amount)`,
so the tokens stayed in the shared vault. But the contract calling `delegate()`
was the user's individual account, which had a zero balance.

In `ERC20Votes`, voting power comes from the address that **holds** the tokens,
and only if that address has called `delegate()`. An empty account delegates
zero. The vault didn't self-delegate either, so the voting power of all
deposited collateral simply vanished — meaning the project's central pitch
("use DeFi without losing your vote") never actually happened on-chain.

Collateral now goes straight to the user's account, and that account
self-delegates to its owner the moment it is created.

> `test_Bug1_DepositingDoesNotCostVotingPower` deposits 400 tokens, mints 100
> gUSD, and checks that the user's `getVotes` did not move by a single wei.

#### 2. The stablecoin was minted to an address that couldn't move it

`arbitrumStablecoin.mint(userAccount, ...)` credited the stablecoin to the
delegation account, which had no function to transfer ERC20s. It was stuck there
permanently and the user never saw it — which explains why the frontend's
`StablecoinComponent`, reading `balanceOf(userAddress)`, always showed 0 in the
demo.

It now mints to the user.

#### 3. A 10^18 scaling error in the mint calculation

```solidity
uint arbPrice = uint(getArbPrice()) * (10 ** 10);  // 18 decimals
uint collateralValue = arbPrice * paramAmountToUse; // 18 + 18 = 36 decimals
uint stablecoinToMint = collateralValue / 2;        // minted as if it were 18
```

The division by `1e18` was missing. One token of collateral minted roughly
3·10^17 stablecoins.

Decimal conventions are now fixed and documented in one place, and the price is
always normalized to 18 decimals.

#### 4. Anyone could hijack another user's delegation account

`createUserDelegationAccount(address)` was `public` and accepted any address, so
`userDelegationAccount[victim]` could be overwritten.

Creation is now internal, always operates on `msg.sender`, uses CREATE2 with the
user's address as salt (one account per user, unique and predictable), and the
account cannot be re-initialized.

#### 5. The second deposit erased the first

`userLockedTokens[msg.sender] = paramAmountToUse` assigned instead of
accumulating, while `userArbCollateralUsed` used `+=`. Two mappings measuring the
same thing and drifting apart. There is now a single field, and it accumulates.

#### 6. There was no way out

`returnGovernanceTokens` was written in the delegation account but **never called
by anyone**. There was no repayment, no withdrawal, no burn. Collateral went in
and never came back.

Added `repay`, `repayFor`, `withdraw` and `repayAndWithdraw`.

#### 7. A `returns(uint)` that never returned

`depositAndMintStablecoin` declared a return value and never produced one: always
0, silently.

#### 8. Zero events in the whole system

Nothing indexable, no reactive frontend possible. Every state-changing operation
now emits an event.

#### 9. The stablecoin had no `burn`

Even if repayment had been written, there would have been no way to settle it.

#### 10. Hardcoded price in the zkSync vault

```solidity
uint zkPrice = uint(12773200) * (10 ** 10);
```

Reasonable on a testnet with no feed, but exactly the kind of line that should
not sit unflagged in a public repo. The feed is now injected through the
constructor and there is no price anywhere in the source.

### Security

- **Oracle validation**: rejects prices `<= 0`, answers older than
  `maxPriceAge`, and stuck rounds (`answeredInRound < roundId`). v1 did
  `uint(answer)` directly — on a negative `int` that yields an astronomical
  number you could mint against.
- **SafeERC20** on every transfer; v1 ignored the returned `bool`.
- **ReentrancyGuard** on every function that moves funds.
- **Custom errors** with parameters instead of strings.
- **Checks-Effects-Interactions** throughout.
- Hard caps on risk parameters: max LTV cannot exceed the liquidation threshold,
  and the liquidation bonus is capped at 20%, so not even the owner can
  configure something that confiscates healthy positions.
- **Ownable2Step**, so a fat-fingered ownership transfer cannot orphan the
  contract.
- `pause()` freezes deposits, minting and liquidations but **never** repayment or
  withdrawal: pausing must not be able to hold anyone's collateral hostage.

### New functionality

- **Liquidations** with health factor, threshold, 10% bonus and 50% close
  factor. Insolvent positions can be drained instead of reverting.
- **Live delegation**: the delegatee can be changed with debt outstanding,
  without touching the position.
- **`repayFor`**: a third party can rescue someone else's position.
- **`positionOf`**: the whole position in a single call.
- **`predictAccountAddress`**: the account address is knowable before creation.
- Testnet faucet on the mock.

### Architecture

- **One contract instead of two copies.** v1 had `lockedArbCollateralVotingVault`
  and `lockedZkCollateralVotingVault`, identical apart from renames — and they
  had already begun to drift (the zk one had a hardcoded price, the arb one did
  not). The token and feed are now injected through the constructor.
- **Delegation accounts as EIP-1167 clones**, instead of deploying a full
  contract per user.
- **Governance mocks go from 1,897 lines to 26.** They were OpenZeppelin v4
  flattened by hand inside a repo whose `package.json` declared v5.
- Addresses and parameters out of the bytecode; `immutable` where appropriate.
- Standard Solidity naming conventions (PascalCase).
- **Hardhat → Foundry.**

### Tests

From 0 to **83 tests**, all passing:

| File | Tests | Coverage |
|---|---|---|
| `V1Regression.t.sol` | 17 | One test per v1 bug |
| `Vault.t.sol` | 34 | Deposit, mint, repay, withdraw, delegation, admin, pause |
| `Liquidation.t.sol` | 13 | Liquidations, bonus, close factor, insolvency |
| `Oracle.t.sol` | 13 | Stale prices, negative prices, stuck rounds, decimals |
| `Invariant.t.sol` | 6 | Accounting invariants over 16,384 calls each |

Includes fuzzing (1,024 runs by default, 10,000 in CI) and an invariant suite
with a handler.

**One fuzzer finding is documented in the code**: liquidating only improves the
health factor while the collateral still covers the debt plus the bonus, i.e.
while `HF > threshold × (1 + bonus)` = 0.825. Below that boundary each
liquidation extracts more value than it cancels and the position sinks further.
This is not a flaw — Aave and Compound behave the same way — but it is a limit
worth knowing when choosing the bonus, so it is derived and tested explicitly in
`Liquidation.t.sol`.

### Frontend

Rewritten from scratch.

- **ethers v5 → v6.**
- **Create React App → Vite.**
- **No more infinite RPC loop**: v1 called `getData()` in the render body, so
  every render fired calls that triggered another render. Loading now lives in a
  `useEffect` with explicit dependencies.
- **Unit handling**: there wasn't a single `parseUnits` in all of v1, so typing
  "100" approved 100 wei and balances were displayed in raw wei.
- **ABIs generated from the artifacts** by `contracts/export-abis.sh`, instead of
  ~1,400 hand-pasted lines (out of the 1,700 in `src/`).
- **Readable errors**: Solidity custom errors are decoded against the ABI and
  translated into plain English. v1 had no `try/catch` at all.
- **Network detection** with a switch button.
- Loading and pending-transaction states instead of `window.location.reload()`
  after every tx.
- Position panel with LTV, color-coded health factor and current delegatee.
- The `<body>` nested inside JSX is gone.

### Repo

- **`hardhat.config.js` didn't exist**: the repo would not compile when cloned.
- Added `.gitignore` (v1 had none: `cache/` and React's `build/` were both
  committed), `LICENSE` (MIT) and GitHub Actions CI running fmt, build, lint and
  tests.
- Removed the Hardhat boilerplate (`Lock.js` in `test/` and in `ignition/`).
- Removed the two `readMe` files whose entire contents were `.`
- README with real architecture, instructions and parameters.

---

## [1.0.0] — 2024-08-25

The Crecimiento hackathon build, written over a weekend.
See [`v1-hackathon`](https://github.com/0xDonPepe/crecimientoHack/tree/v1-hackathon).
