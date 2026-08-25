// Configuracion de red y direcciones, leida del entorno.
// En la v1 cada componente traia su propia direccion cableada en el codigo,
// asi que cambiar de red significaba editar y recompilar el frontend.

export const CHAIN_ID = Number(import.meta.env.VITE_CHAIN_ID ?? 421614);
export const CHAIN_NAME = import.meta.env.VITE_CHAIN_NAME ?? "Arbitrum Sepolia";
export const RPC_URL =
  import.meta.env.VITE_RPC_URL ?? "https://sepolia-rollup.arbitrum.io/rpc";
export const EXPLORER_URL =
  import.meta.env.VITE_EXPLORER_URL ?? "https://sepolia.arbiscan.io";

export const VAULT_ADDRESS = import.meta.env.VITE_VAULT_ADDRESS ?? "";
export const COLLATERAL_ADDRESS = import.meta.env.VITE_COLLATERAL_ADDRESS ?? "";

export const DECIMALS = 18;

export function isConfigured() {
  const placeholder = "0x0000000000000000000000000000000000000000";
  return (
    VAULT_ADDRESS.length === 42 &&
    VAULT_ADDRESS !== placeholder &&
    COLLATERAL_ADDRESS.length === 42 &&
    COLLATERAL_ADDRESS !== placeholder
  );
}

export function explorerAddress(address) {
  return `${EXPLORER_URL}/address/${address}`;
}
