import logo from './logo.svg';
import './App.css';
import { useState } from 'react';

import { ethers } from 'ethers';

import "./GovernanceTokenComponent";
import GovernanceTokenComponent from './GovernanceTokenComponent';
import CollateralVotingVault from './CollateralVotingVaultComponent';
import StablecoinComponent from './StablecoinComponent';

function App() {
  const [connected, setUserConnected] = useState(false);
  const [address, setAddress] = useState(null);
  const [signer, setSigner] = useState(null);



  let provider = new ethers.providers.Web3Provider(window.ethereum);

  async function requestAccount() 
  {
    if(window.ethereum)
    {
      let accounts = await window.ethereum.request({ method: "eth_requestAccounts", });

      const _signer = await provider.getSigner();
      const _address = accounts[0];

      setAddress(_address);
      setSigner(_signer);
      setUserConnected(true);

      console.log("signer");
      console.log(_signer);
      console.log("address:");
      console.log(_address);


      setUserConnected(true);
    }
    else
    {
      console.log("Metamask isnt installed.");
    }

    console.log("userObject:");
    console.log(signer);
  }

  return (
    <div className="App">
      <header>
        <h1>stableGov hackathonProject</h1>
      </header>

      <body style={{paddingTop: '1rem'}}>
        {
          connected?
          <>
            <div>
              <div>
                <h2>userConnected: {address}</h2>
              </div>

              <div style={{paddingTop: '4rem'}}>
                <GovernanceTokenComponent addressData={address} signerData={signer}/>
              </div>

              <div style={{paddingTop: '4rem'}}>
                <CollateralVotingVault addressData={address} signerData={signer}/>
              </div>

              <div style={{paddingTop: '4rem'}}>
                <StablecoinComponent addressData={address} signerData={signer}/>
              </div>
            </div>
          </>
          :
          <>
            <button onClick={requestAccount}>connect</button>
          </>
        }
      </body>
    </div>
  );
}

export default App;
