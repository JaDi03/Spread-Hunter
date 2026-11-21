import { describe, expect, it } from 'vitest'
import { spread } from './math'
import { clip, parseSwapsFile, segments, spreadSeries, windowed, type PricePoint } from './spreadHistory'

describe('spreadSeries', () => {
  it('starts once both pools have a price and steps on every swap', () => {
    const a: PricePoint[] = [[100, 0.01], [300, 0.0102]]
    const b: PricePoint[] = [[200, 0.011]]
    const s = spreadSeries(a, b)
    expect(s.map((p) => p.t)).toEqual([200_000, 300_000])
    expect(s[0].s).toBeCloseTo(spread(0.01, 0.011) * 100)
    expect(s[1].s).toBeCloseTo(spread(0.0102, 0.011) * 100)
  })

  it('merges swaps of both pools in the same second into one point', () => {
    const s = spreadSeries([[100, 0.01], [200, 0.012]], [[100, 0.011], [200, 0.012]])
    expect(s.map((p) => p.t)).toEqual([100_000, 200_000])
    expect(s[1].s).toBe(0)
  })
})

describe('windowed', () => {
  const pts = [
    { t: 1000, s: 1 },
    { t: 5000, s: 2 },
    { t: 9000, s: 3 },
  ]
  it('carries the value that held at the start of the window', () => {
    expect(windowed(pts, 6000, 10_000)).toEqual([{ t: 6000, s: 2 }, { t: 9000, s: 3 }])
  })
  it('keeps everything when the window covers it all', () => {
    expect(windowed(pts, 0, 10_000)).toEqual(pts)
  })
})

describe('parseSwapsFile', () => {
  const ok = { generatedAt: '2026-11-21T00:00:00Z', base: { fromBlock: '1', toBlock: '2', points: [[1, 0.01]] }, unichain: { fromBlock: '1', toBlock: '2', points: [] } }
  it('accepts a file the script wrote', () => {
    expect(parseSwapsFile(ok)).toEqual(ok)
  })
  it('rejects a broken one', () => {
    expect(parseSwapsFile(null)).toBeNull()
    expect(parseSwapsFile({ ...ok, base: { ...ok.base, points: [[1, 'x']] } })).toBeNull()
  })
})

describe('segments', () => {
  const hist = { points: [{ t: 1000, s: 1 }, { t: 2000, s: 2 }], until: 5000 }
  it('ends the file at the moment it was written and splits live reads at gaps', () => {
    const live = [
      { t: 4000, s: 9 },
      { t: 60_000, s: 3 },
      { t: 64_000, s: 4 },
      { t: 100_000, s: 5 },
    ]
    expect(segments(hist, live, 15_000)).toEqual([
      [{ t: 1000, s: 1 }, { t: 2000, s: 2 }, { t: 5000, s: 2 }],
      [{ t: 60_000, s: 3 }, { t: 64_000, s: 4 }],
      [{ t: 100_000, s: 5 }],
    ])
  })
  it('works with live reads only', () => {
    expect(segments(null, [{ t: 1, s: 1 }], 15_000)).toEqual([[{ t: 1, s: 1 }]])
  })
})

describe('clip', () => {
  it('drops a stretch that ended before the window and keeps what held at its start', () => {
    const seg = [{ t: 1000, s: 1 }, { t: 5000, s: 2 }]
    expect(clip(seg, 6000, 9000)).toEqual([])
    expect(clip(seg, 2000, 9000)).toEqual([{ t: 2000, s: 1 }, { t: 5000, s: 2 }])
  })
})
