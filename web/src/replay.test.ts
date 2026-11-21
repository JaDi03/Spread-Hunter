import { describe, expect, it } from 'vitest'
import { trade1 } from './chain/trade1.fixture'
import { agoText, replayFrom, replayHeading } from './replay'

describe('replayFrom', () => {
  it('rebuilds the README cycle of 2026-11-19 from its transactions', () => {
    const r = replayFrom(trade1, 'chain')
    expect(r.steps.map((s) => [s.label, s.detail, s.real, s.tx])).toEqual([
      ['A swap buys HUNT with 20.000000 USDC', 'The Unichain Sepolia pool price moves', '0 s', trade1.origin!.tx],
      ['Reactive contract sizes the trade', 'Both legs sent in one reaction', 'within 1 s', trade1.requested.tx],
      ['Buy on Base Sepolia', '937.4022 HUNT for 9.608635 USDC', '1 s', trade1.legs[0]!.tx],
      ['Sell on Unichain Sepolia', '937.4022 HUNT for 10.081263 USDC', '2 s', trade1.legs[1]!.tx],
    ])
    expect(r.steps[1].particles.map((p) => p.edge)).toEqual(['uni-lasna', 'lasna-base', 'lasna-uni'])
    expect(r.profit).toBe('+0.472628')
    expect(r.profitReal).toBe('2 s')
  })

  it('buys on Unichain when it is the cheap side', () => {
    const r = replayFrom({ ...trade1, cheapSide: 1 }, 'chain')
    expect(r.steps[2].label).toBe('Buy on Unichain Sepolia')
    expect(r.steps[2].tx).toBe(trade1.legs[1]!.tx)
    expect(r.steps[1].particles.map((p) => p.edge)).toEqual(['uni-lasna', 'lasna-uni', 'lasna-base'])
  })

  it('shows a failed leg and no profit', () => {
    const r = replayFrom({ ...trade1, legs: [trade1.legs[0], { ...trade1.legs[1]!, ok: false, fill: null }] }, 'chain')
    expect(r.steps[3].label).toBe('Sell on Unichain Sepolia failed')
    expect(r.profit).toBeNull()
  })

  it('signs a loss', () => {
    const sell = { ...trade1.legs[1]!, fill: { ...trade1.legs[1]!.fill!, received: 9_000_000n } }
    expect(replayFrom({ ...trade1, legs: [trade1.legs[0], sell] }, 'chain').profit).toBe('-0.608635')
  })
})

describe('agoText', () => {
  const ts = 1795236812
  it('says how long ago in minutes, hours, then the date', () => {
    expect(agoText(ts, 0)).toBe('')
    expect(agoText(ts, (ts + 30) * 1000)).toBe('less than a minute ago')
    expect(agoText(ts, (ts + 25 * 60) * 1000)).toBe('25 min ago')
    expect(agoText(ts, (ts + 5 * 3600) * 1000)).toBe('5 h ago')
    expect(agoText(ts, (ts + 3 * 86400) * 1000)).toBe('on 2026-11-21')
  })
})

describe('replayHeading', () => {
  it('calls only a trade read live the last one', () => {
    const now = (trade1.requested.ts + 600) * 1000
    expect(replayHeading(replayFrom(trade1, 'chain'), now).title).toBe('last trade #1, 10 min ago')
    expect(replayHeading(replayFrom(trade1, 'bundled'), now).title).toBe('trade #1, 2026-11-20 01:08 UTC')
    expect(replayHeading(replayFrom(trade1, 'first'), now).note).toBe('Trade #1 of 2026-11-20 01:08 UTC, slowed down. Real values and transactions.')
  })
})
