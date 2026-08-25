// Traduce los errores de una transaccion a algo que un humano pueda leer.
//
// La v1 no tenia ningun try/catch: cuando una transaccion fallaba, la unica
// senal era que la pagina no se recargaba. Con custom errors de Solidity el
// revert llega como 4 bytes de selector, asi que hay que decodificarlo contra
// el ABI para saber que paso.

import { formatUnits } from "ethers";
import { DECIMALS } from "../config";

const FRIENDLY = {
  ExceedsMaxLtv: (args) =>
    `La operacion dejaria una deuda de ${fmt(args?.[0])} gUSD, por encima del maximo de ${fmt(args?.[1])} gUSD que permite tu colateral.`,
  InsufficientCollateral: () => "No tienes tanto colateral depositado.",
  NoDebt: () => "Esta posicion no tiene deuda que repagar.",
  NoAccount: () => "Todavia no tienes cuenta de delegacion. Deposita primero.",
  PositionHealthy: (args) =>
    `La posicion esta sana (health factor ${fmt(args?.[0])}); no se puede liquidar.`,
  StalePrice: () =>
    "El oraculo de precio esta desactualizado. Intentalo de nuevo en unos minutos.",
  InvalidPrice: () => "El oraculo devolvio un precio invalido.",
  ZeroAmount: () => "La cantidad debe ser mayor que cero.",
  EnforcedPause: () => "El protocolo esta pausado ahora mismo.",
  OnlyVault: () => "Solo el vault puede hacer esa operacion.",
  NotAuthorized: () => "No estas autorizado para esa operacion.",
  AlreadyInitialized: () => "Esa cuenta ya estaba inicializada.",
  ERC20InsufficientAllowance: () =>
    "Falta aprobar el token antes de esta operacion.",
  ERC20InsufficientBalance: () => "Saldo insuficiente para esta operacion.",
  OwnableUnauthorizedAccount: () => "Esa accion es solo para el owner.",
};

function fmt(value) {
  if (value === undefined || value === null) return "?";
  try {
    return Number(formatUnits(value, DECIMALS)).toLocaleString("es-MX", {
      maximumFractionDigits: 4,
    });
  } catch {
    return String(value);
  }
}

/// Busca los datos del revert, que ethers v6 esconde en sitios distintos
/// segun de donde venga (simulacion, wallet, nodo).
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
  if (!error) return "Error desconocido.";

  if (error.code === "ACTION_REJECTED" || error.code === 4001) {
    return "Cancelaste la transaccion en la wallet.";
  }
  if (error.code === "INSUFFICIENT_FUNDS") {
    return "No tienes ETH suficiente para pagar el gas.";
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
        // Ese ABI no conoce el error; se prueba el siguiente.
      }
    }
  }

  // Algunos nodos devuelven el nombre del error en el mensaje de texto.
  for (const name of Object.keys(FRIENDLY)) {
    if (error.shortMessage?.includes(name) || error.message?.includes(name)) {
      return FRIENDLY[name]();
    }
  }

  return error.shortMessage ?? error.message ?? "La transaccion fallo.";
}
