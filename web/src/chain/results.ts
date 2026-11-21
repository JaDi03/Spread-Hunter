import type { TradeTimeline } from './latency.ts'

export interface SideDelta {
  /** USDC the Executor gained (positive) or spent (negative), 6 decimals */
  usdc: bigint
  /** token the Executor gained or spent, in its smallest unit */
  token: bigint
}

export interface Results {
  trades: number
  /** trades with both legs executed */
  complete: number
  /** trades where exactly one leg executed: its inventory moved but no profit was locked in */
  oneLeg: number
  /** USDC made by the complete trades, both pool fees already paid */
  realizedUsdc: bigint
  /** token left over or short from the complete trades: the two legs never match to the last unit */
  tokenDrift: bigint
  /** change of each Executor's inventory from every executed leg, side 0 then side 1 */
  sides: [SideDelta, SideDelta]
}

function legDelta(fill: { buyToken: boolean; paid: bigint; received: bigint }): SideDelta {
  return fill.buyToken ? { usdc: -fill.paid, token: fill.received } : { usdc: fill.received, token: -fill.paid }
}

export function resultsOf(trades: readonly TradeTimeline[]): Results {
  const sides: [SideDelta, SideDelta] = [
    { usdc: 0n, token: 0n },
    { usdc: 0n, token: 0n },
  ]
  let complete = 0
  let oneLeg = 0
  let realizedUsdc = 0n
  let tokenDrift = 0n
  for (const t of trades) {
    const deltas = t.legs.map((l) => (l?.ok && l.fill ? legDelta(l.fill) : null))
    deltas.forEach((d, side) => {
      if (!d) return
      sides[side].usdc += d.usdc
      sides[side].token += d.token
    })
    const [a, b] = deltas
    if (a && b) {
      complete++
      realizedUsdc += a.usdc + b.usdc
      tokenDrift += a.token + b.token
    } else if (a || b) {
      oneLeg++
    }
  }
  return { trades: trades.length, complete, oneLeg, realizedUsdc, tokenDrift, sides }
}
