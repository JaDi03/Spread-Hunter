import type { TradeTimeline } from './latency'

// block timestamps and amounts of trade #1, read from the three chains
export const trade1: TradeTimeline = {
  nonce: 1n,
  cheapSide: 0,
  origin: { chain: 'unichain', tx: '0xfa6cb57de334921d50bdda7c10e190376cf6600bf4a31c59368f08250a4e97b2', block: 68284474n, ts: 1795136902, swap: { buyToken: true, usdc: 20_000_000n, token: 1903854853686992547441n } },
  requested: { chain: 'lasna', tx: '0x5930979bf0d29c8ed07262be278df1ac77122f2ce9d3fb8b83ed4b907f21c64a', block: 8772837n, ts: 1795136901 },
  legs: [
    { chain: 'base', tx: '0xd87c7be443e98af70aac8cf0ece0094f8ebb6ac0b76f3c4dc89b6d64c7def20c', block: 61075173n, ts: 1795136903, ok: true, fill: { buyToken: true, paid: 9_608_635n, received: 937402221914402473803n } },
    { chain: 'unichain', tx: '0xa7a13b48f516ab4e313f07356897ed106c9ad1f216686265f2093ac27f17933e', block: 68284476n, ts: 1795136904, ok: true, fill: { buyToken: false, paid: 937402289257704367327n, received: 10_081_263n } },
  ],
  closed: null,
  pending: false,
}
