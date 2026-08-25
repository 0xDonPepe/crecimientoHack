// Paneles de la dApp. Todos los inputs pasan por parseUnits antes de tocar el
// contrato: en la v1 el texto del input se enviaba tal cual, asi que escribir
// "100" aprobaba 100 wei.

import { useState } from "react";
import { parseUnits, isAddress } from "ethers";
import { DECIMALS, explorerAddress } from "../config";
import { fmt, fmtHealth } from "../hooks/useVault";

function parseAmount(text) {
  if (!text || text.trim() === "") return null;
  try {
    const value = parseUnits(text.trim(), DECIMALS);
    return value > 0n ? value : null;
  } catch {
    return null;
  }
}

function healthClass(health, debt) {
  if (!debt || debt === 0n) return "hf hf-none";
  if (health < 1_000000000000000000n) return "hf hf-danger";
  if (health < 1_300000000000000000n) return "hf hf-warn";
  return "hf hf-ok";
}

export function PositionPanel({ data, loading }) {
  const ltv =
    data.collateralUsd > 0n
      ? (Number(data.debt) / Number(data.collateralUsd)) * 100
      : 0;

  return (
    <section className="card">
      <h2>Tu posicion {loading && <span className="spinner" />}</h2>

      <div className="grid">
        <Stat label="Colateral depositado" value={`${fmt(data.collateral)} MGOV`} />
        <Stat label="Valor del colateral" value={`$${fmt(data.collateralUsd, 2)}`} />
        <Stat label="Deuda" value={`${fmt(data.debt)} gUSD`} />
        <Stat label="LTV actual" value={`${ltv.toFixed(1)}%`} />
        <Stat
          label="Health factor"
          value={fmtHealth(data.health, data.debt)}
          className={healthClass(data.health, data.debt)}
        />
        <Stat label="Precio del colateral" value={`$${fmt(data.price, 4)}`} />
      </div>

      <div className="grid">
        <Stat label="MGOV en tu wallet" value={fmt(data.walletCollateral)} />
        <Stat label="gUSD en tu wallet" value={fmt(data.walletStable)} />
        <Stat label="Todavia puedes emitir" value={`${fmt(data.maxMintable)} gUSD`} />
      </div>

      {data.account && (
        <p className="muted">
          Tu cuenta de delegacion:{" "}
          <a href={explorerAddress(data.account)} target="_blank" rel="noreferrer">
            {data.account}
          </a>
          <br />
          Tu colateral vota a traves de:{" "}
          <strong>{data.delegatee ?? "nadie"}</strong>
        </p>
      )}
    </section>
  );
}

function Stat({ label, value, className }) {
  return (
    <div className="stat">
      <span className="stat-label">{label}</span>
      <span className={className ?? "stat-value"}>{value}</span>
    </div>
  );
}

export function DepositPanel({ data, actions, pending }) {
  const [collateralText, setCollateralText] = useState("");
  const [mintText, setMintText] = useState("");

  const collateralAmount = parseAmount(collateralText);
  const mintAmount = parseAmount(mintText);
  const needsApproval =
    collateralAmount !== null && data.allowance < collateralAmount;
  const busy = Boolean(pending);

  return (
    <section className="card">
      <h2>Depositar y emitir</h2>
      <p className="muted">
        El colateral se guarda en tu propia cuenta de delegacion, no en el vault,
        asi que sigue votando mientras esta depositado.
      </p>

      <label>
        Colateral a depositar (MGOV)
        <input
          value={collateralText}
          onChange={(e) => setCollateralText(e.target.value)}
          placeholder="100"
          inputMode="decimal"
        />
      </label>

      <label>
        gUSD a emitir (opcional)
        <input
          value={mintText}
          onChange={(e) => setMintText(e.target.value)}
          placeholder="30"
          inputMode="decimal"
        />
      </label>

      {collateralText && collateralAmount === null && (
        <p className="error-inline">Cantidad de colateral invalida.</p>
      )}

      <div className="row">
        {needsApproval ? (
          <button disabled={busy} onClick={actions.approveCollateral}>
            {pending === "Aprobar colateral" ? "Aprobando..." : "1. Aprobar MGOV"}
          </button>
        ) : (
          <button
            disabled={busy || collateralAmount === null}
            onClick={() =>
              mintAmount
                ? actions.depositAndMint(collateralAmount, mintAmount)
                : actions.deposit(collateralAmount)
            }
          >
            {busy ? "Enviando..." : mintAmount ? "Depositar y emitir" : "Depositar"}
          </button>
        )}
      </div>
    </section>
  );
}

export function RepayPanel({ data, actions, pending }) {
  const [repayText, setRepayText] = useState("");
  const [withdrawText, setWithdrawText] = useState("");

  const repayAmount = parseAmount(repayText);
  const withdrawAmount = parseAmount(withdrawText);
  const needsApproval = repayAmount !== null && data.stableAllowance < repayAmount;
  const busy = Boolean(pending);

  return (
    <section className="card">
      <h2>Repagar y retirar</h2>
      <p className="muted">
        La v1 no tenia salida: el colateral entraba y no volvia a salir nunca.
      </p>

      <label>
        gUSD a repagar
        <input
          value={repayText}
          onChange={(e) => setRepayText(e.target.value)}
          placeholder="30"
          inputMode="decimal"
        />
      </label>

      <div className="row">
        {needsApproval ? (
          <button disabled={busy} onClick={actions.approveStable}>
            {pending === "Aprobar gUSD" ? "Aprobando..." : "Aprobar gUSD"}
          </button>
        ) : (
          <>
            <button
              disabled={busy || repayAmount === null}
              onClick={() => actions.repay(repayAmount)}
            >
              Repagar
            </button>
            <button
              className="secondary"
              disabled={busy || data.debt === 0n}
              onClick={actions.repayAll}
            >
              Repagar todo
            </button>
          </>
        )}
      </div>

      <label>
        Colateral a retirar (MGOV)
        <input
          value={withdrawText}
          onChange={(e) => setWithdrawText(e.target.value)}
          placeholder="100"
          inputMode="decimal"
        />
      </label>

      <div className="row">
        <button
          disabled={busy || withdrawAmount === null}
          onClick={() => actions.withdraw(withdrawAmount)}
        >
          Retirar
        </button>
      </div>
    </section>
  );
}

export function DelegatePanel({ data, actions, pending, address }) {
  const [delegatee, setDelegatee] = useState("");
  const valid = isAddress(delegatee);
  const busy = Boolean(pending);

  return (
    <section className="card">
      <h2>Delegar poder de voto</h2>
      <p className="muted">
        Esto es lo que el protocolo hace distinto: puedes mover tu voto sin
        tocar tu deuda ni tu colateral.
      </p>

      <label>
        Direccion del delegatee
        <input
          value={delegatee}
          onChange={(e) => setDelegatee(e.target.value)}
          placeholder="0x..."
          spellCheck={false}
        />
      </label>

      {delegatee && !valid && (
        <p className="error-inline">Esa no es una direccion valida.</p>
      )}

      <div className="row">
        <button
          disabled={busy || !valid || !data.account}
          onClick={() => actions.delegate(delegatee)}
        >
          {pending === "Delegar voto" ? "Delegando..." : "Delegar"}
        </button>
        <button
          className="secondary"
          disabled={busy || !data.account}
          onClick={() => actions.delegate(address)}
        >
          Recuperar mi voto
        </button>
      </div>
    </section>
  );
}

export function LiquidatePanel({ actions, pending }) {
  const [user, setUser] = useState("");
  const [amountText, setAmountText] = useState("");

  const amount = parseAmount(amountText);
  const valid = isAddress(user);
  const busy = Boolean(pending);

  return (
    <section className="card">
      <h2>Liquidar una posicion</h2>
      <p className="muted">
        Si un health factor cae por debajo de 1, cualquiera puede cubrir parte
        de esa deuda y llevarse el colateral con un 10% de descuento.
      </p>

      <label>
        Direccion del deudor
        <input
          value={user}
          onChange={(e) => setUser(e.target.value)}
          placeholder="0x..."
          spellCheck={false}
        />
      </label>

      <label>
        gUSD a cubrir
        <input
          value={amountText}
          onChange={(e) => setAmountText(e.target.value)}
          placeholder="15"
          inputMode="decimal"
        />
      </label>

      <div className="row">
        <button
          disabled={busy || !valid || amount === null}
          onClick={() => actions.liquidate(user, amount)}
        >
          {pending === "Liquidar" ? "Liquidando..." : "Liquidar"}
        </button>
      </div>
    </section>
  );
}

export function FaucetPanel({ actions, pending }) {
  const busy = Boolean(pending);
  return (
    <section className="card">
      <h2>Faucet de prueba</h2>
      <p className="muted">
        El token de colateral es un mock de testnet: puedes acunarte los que
        quieras para probar.
      </p>
      <div className="row">
        <button
          className="secondary"
          disabled={busy}
          onClick={() => actions.faucet(parseUnits("1000", DECIMALS))}
        >
          Darme 1000 MGOV
        </button>
      </div>
    </section>
  );
}
