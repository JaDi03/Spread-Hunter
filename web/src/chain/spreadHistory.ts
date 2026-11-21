import { spread } from './math.ts'

/** [block time in unix seconds, token price in USDC after the swap] */
export type PricePoint = [number, number]

export interface ChainSwaps {
  fromBlock: string
  toBlock: string
  points: PricePoint[]
}

export interface SwapsFile {
  generatedAt: string
  base: ChainSwaps
  unichain: ChainSwaps
}

export interface SpreadPoint {
  /** ms */
  t: number
  /** percent */
  s: number
}

/** The spread after every price change of either pool, once both pools have a price. Inputs are sorted by time. */
export function spreadSeries(a: readonly PricePoint[], b: readonly PricePoint[]): SpreadPoint[] {
  const out: SpreadPoint[] = []
  let i = 0
  let j = 0
  let pa: number | null = null
  let pb: number | null = null
  while (i < a.length || j < b.length) {
    const ta = i < a.length ? a[i][0] : Infinity
    const tb = j < b.length ? b[j][0] : Infinity
    const t = Math.min(ta, tb)
    // swaps of both pools in the same second count as one change
    while (i < a.length && a[i][0] === t) pa = a[i++][1]
    while (j < b.length && b[j][0] === t) pb = b[j++][1]
    if (pa !== null && pb !== null) {
      const s = spread(pa, pb) * 100
      if (Number.isFinite(s)) out.push({ t: t * 1000, s })
    }
  }
  return out
}

/** The points inside [from, to] in ms, starting with the value that held at `from`: the price stays until the next swap. */
export function windowed(points: readonly SpreadPoint[], from: number, to: number): SpreadPoint[] {
  let before: SpreadPoint | null = null
  const inside: SpreadPoint[] = []
  for (const p of points) {
    if (p.t < from) before = p
    else if (p.t <= to) inside.push(p)
  }
  return before ? [{ t: from, s: before.s }, ...inside] : inside
}

/** A bundled swaps file, or null when it is missing or malformed. */
export function parseSwapsFile(v: unknown): SwapsFile | null {
  const f = v as Partial<SwapsFile> | null
  const chain = (c: unknown): ChainSwaps | null => {
    const x = c as Partial<ChainSwaps> | null
    if (!x || typeof x.fromBlock !== 'string' || typeof x.toBlock !== 'string' || !Array.isArray(x.points)) return null
    const ok = x.points.every((p) => Array.isArray(p) && p.length === 2 && Number.isFinite(p[0]) && Number.isFinite(p[1]))
    return ok ? (x as ChainSwaps) : null
  }
  if (!f || typeof f.generatedAt !== 'string') return null
  const base = chain(f.base)
  const unichain = chain(f.unichain)
  return base && unichain ? { generatedAt: f.generatedAt, base, unichain } : null
}

/**
 * Stretches of time the chart knows the spread for: the file up to the moment it was written, then each run of
 * live reads no more than `gapMs` apart. Between stretches nobody read the pools, so nothing is drawn.
 */
export function segments(hist: { points: readonly SpreadPoint[]; until: number } | null, live: readonly SpreadPoint[], gapMs: number): SpreadPoint[][] {
  const out: SpreadPoint[][] = []
  if (hist && hist.points.length) {
    const last = hist.points[hist.points.length - 1]
    // the file holds every swap up to `until`, so the last spread held until then
    out.push(hist.until > last.t ? [...hist.points, { t: hist.until, s: last.s }] : [...hist.points])
  }
  const after = hist ? live.filter((p) => p.t > hist.until) : live
  let run: SpreadPoint[] = []
  for (const p of after) {
    if (run.length && p.t - run[run.length - 1].t > gapMs) {
      out.push(run)
      run = []
    }
    run.push(p)
  }
  if (run.length) out.push(run)
  return out
}

/** A stretch cut to [from, to]: what held at `from` is kept, a stretch that ended before `from` is dropped. */
export function clip(seg: readonly SpreadPoint[], from: number, to: number): SpreadPoint[] {
  if (!seg.length || seg[seg.length - 1].t < from) return []
  return windowed(seg, from, to)
}
