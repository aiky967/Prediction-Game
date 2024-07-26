import React, { useState, useEffect } from 'react';
import detectEthereumProvider from '@metamask/detect-provider';
import Web3 from 'web3';

const ConnectWallet = ({ setAccount }) => {
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    const connectWallet = async () => {
      const provider = await detectEthereumProvider();
      if (provider) {
        const web3 = new Web3(provider);
        const accounts = await web3.eth.requestAccounts();
        setAccount(accounts[0]);
        setConnected(true);
      }
    };
    connectWallet();
  }, [setAccount]);

  return (
    <div>
      {connected ? (
        <button>Wallet Connected</button>
      ) : (
        <button onClick={() => window.ethereum.request({ method: 'eth_requestAccounts' })}>
          Connect Wallet
        </button>
      )}
    </div>
  );
};

export default ConnectWallet;



<div class="grid grid-cols-2 gap-4">
    <div>first</div>
    <div>second</div>
</div>