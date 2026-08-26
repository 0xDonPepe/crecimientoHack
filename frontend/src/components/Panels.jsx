// The dApp's panels. Every input goes through parseUnits before it reaches the
// contract: in v1 the raw input text was sent as-is, so typing "100" approved
// 100 wei.

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
      <h2>Your position {loading && <span className="spinner" />}</h2>

      <div className="grid">
        <Stat label="Collateral deposited" value={`${fmt(data.collateral)} MGOV`} />
        <Stat label="Collateral value" value={`$${fmt(data.collateralUsd, 2)}`} />
        <Stat label="Debt" value={`${fmt(data.debt)} gUSD`} />
        <Stat label="Current LTV" value={`${ltv.toFixed(1)}%`} />
        <Stat
          label="Health factor"
          value={fmtHealth(data.health, data.debt)}
          className={healthClass(data.health, data.debt)}
        />
        <Stat label="Collateral price" value={`$${fmt(data.price, 4)}`} />
      </div>

      <div className="grid">
        <Stat label="MGOV in your wallet" value={fmt(data.walletCollateral)} />
        <Stat label="gUSD in your wallet" value={fmt(data.walletStable)} />
        <Stat label="Still mintable" value={`${fmt(data.maxMintable)} gUSD`} />
      </div>

      {data.account && (
        <p className="muted">
          Your delegation account:{" "}
          <a href={explorerAddress(data.account)} target="_blank" rel="noreferrer">
            {data.account}
          </a>
          <br />
          Your collateral votes through:{" "}
          <strong>{data.delegatee ?? "nobody"}</strong>
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
      <h2>Deposit and mint</h2>
      <p className="muted">
        Your collateral is held in your own delegation account, not in the
        vault, so it keeps voting while it is deposited.
      </p>

      <label>
        Collateral to deposit (MGOV)
        <input
          value={collateralText}
          onChange={(e) => setCollateralText(e.target.value)}
          placeholder="100"
          inputMode="decimal"
        />
      </label>

      <label>
        gUSD to mint (optional)
        <input
          value={mintText}
          onChange={(e) => setMintText(e.target.value)}
          placeholder="30"
          inputMode="decimal"
        />
      </label>

      {collateralText && collateralAmount === null && (
        <p className="error-inline">Invalid collateral amount.</p>
      )}

      <div className="row">
        {needsApproval ? (
          <button disabled={busy} onClick={actions.approveCollateral}>
            {pending === "Approve collateral" ? "Approving..." : "1. Approve MGOV"}
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
            {busy ? "Sending..." : mintAmount ? "Deposit and mint" : "Deposit"}
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
      <h2>Repay and withdraw</h2>
      <p className="muted">
        v1 had no exit at all: collateral went in and never came back out.
      </p>

      <label>
        gUSD to repay
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
            {pending === "Approve gUSD" ? "Approving..." : "Approve gUSD"}
          </button>
        ) : (
          <>
            <button
              disabled={busy || repayAmount === null}
              onClick={() => actions.repay(repayAmount)}
            >
              Repay
            </button>
            <button
              className="secondary"
              disabled={busy || data.debt === 0n}
              onClick={actions.repayAll}
            >
              Repay all
            </button>
          </>
        )}
      </div>

      <label>
        Collateral to withdraw (MGOV)
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
          Withdraw
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
      <h2>Delegate voting power</h2>
      <p className="muted">
        This is what makes the protocol different: you can move your votes
        without touching your debt or your collateral.
      </p>

      <label>
        Delegatee address
        <input
          value={delegatee}
          onChange={(e) => setDelegatee(e.target.value)}
          placeholder="0x..."
          spellCheck={false}
        />
      </label>

      {delegatee && !valid && (
        <p className="error-inline">That is not a valid address.</p>
      )}

      <div className="row">
        <button
          disabled={busy || !valid || !data.account}
          onClick={() => actions.delegate(delegatee)}
        >
          {pending === "Delegate votes" ? "Delegating..." : "Delegate"}
        </button>
        <button
          className="secondary"
          disabled={busy || !data.account}
          onClick={() => actions.delegate(address)}
        >
          Take my votes back
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
      <h2>Liquidate a position</h2>
      <p className="muted">
        When a health factor drops below 1, anyone can cover part of that debt
        and take the collateral at a 10% discount.
      </p>

      <label>
        Borrower address
        <input
          value={user}
          onChange={(e) => setUser(e.target.value)}
          placeholder="0x..."
          spellCheck={false}
        />
      </label>

      <label>
        gUSD to cover
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
          {pending === "Liquidate" ? "Liquidating..." : "Liquidate"}
        </button>
      </div>
    </section>
  );
}

export function FaucetPanel({ actions, pending }) {
  const busy = Boolean(pending);
  return (
    <section className="card">
      <h2>Test faucet</h2>
      <p className="muted">
        The collateral token is a testnet mock: mint yourself as many as you
        need to try things out.
      </p>
      <div className="row">
        <button
          className="secondary"
          disabled={busy}
          onClick={() => actions.faucet(parseUnits("1000", DECIMALS))}
        >
          Give me 1000 MGOV
        </button>
      </div>
    </section>
  );
}
