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
            Emite una stablecoin contra tu token de gobernanza sin renunciar a
            tu voto.
          </p>
        </div>
        {wallet.address ? (
          <span className="pill">
            {wallet.address.slice(0, 6)}...{wallet.address.slice(-4)}
          </span>
        ) : (
          <button onClick={wallet.connect} disabled={wallet.connecting}>
            {wallet.connecting ? "Conectando..." : "Conectar wallet"}
          </button>
        )}
      </header>

      <main>
        {!wallet.hasWallet && (
          <Banner kind="error">
            No se detecto ninguna wallet en el navegador. Instala MetaMask para
            usar la aplicacion.
          </Banner>
        )}

        {!isConfigured() && (
          <Banner kind="error">
            Faltan las direcciones de los contratos. Copia{" "}
            <code>.env.example</code> a <code>.env</code> y rellena{" "}
            <code>VITE_VAULT_ADDRESS</code> y{" "}
            <code>VITE_COLLATERAL_ADDRESS</code>.
          </Banner>
        )}

        {wallet.wrongNetwork && (
          <Banner kind="warn">
            Estas en la red equivocada. Esta dApp corre en {CHAIN_NAME}.{" "}
            <button className="link" onClick={wallet.switchNetwork}>
              Cambiar de red
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
            <h2>Como funciona</h2>
            <ol className="how">
              <li>Depositas tu token de gobernanza como colateral.</li>
              <li>
                El protocolo lo guarda en una cuenta que es solo tuya y la hace
                delegar a quien tu digas, asi que tu voto no se mueve.
              </li>
              <li>Emites gUSD contra ese colateral, hasta el 50% de su valor.</li>
              <li>
                Cuando quieras, repagas y recuperas todo tu colateral. Si el
                precio cae y tu health factor baja de 1, tu posicion se puede
                liquidar.
              </li>
            </ol>
            <p className="muted">Conecta tu wallet para empezar.</p>
          </section>
        )}
      </main>

      <footer>
        <a
          href="https://github.com/0xDonPepe/crecimientoHack"
          target="_blank"
          rel="noreferrer"
        >
          Codigo en GitHub
        </a>
        <span>
          {" · "}
          <a
            href="https://github.com/0xDonPepe/crecimientoHack/tree/v1-hackathon"
            target="_blank"
            rel="noreferrer"
          >
            Ver la v1 del hackathon
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
          cerrar
        </button>
      )}
    </div>
  );
}
