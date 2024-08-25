import { useState } from "react";

import { ethers } from "ethers";

function CollateralVotingVault(props)
{
    let userAddress = props.addressData;  
    let signer = props.signerData;

    let smartContractAddress = "0xc009EDe4e4406d702F8B9F8357b6b4EE7b5Ee0e4";

    let smartContractAbi = [
      {
        "inputs": [],
        "stateMutability": "nonpayable",
        "type": "constructor"
      },
      {
        "inputs": [
          {
            "internalType": "address",
            "name": "paramUserAddress",
            "type": "address"
          }
        ],
        "name": "createUserDelegationAccount",
        "outputs": [
          {
            "internalType": "address",
            "name": "",
            "type": "address"
          }
        ],
        "stateMutability": "nonpayable",
        "type": "function"
      },
      {
        "inputs": [
          {
            "internalType": "address",
            "name": "paramDelegateeAddress",
            "type": "address"
          }
        ],
        "name": "delegateLockedGovernanceTokens",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
      },
      {
        "inputs": [
          {
            "internalType": "address",
            "name": "",
            "type": "address"
          }
        ],
        "name": "delegationAccountExists",
        "outputs": [
          {
            "internalType": "bool",
            "name": "",
            "type": "bool"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [
          {
            "internalType": "uint256",
            "name": "paramAmountToUse",
            "type": "uint256"
          }
        ],
        "name": "depositAndMintStablecoin",
        "outputs": [
          {
            "internalType": "uint256",
            "name": "",
            "type": "uint256"
          }
        ],
        "stateMutability": "nonpayable",
        "type": "function"
      },
      {
        "inputs": [],
        "name": "getArbPrice",
        "outputs": [
          {
            "internalType": "int256",
            "name": "",
            "type": "int256"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [],
        "name": "getArbStablecoinAddress",
        "outputs": [
          {
            "internalType": "address",
            "name": "",
            "type": "address"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [
          {
            "internalType": "address",
            "name": "",
            "type": "address"
          }
        ],
        "name": "userArbCollateralUsed",
        "outputs": [
          {
            "internalType": "uint256",
            "name": "",
            "type": "uint256"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [
          {
            "internalType": "address",
            "name": "",
            "type": "address"
          }
        ],
        "name": "userDelegationAccount",
        "outputs": [
          {
            "internalType": "address",
            "name": "",
            "type": "address"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [
          {
            "internalType": "address",
            "name": "",
            "type": "address"
          }
        ],
        "name": "userLockedTokens",
        "outputs": [
          {
            "internalType": "uint256",
            "name": "",
            "type": "uint256"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      },
      {
        "inputs": [
          {
            "internalType": "address",
            "name": "",
            "type": "address"
          }
        ],
        "name": "userMintedArbStablecoin",
        "outputs": [
          {
            "internalType": "uint256",
            "name": "",
            "type": "uint256"
          }
        ],
        "stateMutability": "view",
        "type": "function"
      }
    ];
    
    let provider = new ethers.providers.Web3Provider(window.ethereum);
    
    let smartContractInstance = new ethers.Contract(smartContractAddress, smartContractAbi, provider);



    const [mintInput, setMintInput] = useState(0);
    const [delegateInput, setDelegateInput] = useState(0);

    async function depositAndMint()
    {
      const tx = await smartContractInstance.connect(signer).depositAndMintStablecoin(mintInput);
      const txReceipt = await tx.wait();
      window.location.reload(false);
    }

    async function delegate()
    {
      const tx = await smartContractInstance.connect(signer).delegateLockedGovernanceTokens(delegateInput);
      const txReceipt = await tx.wait();
      window.location.reload(false);
    }


  

    return(
        <div>
          <div>
            <h3>Deposit governanceToken and mint stablecoin:</h3>
            <input type="text" placeholder="governanceTokenToUse" onChange={e => setMintInput(e.target.value)}></input>
            <button onClick={depositAndMint}>depositAndMint</button>
          </div>

          <div>
            <h3>Delegate locked governance tokens:</h3>
            <input type="text" placeholder="delegateeAddress" onChange={e => setDelegateInput(e.target.value)}></input>
            <button onClick={delegate}>delegate</button>
          </div>
        </div>
    );
}

export default CollateralVotingVault;