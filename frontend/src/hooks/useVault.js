// Protocol state for the connected user.
//
// v1 called getData() in the render body, so every render fired RPC calls that
// triggered another render: an infinite loop. Here loading lives in a useEffect
// with explicit dependencies and is refreshed by hand after each transaction.

import { useCallback, useEffect, useMemo, useState } from "react";
import { Contract, MaxUint256, formatUnits } from "ethers";

import { collateralVotingVaultAbi } from "../abi/CollateralVotingVault";
import { govStablecoinAbi } from "../abi/GovStablecoin";
import { mockGovernanceTokenAbi } from "../abi/MockGovernanceToken";
import { VAULT_ADDRESS, COLLATERAL_ADDRESS, DECIMALS } from "../config";
import { describeError } from "../lib/errors";

const ZERO = "0x0000000000000000000000000000000000000000";

const EMPTY = {
  account: null,
  collateral: 0n,
  debt: 0n,
  collateralUsd: 0n,
  health: 0n,
  delegatee: null,
  walletCollateral: 0n,
  walletStable: 0n,
  allowance: 0n,
  stableAllowance: 0n,
  maxMintable: 0n,
  price: 0n,
  stableAddress: null,
};

export function useVault(signer, address) {
  const [data, setData] = useState(EMPTY);
  const [loading, setLoading] = useState(false);
  const [pending, setPending] = useState(null);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState(null);

  const vault = useMemo(() => {
    if (!signer || !VAULT_ADDRESS) return null;
    return new Contract(VAULT_ADDRESS, collateralVotingVaultAbi, signer);
  }, [signer]);

  const collateral = useMemo(() => {
    if (!signer || !COLLATERAL_ADDRESS) return null;
    return new Contract(COLLATERAL_ADDRESS, mockGovernanceTokenAbi, signer);
  }, [signer]);

  const interfaces = useMemo(() => {
    const list = [];
    if (vault) list.push(vault.interface);
    if (collateral) list.push(collateral.interface);
    return list;
  }, [vault, collateral]);

  const load = useCallback(async () => {
    if (!vault || !collateral || !address) {
      setData(EMPTY);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const stableAddress = await vault.stablecoin();
      const stable = new Contract(stableAddress, govStablecoinAbi, signer);

      // positionOf collapses what used to be six separate calls.
      const [position, walletCollateral, walletStable, allowance, stableAllowance] =
        await Promise.all([
          vault.positionOf(address),
          collateral.balanceOf(address),
          stable.balanceOf(address),
          collateral.allowance(address, VAULT_ADDRESS),
          stable.allowance(address, VAULT_ADDRESS),
        ]);

      // These two depend on the oracle and can revert if the feed is stale. The
      // basic position must stay visible regardless.
      let maxMintable = 0n;
      let price = 0n;
      try {
        [maxMintable, price] = await Promise.all([
          vault.maxMintable(address),
          vault.getPrice(),
        ]);
      } catch {
        setNotice(
          "The price oracle is not responding; deposits and minting are blocked until it updates.",
        );
      }

      setData({
        account: position[0] === ZERO ? null : position[0],
        collateral: position[1],
        debt: position[2],
        collateralUsd: position[3],
        health: position[4],
        delegatee: position[5] === ZERO ? null : position[5],
        walletCollateral,
        walletStable,
        allowance,
        stableAllowance,
        maxMintable,
        price,
        stableAddress,
      });
    } catch (e) {
      setError(describeError(e, interfaces));
    } finally {
      setLoading(false);
    }
  }, [vault, collateral, address, signer, interfaces]);

  useEffect(() => {
    load();
  }, [load]);

  /// Wraps a transaction: pending state, confirmation wait, readable error and
  /// reload. v1 called window.location.reload() blindly.
  const run = useCallback(
    async (label, fn) => {
      setPending(label);
      setError(null);
      setNotice(null);
      try {
        const tx = await fn();
        await tx.wait();
        setNotice(`${label}: confirmed.`);
        await load();
        return true;
      } catch (e) {
        setError(describeError(e, interfaces));
        return false;
      } finally {
        setPending(null);
      }
    },
    [load, interfaces],
  );

  const actions = useMemo(
    () => ({
      approveCollateral: () =>
        run("Approve collateral", () =>
          collateral.approve(VAULT_ADDRESS, MaxUint256),
        ),
      approveStable: async () => {
        const stable = new Contract(
          await vault.stablecoin(),
          govStablecoinAbi,
          signer,
        );
        return run("Approve gUSD", () =>
          stable.approve(VAULT_ADDRESS, MaxUint256),
        );
      },
      deposit: (amount) => run("Deposit", () => vault.deposit(amount)),
      mint: (amount) => run("Mint gUSD", () => vault.mint(amount)),
      depositAndMint: (c, m) =>
        run("Deposit and mint", () => vault.depositAndMint(c, m)),
      repay: (amount) => run("Repay", () => vault.repay(amount)),
      repayAll: () => run("Repay all", () => vault.repay(MaxUint256)),
      withdraw: (amount) => run("Withdraw", () => vault.withdraw(amount)),
      delegate: (to) => run("Delegate votes", () => vault.delegate(to)),
      openAccount: () => run("Open account", () => vault.openAccount()),
      liquidate: (user, amount) =>
        run("Liquidate", () => vault.liquidate(user, amount)),
      faucet: (amount) =>
        run("Request test tokens", () => collateral.mint(address, amount)),
    }),
    [run, vault, collateral, signer, address],
  );

  return { data, loading, pending, error, notice, actions, reload: load, setError };
}

/// Formats an 18-decimal value. v1 showed balances in raw wei, so a balance of
/// 100 tokens appeared as 100000000000000000000.
export function fmt(value, digits = 4) {
  if (value === undefined || value === null) return "-";
  try {
    return Number(formatUnits(value, DECIMALS)).toLocaleString("en-US", {
      maximumFractionDigits: digits,
    });
  } catch {
    return String(value);
  }
}

/// With no debt the health factor is type(uint256).max; printing that is useless.
export function fmtHealth(health, debt) {
  if (!debt || debt === 0n) return "∞";
  return fmt(health, 2);
}
