import { describe, expect, it } from 'vitest'
import { latencyOf, legId, stats, type TradeTimeline } from './latency'

const RC = '0xA07fcfCbE127D14668Ffb93f41aFF270b151777F'

describe('legId', () => {
  it('matches the leg ids the Executors emitted for trade #1 on 2026-11-19', () => {
    // topic1 of LegExecuted in Base tx 0xd87c7be4… and Unichain tx 0xa7a13b48…
    expect(legId(RC, 1n, 0)).toBe('0x3b2e5cb43dc4249298ae4ecfe86790ce5252f69034dac8575fad03998b8b7f83')
    expect(legId(RC, 1n, 1)).toBe('0x988c3f8d012b59125003e08268e2c28c0784eedb075791c2f194712135c9fc27')
  })
})

// block timestamps of trade #1, read from the three chains
const trade1: TradeTimeline = {
  nonce: 1n,
  cheapSide: 0,
  origin: { chain: 'unichain', tx: '0xfa6cb57de334921d50bdda7c10e190376cf6600bf4a31c59368f08250a4e97b2', block: 68284474n, ts: 1795136902 },
  requested: { chain: 'lasna', tx: '0x5930979bf0d29c8ed07262be278df1ac77122f2ce9d3fb8b83ed4b907f21c64a', block: 8772837n, ts: 1795136901 },
  legs: [
    { chain: 'base', tx: '0xd87c7be443e98af70aac8cf0ece0094f8ebb6ac0b76f3c4dc89b6d64c7def20c', block: 61075173n, ts: 1795136903, ok: true },
    { chain: 'unichain', tx: '0xa7a13b48f516ab4e313f07356897ed106c9ad1f216686265f2093ac27f17933e', block: 68284476n, ts: 1795136904, ok: true },
  ],
  closed: null,
  pending: false,
}

describe('latencyOf', () => {
  it('gives the README timings for trade #1', () => {
    const l = latencyOf(trade1)
    expect(l.originToRequestCrossClock).toBe(-1)
    expect(l.originToLeg).toEqual([1, 2])
    expect(l.originToLegsDone).toBe(2)
    expect(l.requestToClosed).toBeNull()
    expect(l.ok).toBe(true)
  })

  it('measures the close on the Lasna clock only', () => {
    // TradeClosed of trade #1: Lasna block 8772839 (the script output, 2026-11-20)
    const closed = { chain: 'lasna' as const, tx: '0x3818254dd4177f02df964a124a0c17413b4df00b6d0f9e05ac6d3dc183a1bcd5' as const, block: 8772839n, ts: 1795136903, timedOut: false, legFailed: false }
    expect(latencyOf({ ...trade1, closed }).requestToClosed).toBe(2)
  })

  it('leaves a close by timeout or with a failed leg out of the close figure', () => {
    const closed = { chain: 'lasna' as const, tx: '0x3818254dd4177f02df964a124a0c17413b4df00b6d0f9e05ac6d3dc183a1bcd5' as const, block: 8772839n, ts: 1795137100, timedOut: true, legFailed: false }
    expect(latencyOf({ ...trade1, closed }).requestToClosed).toBeNull()
    expect(latencyOf({ ...trade1, closed: { ...closed, timedOut: false, legFailed: true } }).requestToClosed).toBeNull()
  })

  it('reports a trade still in flight as pending, not failed', () => {
    const l = latencyOf({ ...trade1, legs: [trade1.legs[0], null], pending: true })
    expect(l.pending).toBe(true)
    expect(l.ok).toBe(false)
  })

  it('has no totals without the origin swap', () => {
    const l = latencyOf({ ...trade1, origin: null })
    expect(l.originToLegsDone).toBeNull()
    expect(l.originToRequestCrossClock).toBeNull()
  })

  it('marks a trade with a failed or missing leg as not ok', () => {
    expect(latencyOf({ ...trade1, legs: [trade1.legs[0], { ...trade1.legs[1]!, ok: false }] }).ok).toBe(false)
    const missing = latencyOf({ ...trade1, legs: [trade1.legs[0], null] })
    expect(missing.ok).toBe(false)
    expect(missing.originToLegsDone).toBeNull()
  })
})

describe('stats', () => {
  it('summarizes seconds', () => {
    expect(stats([3, 1, 2, 2])).toEqual({ n: 4, min: 1, median: 2, mean: 2, max: 3 })
    expect(stats([])).toBeNull()
  })
})
