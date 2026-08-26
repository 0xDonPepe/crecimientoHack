// Turns transaction errors into something a human can read.
//
// v1 had no try/catch anywhere: when a transaction failed, the only signal was
// that the page did not reload. With Solidity custom errors the revert arrives
// as a 4-byte selector, so it has to be decoded against the ABI to know what
// actually happened.

import { formatUnits } from "ethers";
import { DECIMALS } from "../config";

const FRIENDLY = {
  ExceedsMaxLtv: (args) =>
    `This would leave a debt of ${fmt(args?.[0])} gUSD, above the ${fmt(args?.[1])} gUSD ceiling your collateral allows.`,
  InsufficientCollateral: () => "You do not have that much collateral deposited.",
  NoDebt: () => "This position has no debt to repay.",
  NoAccount: () => "You do not have a delegation account yet. Deposit first.",
  PositionHealthy: (args) =>
    `The position is healthy (health factor ${fmt(args?.[0])}); it cannot be liquidated.`,
  StalePrice: () =>
    "The price oracle is out of date. Try again in a few minutes.",
  InvalidPrice: () => "The oracle returned an invalid price.",
  ZeroAmount: () => "The amount must be greater than zero.",
  EnforcedPause: () => "The protocol is paused right now.",
  OnlyVault: () => "Only the vault can perform that operation.",
  NotAuthorized: () => "You are not authorized to do that.",
  AlreadyInitialized: () => "That account was already initialized.",
  ERC20InsufficientAllowance: () =>
    "You need to approve the token before this operation.",
  ERC20InsufficientBalance: () => "Insufficient balance for this operation.",
  OwnableUnauthorizedAccount: () => "That action is owner-only.",
};

function fmt(value) {
  if (value === undefined || value === null) return "?";
  try {
    return Number(formatUnits(value, DECIMALS)).toLocaleString("en-US", {
      maximumFractionDigits: 4,
    });
  } catch {
    return String(value);
  }
}

/// Finds the revert payload, which ethers v6 tucks in different places
/// depending on where it came from (simulation, wallet, node).
function revertData(error) {
  return (
    error?.data ??
    error?.error?.data ??
    error?.info?.error?.data ??
    error?.transaction?.data ??
    null
  );
}

export function describeError(error, interfaces = []) {
  if (!error) return "Unknown error.";

  if (error.code === "ACTION_REJECTED" || error.code === 4001) {
    return "You rejected the transaction in your wallet.";
  }
  if (error.code === "INSUFFICIENT_FUNDS") {
    return "You do not have enough ETH to pay for gas.";
  }

  const data = revertData(error);
  if (data && data !== "0x") {
    for (const iface of interfaces) {
      try {
        const parsed = iface.parseError(data);
        if (parsed) {
          const friendly = FRIENDLY[parsed.name];
          return friendly ? friendly(parsed.args) : `${parsed.name}()`;
        }
      } catch {
        // This ABI does not know that error; try the next one.
      }
    }
  }

  // Some nodes return the error name inside the plain-text message.
  for (const name of Object.keys(FRIENDLY)) {
    if (error.shortMessage?.includes(name) || error.message?.includes(name)) {
      return FRIENDLY[name]();
    }
  }

  return error.shortMessage ?? error.message ?? "The transaction failed.";
}
