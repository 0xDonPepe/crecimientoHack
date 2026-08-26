import { useWallet } from "./hooks/useWallet";
import { useVault } from "./hooks/useVault";
import {
  PositionPanel,
  DepositPanel,
  RepayPanel,
  DelegatePanel,
  LiquidatePanel,
  FaucetPanel,
} from "./components/Panels";
import { CHAIN_NAME, isConfigured } from "./config";

export default function App() {
  const wallet = useWallet();
  const vault = useVault(wallet.signer, wallet.address);

  return (
    <div className="app">
      <header>
        <div>
          <h1>stableGov</h1>
          <p className="tagline">
            Mint a stablecoin against your governance token without giving up
            your vote.
          </p>
        </div>
        {wallet.address ? (
          <span className="pill">
            {wallet.address.slice(0, 6)}...{wallet.address.slice(-4)}
          </span>
        ) : (
          <button onClick={wallet.connect} disabled={wallet.connecting}>
            {wallet.connecting ? "Connecting..." : "Connect wallet"}
          </button>
        )}
      </header>

      <main>
        {!wallet.hasWallet && (
          <Banner kind="error">
            No wallet detected in this browser. Install MetaMask to use the app.
          </Banner>
        )}

        {!isConfigured() && (
          <Banner kind="error">
            Contract addresses are missing. Copy <code>.env.example</code> to{" "}
            <code>.env</code> and fill in <code>VITE_VAULT_ADDRESS</code> and{" "}
            <code>VITE_COLLATERAL_ADDRESS</code>.
          </Banner>
        )}

        {wallet.wrongNetwork && (
          <Banner kind="warn">
            You are on the wrong network. This dApp runs on {CHAIN_NAME}.{" "}
            <button className="link" onClick={wallet.switchNetwork}>
              Switch network
            </button>
          </Banner>
        )}

        {wallet.error && <Banner kind="error">{wallet.error}</Banner>}
        {vault.error && (
          <Banner kind="error" onClose={() => vault.setError(null)}>
            {vault.error}
          </Banner>
        )}
        {vault.notice && <Banner kind="ok">{vault.notice}</Banner>}

        {wallet.address && !wallet.wrongNetwork && isConfigured() ? (
          <>
            <PositionPanel data={vault.data} loading={vault.loading} />
            <div className="columns">
              <DepositPanel
                data={vault.data}
                actions={vault.actions}
                pending={vault.pending}
              />
              <RepayPanel
                data={vault.data}
                actions={vault.actions}
                pending={vault.pending}
              />
              <DelegatePanel
                data={vault.data}
                actions={vault.actions}
                pending={vault.pending}
                address={wallet.address}
              />
              <LiquidatePanel actions={vault.actions} pending={vault.pending} />
            </div>
            <FaucetPanel actions={vault.actions} pending={vault.pending} />
          </>
        ) : (
          <section className="card">
            <h2>How it works</h2>
            <ol className="how">
              <li>You deposit your governance token as collateral.</li>
              <li>
                The protocol keeps it in an account that is yours alone and has
                it delegate to whoever you choose, so your votes never move.
              </li>
              <li>
                You mint gUSD against that collateral, up to 50% of its value.
              </li>
              <li>
                Whenever you want, you repay and get all your collateral back.
                If the price falls and your health factor drops below 1, your
                position can be liquidated.
              </li>
            </ol>
            <p className="muted">Connect your wallet to get started.</p>
          </section>
        )}
      </main>

      <footer>
        <a
          href="https://github.com/0xDonPepe/crecimientoHack"
          target="_blank"
          rel="noreferrer"
        >
          Source on GitHub
        </a>
        <span>
          {" · "}
          <a
            href="https://github.com/0xDonPepe/crecimientoHack/tree/v1-hackathon"
            target="_blank"
            rel="noreferrer"
          >
            See the v1 hackathon build
          </a>
        </span>
      </footer>
    </div>
  );
}

function Banner({ kind, children, onClose }) {
  return (
    <div className={`banner banner-${kind}`}>
      <span>{children}</span>
      {onClose && (
        <button className="link" onClick={onClose}>
          dismiss
        </button>
      )}
    </div>
  );
}
