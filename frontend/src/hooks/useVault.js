// Estado del protocolo para el usuario conectado.
//
// La v1 llamaba a getData() en el cuerpo del render, asi que cada render
// disparaba llamadas RPC que provocaban otro render: un bucle infinito. Aqui
// la carga vive en un useEffect con dependencias explicitas y se refresca a
// mano tras cada transaccion.

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

      // positionOf agrupa lo que antes eran seis llamadas sueltas.
      const [position, walletCollateral, walletStable, allowance, stableAllowance] =
        await Promise.all([
          vault.positionOf(address),
          collateral.balanceOf(address),
          stable.balanceOf(address),
          collateral.allowance(address, VAULT_ADDRESS),
          stable.allowance(address, VAULT_ADDRESS),
        ]);

      // Estas dos dependen del oraculo y pueden revertir si el feed esta
      // rancio. La posicion basica debe seguir viendose igualmente.
      let maxMintable = 0n;
      let price = 0n;
      try {
        [maxMintable, price] = await Promise.all([
          vault.maxMintable(address),
          vault.getPrice(),
        ]);
      } catch {
        setNotice(
          "El oraculo de precio no responde; deposito y emision estaran bloqueados hasta que se actualice.",
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

  /// Envuelve una transaccion: estado de pendiente, espera de confirmacion,
  /// error legible y recarga. La v1 hacia window.location.reload() a ciegas.
  const run = useCallback(
    async (label, fn) => {
      setPending(label);
      setError(null);
      setNotice(null);
      try {
        const tx = await fn();
        await tx.wait();
        setNotice(`${label}: confirmado.`);
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
        run("Aprobar colateral", () =>
          collateral.approve(VAULT_ADDRESS, MaxUint256),
        ),
      approveStable: async () => {
        const stable = new Contract(
          await vault.stablecoin(),
          govStablecoinAbi,
          signer,
        );
        return run("Aprobar gUSD", () =>
          stable.approve(VAULT_ADDRESS, MaxUint256),
        );
      },
      deposit: (amount) => run("Depositar", () => vault.deposit(amount)),
      mint: (amount) => run("Emitir gUSD", () => vault.mint(amount)),
      depositAndMint: (c, m) =>
        run("Depositar y emitir", () => vault.depositAndMint(c, m)),
      repay: (amount) => run("Repagar", () => vault.repay(amount)),
      repayAll: () => run("Repagar todo", () => vault.repay(MaxUint256)),
      withdraw: (amount) => run("Retirar", () => vault.withdraw(amount)),
      delegate: (to) => run("Delegar voto", () => vault.delegate(to)),
      openAccount: () => run("Abrir cuenta", () => vault.openAccount()),
      liquidate: (user, amount) =>
        run("Liquidar", () => vault.liquidate(user, amount)),
      faucet: (amount) =>
        run("Pedir tokens de prueba", () => collateral.mint(address, amount)),
    }),
    [run, vault, collateral, signer, address],
  );

  return { data, loading, pending, error, notice, actions, reload: load, setError };
}

/// Formatea un valor de 18 decimales. La v1 mostraba los balances en wei
/// crudo, asi que un saldo de 100 tokens aparecia como 100000000000000000000.
export function fmt(value, digits = 4) {
  if (value === undefined || value === null) return "-";
  try {
    return Number(formatUnits(value, DECIMALS)).toLocaleString("es-MX", {
      maximumFractionDigits: digits,
    });
  } catch {
    return String(value);
  }
}

/// El health factor sin deuda es type(uint256).max; no tiene sentido pintarlo.
export function fmtHealth(health, debt) {
  if (!debt || debt === 0n) return "∞";
  return fmt(health, 2);
}
