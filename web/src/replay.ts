// The first live cycle, 2026-11-19, as published in the README. Every value was read from the chain.

export type Edge = 'in-uni' | 'in-base' | 'uni-lasna' | 'base-lasna' | 'lasna-base' | 'lasna-uni' | 'exec-base' | 'exec-uni' | 'leg-base' | 'leg-uni'

export interface ReplayStep {
  /** when the step starts in the animation, in ms */
  at: number
  /** seconds after the trigger swap, from block timestamps */
  real: string
  edges: Edge[]
  label: string
  detail: string
  chain: 'base' | 'unichain' | 'lasna'
  tx: `0x${string}`
}

export const REPLAY_STEPS: ReplayStep[] = [
  {
    at: 0,
    real: '0 s',
    edges: ['in-uni'],
    label: 'Someone buys HUNT with 20 USDC',
    detail: 'HUNT is now about 10% dearer on Unichain',
    chain: 'unichain',
    tx: '0xfa6cb57de334921d50bdda7c10e190376cf6600bf4a31c59368f08250a4e97b2',
  },
  {
    at: 1600,
    real: 'within 1 s',
    edges: ['uni-lasna', 'lasna-base', 'lasna-uni'],
    label: 'Reactive contract sizes the trade',
    detail: '9.608635 USDC in, 0.472628 USDC expected, both legs sent',
    chain: 'lasna',
    tx: '0x5930979bf0d29c8ed07262be278df1ac77122f2ce9d3fb8b83ed4b907f21c64a',
  },
  {
    at: 4200,
    real: '1 s',
    edges: ['exec-base', 'leg-base'],
    label: 'Buy on Base',
    detail: '937.4022 HUNT for 9.608635 USDC',
    chain: 'base',
    tx: '0xd87c7be443e98af70aac8cf0ece0094f8ebb6ac0b76f3c4dc89b6d64c7def20c',
  },
  {
    at: 6000,
    real: '2 s',
    edges: ['exec-uni', 'leg-uni'],
    label: 'Sell on Unichain',
    detail: '937.4023 HUNT for 10.081263 USDC',
    chain: 'unichain',
    tx: '0xa7a13b48f516ab4e313f07356897ed106c9ad1f216686265f2093ac27f17933e',
  },
]

export const REPLAY_PROFIT = '0.472628'
export const REPLAY_PROFIT_AT = 8200
export const REPLAY_LOOP_MS = 12_500
