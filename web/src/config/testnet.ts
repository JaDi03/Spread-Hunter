// Public testnet values for the demo pair. Nothing here is secret.

export type ChainKey = 'base' | 'lasna' | 'unichain'

export interface ChainConfig {
  key: ChainKey
  name: string
  short: string
  chainId: number
  rpcUrl: string
  explorer: string
  pollMs: number
  maxLogRange: bigint
  /** blocks in about 20 s: an event this recent is shown as live on the map */
  liveBlocks: bigint
}

// Log ranges sit under each RPC's eth_getLogs limit (Base 200 blocks, Unichain 1000, Lasna 10 000 accepted).
// Block times measured 2026-11-20: Base Sepolia 0.2 s, Unichain Sepolia 1 s, Lasna about 1.07 s.
export const CHAINS: Record<ChainKey, ChainConfig> = {
  base: {
    key: 'base',
    name: 'Base Sepolia',
    short: 'BASE',
    chainId: 84532,
    rpcUrl: 'https://sepolia.base.org',
    explorer: 'https://sepolia.basescan.org',
    pollMs: 4000,
    maxLogRange: 190n,
    liveBlocks: 100n,
  },
  unichain: {
    key: 'unichain',
    name: 'Unichain Sepolia',
    short: 'UNICHAIN',
    chainId: 1301,
    rpcUrl: 'https://sepolia.unichain.org',
    explorer: 'https://sepolia.uniscan.xyz',
    pollMs: 4000,
    maxLogRange: 900n,
    liveBlocks: 20n,
  },
  lasna: {
    key: 'lasna',
    name: 'Reactive Lasna',
    short: 'LASNA',
    chainId: 5318007,
    rpcUrl: 'https://lasna-rpc.rnk.dev/',
    explorer: 'https://lasna.reactscan.net',
    pollMs: 4000,
    maxLogRange: 9000n,
    liveBlocks: 20n,
  },
}

export const REACTIVE_CONTRACT = '0xA07fcfCbE127D14668Ffb93f41aFF270b151777F' as const
/** Lasna block of the reactive contract's deployment: no trade can be older */
export const REACTIVE_DEPLOY_BLOCK = 8772026n

export interface SideConfig {
  side: 0 | 1
  chain: 'base' | 'unichain'
  executor: `0x${string}`
  poolManager: `0x${string}`
  stateView: `0x${string}`
  poolId: `0x${string}`
  usdc: `0x${string}`
  token: `0x${string}`
}

// Side 0 is Base Sepolia and side 1 is Unichain Sepolia, as in the reactive contract.
export const SIDES: readonly [SideConfig, SideConfig] = [
  {
    side: 0,
    chain: 'base',
    executor: '0x63d0c088C404E5800CA21BFffDd39Db273Cdd500',
    poolManager: '0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408',
    stateView: '0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4',
    poolId: '0xff22002f000707834d52741f48fef85a77aebc7ac17d1ed9a64538b036d711b2',
    usdc: '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
    token: '0xDf9a8390085267F6E197Bd4D28d4532c19628391',
  },
  {
    side: 1,
    chain: 'unichain',
    executor: '0x5Ae2db5f67D73749a4D06229e851CAEd21F37753',
    poolManager: '0x00B036B58a818B1BC34d502D3fE730Db729e62AC',
    stateView: '0xc199F1072a74D4e905ABa1A84d9a45E2546B6222',
    poolId: '0xac8899d8e500a5741a4c146f1d465e76c69daf365a46aa6a95305ea4cfddf9c5',
    usdc: '0x31d0220469e10c4E71834a79b1f276d740d3768F',
    token: '0xFF548c03b910bF69eeb026B10CF195a9925F9719',
  },
] as const

export const TOKEN_SYMBOL = 'HUNT'
export const USDC_DECIMALS = 6
export const TOKEN_DECIMALS = 18

export const REPO_URL = 'https://github.com/JaDi03/Spread-Hunter'
