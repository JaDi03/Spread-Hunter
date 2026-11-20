import type { FeedState } from '../chain/feed'
import { feeFloor, spread } from '../chain/math'

const W = 600
const H = 200
const PAD = { l: 44, r: 12, t: 14, b: 22 }
const GAP_MS = 15_000

export function SpreadChart({ feed }: { feed: FeedState }) {
  const pts = feed.history.map((p) => ({ t: p.t, s: spread(p.a, p.b) * 100 })).filter((p) => Number.isFinite(p.s))
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
  const t1 = pts.length ? pts[pts.length - 1].t : 60_000
  const t0 = Math.min(pts.length ? pts[0].t : t1, t1 - 60_000)
  const x = (t: number) => PAD.l + ((t - t0) / (t1 - t0 || 1)) * (W - PAD.l - PAD.r)
  const y = (s: number) => PAD.t + (1 - (s - minS) / (maxS - minS || 1)) * (H - PAD.t - PAD.b)

  // a step line: the price only moves when someone swaps; a gap with no reads breaks the line
  let d = ''
  pts.forEach((p, i) => {
    const gap = i > 0 && p.t - pts[i - 1].t > GAP_MS
    d += i === 0 || gap ? `M${x(p.t)} ${y(p.s)}` : `H${x(p.t)} V${y(p.s)}`
  })
  const last = pts[pts.length - 1]
  const ticks = [minS, (minS + maxS) / 2, maxS]
  const minutes = Math.max(1, Math.round((t1 - t0) / 60_000))

  return (
    <figure className="chart">
      <figcaption>
        <span className="chart-title">Spread, last {minutes} min</span>
        <span className="chart-legend">
          <i className="lg lg-line" /> spread <i className="lg lg-floor" /> fee floor
        </span>
      </figcaption>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={last ? `Spread now ${last.s.toFixed(3)} percent` : 'Waiting for prices'}>
        {ticks.map((v) => (
          <g key={v}>
            <line x1={PAD.l} x2={W - PAD.r} y1={y(v)} y2={y(v)} className="grid" />
            <text x={PAD.l - 6} y={y(v) + 4} textAnchor="end" className="axis">{v.toFixed(3)}%</text>
          </g>
        ))}
        {floor !== null && (
          <>
            <rect x={PAD.l} y={PAD.t} width={W - PAD.l - PAD.r} height={Math.max(0, y(floor) - PAD.t)} className="zone" />
            <line x1={PAD.l} x2={W - PAD.r} y1={y(floor)} y2={y(floor)} className="floor" />
            <text x={W - PAD.r - 4} y={PAD.t + 12} textAnchor="end" className="zone-label">above the fees</text>
          </>
        )}
        {pts.length > 0 && <path d={`${d} H${x(t1)}`} className="sline" />}
        {last && <circle cx={x(last.t)} cy={y(last.s)} r={4} className="sdot" />}
        <text x={PAD.l} y={H - 4} className="axis">-{minutes} min</text>
        <text x={W - PAD.r} y={H - 4} textAnchor="end" className="axis">now</text>
        {pts.length === 0 && (
          <text x={W / 2} y={H / 2} textAnchor="middle" className="axis">reading both pools…</text>
        )}
      </svg>
    </figure>
  )
}
