# SpreadHunter

SpreadHunter catches price gaps for the same token between Base Sepolia and Unichain Sepolia and closes them in about a second. A reactive contract on Reactive Network watches swaps on both chains. When the gap pays for its costs, it trades on both chains at once. No off-chain bot has to watch the pools.

Built for the Reactive Omni Buildathon (track "Every Second Counts").

> Work in progress. Setup, deployed addresses and demo come as each part lands.

## Requirements

- [Foundry](https://getfoundry.sh/introduction/installation) v1.9.0

## Build

```bash
git clone --recurse-submodules <repo-url>
cd SpreadHunter/contracts
forge build
```

## Loop test on testnet

A small test of the reactive loop: a `Ping` on Base Sepolia makes the reactive contract on Lasna send a callback back to Base Sepolia, which emits `Pong`.

You need a testnet-only wallet with Base Sepolia ETH and lREACT on Lasna. To get lREACT, send ETH to the Reactive faucet contract of the chain you pay from. 1 ETH gives 100 lREACT. Send at most 5 ETH per transaction: anything above that is lost.

| Pay from | Faucet contract |
|---|---|
| Ethereum Sepolia | `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` |
| Base Sepolia | `0x2afaFD298b23b62760711756088F75B7409f5967` |

The scripts sign with a [Foundry keystore](https://www.getfoundry.sh/cast/reference/wallet), so the private key never sits in a plain file. Import the wallet once; it asks for the key and a password:

```bash
cast wallet import spreadhunter-deployer --interactive
```

Then, from the repository root:

```bash
cp .env.example .env            # then set DEPLOYER_ADDRESS
cd contracts
set -a; source ../.env; set +a
: "${DEPLOYER_ACCOUNT:?set it in .env}" "${DEPLOYER_ADDRESS:?set it in .env}"

S=script/SpikeDeploy.s.sol:SpikeDeploy
W="--account $DEPLOYER_ACCOUNT --sender $DEPLOYER_ADDRESS"

# 1. Emitter on Base Sepolia
forge script $S --sig "emitter()" --rpc-url base_sepolia $W --broadcast
# 2. Reactive contract on Lasna: emitter, threshold, lREACT funding in wei
forge script $S --sig "reactive(address,uint256,uint256)" <EMITTER> 10 <FUNDING> --rpc-url lasna $W --broadcast
# 3. Callback on Base Sepolia: reactive contract, ETH funding in wei
forge script $S --sig "callback(address,uint256)" <REACTIVE> <FUNDING> --rpc-url base_sepolia $W --broadcast
# 4. Link the callback on Lasna
forge script $S --sig "link(address,address)" <REACTIVE> <CALLBACK> --rpc-url lasna $W --broadcast
# 5. Ping with a value at or above the threshold
forge script $S --sig "ping(address,uint256)" <EMITTER> 42 --rpc-url base_sepolia $W --broadcast
```

Each step prints the address the next one needs. Check the result with:

```bash
cast call <CALLBACK> "pongCount()(uint256)" --rpc-url base_sepolia
```

## HUNT bridge

HUNT is the test token traded against USDC. It moves between Base Sepolia and Unichain Sepolia through Reactive: the bridge on one chain burns it, a reactive contract on Lasna sees the request, and the bridge on the other chain mints it, in about one to three seconds.

You need ETH on Base Sepolia and Unichain Sepolia and lREACT on Lasna (see above). From `contracts/`, with the variables from `.env` loaded and `W` set as in the loop test:

```bash
B=script/BridgeDeploy.s.sol:BridgeDeploy

# 1. Reactive relay on Lasna, funded with lREACT in wei. It goes first: the bridges need its address
forge script $B --sig "reactive(uint256)" <FUNDING> --rpc-url lasna $W --broadcast
# 2. Token and bridge on each chain: relay address, initial HUNT supply and bridge ETH funding, in wei
forge script $B --sig "pair(address,uint256,uint256)" <RELAY> <SUPPLY> <FUNDING> --rpc-url base_sepolia $W --broadcast
forge script $B --sig "pair(address,uint256,uint256)" <RELAY> <SUPPLY> <FUNDING> --rpc-url unichain_sepolia $W --broadcast
# 3. Link both bridges to the relay
forge script $B --sig "link(address,address,address)" <RELAY> <BASE_BRIDGE> <UNICHAIN_BRIDGE> --rpc-url lasna $W --broadcast
```

The initial supply is the only mint outside the bridge. Then move 1 HUNT to the other chain:

```bash
cast send <BASE_BRIDGE> "bridge(address,uint256)" $DEPLOYER_ADDRESS 1000000000000000000 --rpc-url base_sepolia --account $DEPLOYER_ACCOUNT
```

## License

MIT, see [LICENSE](LICENSE).
