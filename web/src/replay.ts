// Turns one real trade, read from the chains, into the slowed-down steps the map replays.
import type { LegStamp, TradeTimeline } from './chain/latency'
import { formatUnits } from './chain/math'
import { CHAINS, SIDES, TOKEN_DECIMALS, TOKEN_SYMBOL, USDC_DECIMALS } from './config/testnet'
import { FIRST_TRADE } from './data/firstTrade'

export type Edge = 'in-uni' | 'in-base' | 'uni-lasna' | 'base-lasna' | 'lasna-base' | 'lasna-uni' | 'exec-base' | 'exec-uni' | 'leg-base' | 'leg-uni'

export interface ReplayStep {
  /** when the step starts in the animation, in ms */
  at: number
  /** seconds after the trigger swap, from block timestamps */
  real: string
  particles: { edge: Edge; label: string }[]
  label: string
  detail: string
  chain: 'base' | 'unichain' | 'lasna'
  tx: `0x${string}`
}

export type ReplaySource = 'chain' | 'bundled' | 'first'

export interface Replay {
  nonce: bigint
  /** where the trade came from: read live now, the bundled report, or the first cycle */
  source: ReplaySource
  /** block time the trade closed or, without a close, was requested; unix seconds */
  ts: number
  steps: ReplayStep[]
  /** USDC received on the sell leg minus USDC paid on the buy leg, with its sign; null unless both legs executed */
  profit: string | null
  /** seconds from the swap to the last leg */
  profitReal: string
}

export const REPLAY_PROFIT_AT = 8200
export const REPLAY_LOOP_MS = 12_500

const AT = { swap: 0, request: 1600, buy: 4200, sell: 6000 } as const

const usdc = (v: bigint, shown = 2) => formatUnits(v, USDC_DECIMALS, shown)
const tok = (v: bigint, shown = 2) => formatUnits(v, TOKEN_DECIMALS, shown)
const edgeSide = (chain: 'base' | 'unichain') => (chain === 'base' ? 'base' : 'uni')

export function replayFrom(t: TradeTimeline, source: ReplaySource): Replay {
  const o = t.origin
  const zero = o?.ts ?? t.requested.ts
  const since = (ts: number) => `${Math.max(0, ts - zero)} s`
  const steps: ReplayStep[] = []

  if (o && o.chain !== 'lasna') {
    const s = edgeSide(o.chain)
    const what = o.swap ? (o.swap.buyToken ? `buys ${TOKEN_SYMBOL} with ${usdc(o.swap.usdc, 6)} USDC` : `sells ${tok(o.swap.token, 4)} ${TOKEN_SYMBOL}`) : `trades ${TOKEN_SYMBOL}`
    const label = o.swap ? (o.swap.buyToken ? `buy · ${usdc(o.swap.usdc)} USDC` : `sell · ${tok(o.swap.token)} ${TOKEN_SYMBOL}`) : 'swap'
    steps.push({
      at: AT.swap,
      real: '0 s',
      particles: [{ edge: `in-${s}`, label }],
      label: `A swap ${what}`,
      detail: `The ${CHAINS[o.chain].name} pool price moves`,
      chain: o.chain,
      tx: o.tx,
    })
  }

  const buySide = t.cheapSide === 0 ? 0 : 1
  const sellSide = buySide === 0 ? 1 : 0
  const buy = t.legs[buySide]
  const sell = t.legs[sellSide]
  const buyChain = SIDES[buySide].chain
  const sellChain = SIDES[sellSide].chain
  const reqParticles: ReplayStep['particles'] = []
  if (o && o.chain !== 'lasna') reqParticles.push({ edge: `${edgeSide(o.chain)}-lasna`, label: 'Swap log' })
  reqParticles.push(
    { edge: `lasna-${edgeSide(buyChain)}`, label: buy?.fill ? `BUY ${usdc(buy.fill.paid)} USDC` : 'BUY' },
    { edge: `lasna-${edgeSide(sellChain)}`, label: sell?.fill ? `SELL ${tok(sell.fill.paid)} ${TOKEN_SYMBOL}` : 'SELL' },
  )
  steps.push({
    at: AT.request,
    real: o ? 'within 1 s' : '0 s',
    particles: reqParticles,
    label: 'Reactive contract sizes the trade',
    detail: 'Both legs sent in one reaction',
    chain: 'lasna',
    tx: t.requested.tx,
  })

  const legStep = (leg: LegStamp | null, at: number, isBuy: boolean, chain: 'base' | 'unichain') => {
    if (!leg) return
    const s = edgeSide(chain)
    const name = `${isBuy ? 'Buy' : 'Sell'} on ${CHAINS[chain].name}`
    const f = leg.fill
    steps.push({
      at,
      real: since(leg.ts),
      particles: [
        { edge: `exec-${s}`, label: f ? (isBuy ? `bought ${tok(f.received)}` : `sold for ${usdc(f.received)}`) : 'failed' },
        { edge: `leg-${s}`, label: f ? 'LegExecuted' : 'LegFailed' },
      ],
      label: f ? name : `${name} failed`,
      detail: f ? (isBuy ? `${tok(f.received, 4)} ${TOKEN_SYMBOL} for ${usdc(f.paid, 6)} USDC` : `${tok(f.paid, 4)} ${TOKEN_SYMBOL} for ${usdc(f.received, 6)} USDC`) : 'The Executor reported LegFailed',
      chain,
      tx: leg.tx,
    })
  }
  legStep(buy, AT.buy, true, buyChain)
  legStep(sell, AT.sell, false, sellChain)

  const net = buy?.fill && sell?.fill ? sell.fill.received - buy.fill.paid : null
  const lastLeg = Math.max(buy?.ts ?? zero, sell?.ts ?? zero)
  return {
    nonce: t.nonce,
    source,
    ts: t.closed?.ts ?? t.requested.ts,
    steps,
    profit: net === null ? null : `${net >= 0n ? '+' : ''}${usdc(net, 6)}`,
    profitReal: since(lastLeg),
  }
}

export const FIRST_REPLAY = replayFrom(FIRST_TRADE, 'first')

/** How long ago a block time was, for the replay header; empty until the clock has ticked. */
export function agoText(ts: number, nowMs: number) {
  if (nowMs === 0) return ''
  const s = Math.max(0, Math.floor(nowMs / 1000) - ts)
  if (s < 60) return 'less than a minute ago'
  if (s < 3600) return `${Math.floor(s / 60)} min ago`
  if (s < 48 * 3600) return `${Math.floor(s / 3600)} h ago`
  return `on ${new Date(ts * 1000).toISOString().slice(0, 10)}`
}

/** Map header and steps title: only a trade read live now is called the last one. */
export function replayHeading(r: Replay, nowMs: number) {
  if (r.source === 'chain') {
    const when = agoText(r.ts, nowMs)
    return { note: `The last trade, #${r.nonce}, slowed down. Real values and transactions.`, title: `last trade #${r.nonce}${when ? `, ${when}` : ''}` }
  }
  const date = `${new Date(r.ts * 1000).toISOString().slice(0, 16).replace('T', ' ')} UTC`
  return { note: `Trade #${r.nonce} of ${date}, slowed down. Real values and transactions.`, title: `trade #${r.nonce}, ${date}` }
}
