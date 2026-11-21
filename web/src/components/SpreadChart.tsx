import { useEffect, useMemo, useState } from 'react'
import type { FeedState } from '../chain/feed'
import { feeFloor, spread } from '../chain/math'
import { clip, parseSwapsFile, segments, spreadSeries, type SpreadPoint } from '../chain/spreadHistory'
import { useClock } from './useClock'

const W = 600
const H = 200
const PAD = { l: 44, r: 12, t: 14, b: 22 }
// live reads further apart than this left time nobody measured: the line breaks there
const GAP_MS = 15_000

const RANGES = [
  { key: '1H', ms: 3_600_000, edge: '-1 h' },
  { key: '24H', ms: 86_400_000, edge: '-24 h' },
  { key: '7D', ms: 7 * 86_400_000, edge: '-7 d' },
  { key: 'ALL', ms: Infinity, edge: '' },
] as const
type RangeKey = (typeof RANGES)[number]['key']

/** Spread after every swap since the reactive contract went live, from the file `pnpm swaps` writes. */
function useSwapHistory() {
  const [hist, setHist] = useState<{ points: SpreadPoint[]; until: number } | null>(null)
  useEffect(() => {
    let gone = false
    // its own chunk, fetched after the page is up
    import('../data/swaps.json')
      .then((m) => {
        const f = parseSwapsFile(m.default)
        if (!gone && f) setHist({ points: spreadSeries(f.base.points, f.unichain.points), until: Date.parse(f.generatedAt) })
      })
      // without the file the chart shows what it reads live, as before
      .catch(() => {})
    return () => {
      gone = true
    }
  }, [])
  return hist
}

const utc = (t: number) => new Date(t).toISOString().slice(5, 16).replace('T', ' ')

export function SpreadChart({ feed }: { feed: FeedState }) {
  const [range, setRange] = useState<RangeKey>('24H')
  const hist = useSwapHistory()
  const clock = useClock(5000)
  const live = useMemo(() => feed.history.map((p) => ({ t: p.t, s: spread(p.a, p.b) * 100 })).filter((p) => Number.isFinite(p.s)), [feed.history])
  const segs = useMemo(() => segments(hist, live, GAP_MS), [hist, live])

  const r = RANGES.find((x) => x.key === range) ?? RANGES[1]
  const lastSeg = segs[segs.length - 1]
  const newest = lastSeg ? lastSeg[lastSeg.length - 1] : null
  const t1 = Math.max(clock, newest?.t ?? 0) || 60_000
  const first = segs.length ? segs[0][0].t : t1 - 60_000
  const t0 = r.ms === Infinity ? Math.min(first, t1 - 60_000) : t1 - r.ms
  const shown = segs.map((s) => clip(s, t0, t1)).filter((s) => s.length > 0)
  const pts = shown.flat()
  // a live run still being read reaches "now"; any other stretch stops where its data stops
  const reachesNow = newest !== null && newest.t > (hist?.until ?? -Infinity) && t1 - newest.t <= GAP_MS
  const tail = reachesNow ? newest : null

  const a = feed.pools[0]
  const b = feed.pools[1]
  const floor = a && b ? feeFloor(a.fee, b.fee) * 100 : null

  // the axis zooms on the data and the fee floor, so small moves stay visible
  const vals = [...pts.map((p) => p.s), ...(floor !== null ? [floor] : [])]
  const lo0 = vals.length ? Math.min(...vals) : 0
  const hi0 = vals.length ? Math.max(...vals) : 0.2
  const pad = Math.max((hi0 - lo0) * 0.35, 0.01)
  const minS = Math.max(0, lo0 - pad)
  const maxS = hi0 + pad
  const x = (t: number) => PAD.l + ((t - t0) / (t1 - t0 || 1)) * (W - PAD.l - PAD.r)
  const y = (s: number) => PAD.t + (1 - (s - minS) / (maxS - minS || 1)) * (H - PAD.t - PAD.b)

  // a step line: the spread holds until the next swap moves one of the two prices
  let d = ''
  for (const seg of shown) {
    seg.forEach((p, i) => {
      d += i === 0 ? `M${x(p.t)} ${y(p.s)}` : `H${x(p.t)} V${y(p.s)}`
    })
    // the last value holds to the end of its stretch
    d += ` H${x(seg === shown[shown.length - 1] && tail ? t1 : seg[seg.length - 1].t)}`
  }
  const last = tail
  const ticks = [minS, (minS + maxS) / 2, maxS]

  return (
    <figure className="chart">
      <figcaption>
        <span className="chart-title">Spread</span>
        <span className="chart-ranges" role="group" aria-label="Time range">
          {RANGES.map((x) => (
            <button key={x.key} type="button" aria-pressed={x.key === range} onClick={() => setRange(x.key)}>
              {x.key}
            </button>
          ))}
        </span>
        <span className="chart-legend">
          <i className="lg lg-line" /> spread <i className="lg lg-floor" /> fee floor
        </span>
      </figcaption>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={last ? `Spread over ${r.key === 'ALL' ? 'all the history' : `the last ${r.edge.slice(1)}`}, now ${last.s.toFixed(3)} percent` : 'Waiting for prices'}>
        {ticks.map((v) => (
          <g key={v}>
            <line x1={PAD.l} x2={W - PAD.r} y1={y(v)} y2={y(v)} className="grid" />
            <text x={PAD.l - 6} y={y(v) + 4} textAnchor="end" className="axis">{v.toFixed(v >= 10 ? 1 : v >= 1 ? 2 : 3)}%</text>
          </g>
        ))}
        {floor !== null && (
          <>
            <rect x={PAD.l} y={PAD.t} width={W - PAD.l - PAD.r} height={Math.max(0, y(floor) - PAD.t)} className="zone" />
            <line x1={PAD.l} x2={W - PAD.r} y1={y(floor)} y2={y(floor)} className="floor" />
            <text x={W - PAD.r - 4} y={PAD.t + 12} textAnchor="end" className="zone-label">above the fees</text>
          </>
        )}
        {pts.length > 0 && <path d={d} className="sline" />}
        {last && <circle cx={x(t1)} cy={y(last.s)} r={4} className="sdot" />}
        <text x={PAD.l} y={H - 4} className="axis">{r.ms === Infinity ? `${utc(t0)} UTC` : r.edge}</text>
        <text x={W - PAD.r} y={H - 4} textAnchor="end" className="axis">now</text>
        {pts.length === 0 && (
          <text x={W / 2} y={H / 2} textAnchor="middle" className="axis">{segs.length ? 'no data in this range' : 'reading both pools…'}</text>
        )}
      </svg>
      <p className="chart-note">
        {hist ? `Every swap of both pools up to ${utc(hist.until)} UTC, then read live.` : 'Read live since this page opened.'}
      </p>
    </figure>
  )
}
