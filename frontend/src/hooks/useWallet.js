// Wallet connection, with network detection and switching.
//
// v1 built a Web3Provider in the body of every component (which blows up when
// no wallet is installed) and never checked which network you were on.

import { useCallback, useEffect, useState } from "react";
import { BrowserProvider } from "ethers";
import { CHAIN_ID, CHAIN_NAME, RPC_URL, EXPLORER_URL } from "../config";

export function useWallet() {
  const [address, setAddress] = useState(null);
  const [signer, setSigner] = useState(null);
  const [chainId, setChainId] = useState(null);
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState(null);

  const hasWallet = typeof window !== "undefined" && Boolean(window.ethereum);

  const refresh = useCallback(async () => {
    if (!window.ethereum) return;
    try {
      const provider = new BrowserProvider(window.ethereum);
      const accounts = await provider.send("eth_accounts", []);
      const network = await provider.getNetwork();
      setChainId(Number(network.chainId));

      if (accounts.length === 0) {
        setAddress(null);
        setSigner(null);
        return;
      }
      const nextSigner = await provider.getSigner();
      setSigner(nextSigner);
      setAddress(await nextSigner.getAddress());
    } catch (e) {
      setError(e.shortMessage ?? e.message);
    }
  }, []);

  const connect = useCallback(async () => {
    if (!window.ethereum) {
      setError("No wallet detected. Install MetaMask.");
      return;
    }
    setConnecting(true);
    setError(null);
    try {
      const provider = new BrowserProvider(window.ethereum);
      await provider.send("eth_requestAccounts", []);
      await refresh();
    } catch (e) {
      setError(e.shortMessage ?? e.message ?? "Could not connect.");
    } finally {
      setConnecting(false);
    }
  }, [refresh]);

  const switchNetwork = useCallback(async () => {
    if (!window.ethereum) return;
    const hexChainId = `0x${CHAIN_ID.toString(16)}`;
    try {
      await window.ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: hexChainId }],
      });
    } catch (e) {
      // 4902 = the network is not registered in the wallet.
      if (e.code === 4902) {
        await window.ethereum.request({
          method: "wallet_addEthereumChain",
          params: [
            {
              chainId: hexChainId,
              chainName: CHAIN_NAME,
              rpcUrls: [RPC_URL],
              blockExplorerUrls: [EXPLORER_URL],
              nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
            },
          ],
        });
      } else {
        setError(e.shortMessage ?? e.message);
      }
    }
  }, []);

  useEffect(() => {
    if (!window.ethereum) return undefined;

    refresh();

    const onAccountsChanged = () => refresh();
    // Switching networks invalidates cached providers and contracts; reloading
    // is what MetaMask recommends and avoids half-updated state.
    const onChainChanged = () => window.location.reload();

    window.ethereum.on("accountsChanged", onAccountsChanged);
    window.ethereum.on("chainChanged", onChainChanged);
    return () => {
      window.ethereum.removeListener("accountsChanged", onAccountsChanged);
      window.ethereum.removeListener("chainChanged", onChainChanged);
    };
  }, [refresh]);

  return {
    hasWallet,
    address,
    signer,
    chainId,
    wrongNetwork: chainId !== null && chainId !== CHAIN_ID,
    connecting,
    error,
    connect,
    switchNetwork,
  };
}
