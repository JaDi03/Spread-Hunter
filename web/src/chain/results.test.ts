import { describe, expect, it } from 'vitest'
import { resultsOf } from './results'
import { trade1 } from './trade1.fixture'

describe('resultsOf', () => {
  it('gives the profit of trade #1 from its two LegExecuted events', () => {
    const r = resultsOf([trade1])
    // 10.081263 USDC received on Unichain minus 9.608635 paid on Base
    expect(r.realizedUsdc).toBe(472_628n)
    expect(r.tokenDrift).toBe(-67343301893524n)
    expect(r.sides).toEqual([
      { usdc: -9_608_635n, token: 937402221914402473803n },
      { usdc: 10_081_263n, token: -937402289257704367327n },
    ])
    expect(r).toMatchObject({ trades: 1, complete: 1, oneLeg: 0 })
  })

  it('moves the inventory of a lone executed leg but books no profit for it', () => {
    const failed = { ...trade1.legs[1]!, ok: false, fill: null }
    const r = resultsOf([{ ...trade1, legs: [trade1.legs[0], failed] }])
    expect(r.realizedUsdc).toBe(0n)
    expect(r.sides[0].usdc).toBe(-9_608_635n)
    expect(r.sides[1]).toEqual({ usdc: 0n, token: 0n })
    expect(r).toMatchObject({ complete: 0, oneLeg: 1 })
  })

  it('adds trades up and counts one still in flight', () => {
    const r = resultsOf([trade1, trade1, { ...trade1, legs: [null, null], pending: true }])
    expect(r.realizedUsdc).toBe(945_256n)
    expect(r).toMatchObject({ trades: 3, complete: 2, oneLeg: 0 })
  })
})
