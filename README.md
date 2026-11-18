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

## License

MIT, see [LICENSE](LICENSE).
