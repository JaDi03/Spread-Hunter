import { useMemo } from 'react'
import type { FeedEvent, FeedState } from '../chain/feed'
import { formatUnits } from '../chain/math'
import { TOKEN_DECIMALS, TOKEN_SYMBOL, USDC_DECIMALS } from '../config/testnet'
import { REPLAY_LOOP_MS, REPLAY_PROFIT_AT, replayHeading, type Edge, type Replay } from '../replay'
import { TxLink } from './TxLink'
import { useClock } from './useClock'
import { useMediaQuery } from './useMediaQuery'

type Pt = { x: number; y: number }
type NodeKey = 'lasna' | 'execBase' | 'execUni' | 'poolBase' | 'poolUni' | 'mktBase' | 'mktUni'

interface Layout {
  w: number
  h: number
  nodes: Record<NodeKey, Pt>
  bend: number
}

const WIDE: Layout = {
  w: 1000,
  h: 600,
  bend: 150,
  nodes: {
    lasna: { x: 500, y: 105 },
    execBase: { x: 230, y: 320 },
    execUni: { x: 770, y: 320 },
    poolBase: { x: 230, y: 492 },
    poolUni: { x: 770, y: 492 },
    mktBase: { x: 40, y: 585 },
    mktUni: { x: 960, y: 585 },
  },
}

const NARROW: Layout = {
  w: 400,
  h: 700,
  bend: 60,
  nodes: {
    lasna: { x: 200, y: 92 },
    execBase: { x: 104, y: 352 },
    execUni: { x: 296, y: 352 },
    poolBase: { x: 104, y: 548 },
    poolUni: { x: 296, y: 548 },
    mktBase: { x: 14, y: 690 },
    mktUni: { x: 386, y: 690 },
  },
}

const EDGES: Record<Edge, { from: NodeKey; to: NodeKey; side: -1 | 0 | 1; color: string }> = {
  'in-base': { from: 'mktBase', to: 'poolBase', side: 0, color: 'var(--base)' },
  'in-uni': { from: 'mktUni', to: 'poolUni', side: 0, color: 'var(--uni)' },
  'base-lasna': { from: 'poolBase', to: 'lasna', side: -1, color: 'var(--base)' },
  'uni-lasna': { from: 'poolUni', to: 'lasna', side: 1, color: 'var(--uni)' },
  'lasna-base': { from: 'lasna', to: 'execBase', side: 0, color: 'var(--lasna)' },
  'lasna-uni': { from: 'lasna', to: 'execUni', side: 0, color: 'var(--lasna)' },
  'exec-base': { from: 'execBase', to: 'poolBase', side: 0, color: 'var(--base)' },
  'exec-uni': { from: 'execUni', to: 'poolUni', side: 0, color: 'var(--uni)' },
  'leg-base': { from: 'execBase', to: 'lasna', side: 1, color: 'var(--base)' },
  'leg-uni': { from: 'execUni', to: 'lasna', side: -1, color: 'var(--uni)' },
}

function control(l: Layout, e: Edge): Pt {
  const { from, to, side } = EDGES[e]
  const a = l.nodes[from]
  const b = l.nodes[to]
  const mx = (a.x + b.x) / 2
  const my = (a.y + b.y) / 2
  if (side === 0) return { x: mx, y: my }
  // bend outward for pool reports, inward for leg reports, so lines do not overlap
  const dx = b.x - a.x
  const dy = b.y - a.y
  const len = Math.hypot(dx, dy) || 1
  return { x: mx + (-dy / len) * l.bend * side, y: my + (dx / len) * l.bend * side }
}

function at(l: Layout, e: Edge, t: number): Pt {
  const a = l.nodes[EDGES[e].from]
  const b = l.nodes[EDGES[e].to]
  const c = control(l, e)
  const u = 1 - t
  return { x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y }
}

function pathD(l: Layout, e: Edge) {
  const a = l.nodes[EDGES[e].from]
  const b = l.nodes[EDGES[e].to]
  const c = control(l, e)
  return `M${a.x} ${a.y} Q${c.x} ${c.y} ${b.x} ${b.y}`
}

interface Particle {
  id: string
  edge: Edge
  label: string
  start: number
  dur: number
}

const PARTICLE_MS = 1500
const LIVE_HOLD_MS = 20_000

function usdc(v: bigint) {
  return formatUnits(v, USDC_DECIMALS, 2)
}
function tok(v: bigint) {
  return formatUnits(v, TOKEN_DECIMALS, 2)
}

function particlesFor(e: FeedEvent): Particle[] {
  const p = (edge: Edge, label: string, delay = 0): Particle => ({ id: `${e.id}:${edge}`, edge, label, start: e.at + delay, dur: PARTICLE_MS })
  switch (e.kind) {
    case 'swap': {
      if (e.byBot) return []
      const side = e.chain === 'base' ? 'base' : 'uni'
      const what = e.buyToken ? `buy · ${usdc(e.usdc)} USDC` : `sell · ${tok(e.token)} ${TOKEN_SYMBOL}`
      return [p(`in-${side}`, what), p(`${side}-lasna`, 'Swap log', PARTICLE_MS)]
    }
    case 'trade': {
      const buyOnBase = e.cheapSide === 0
      return [
        p('lasna-base', buyOnBase ? `BUY ${usdc(e.usdcIn)} USDC` : `SELL ${tok(e.tokenAmount)} ${TOKEN_SYMBOL}`),
        p('lasna-uni', buyOnBase ? `SELL ${tok(e.tokenAmount)} ${TOKEN_SYMBOL}` : `BUY ${usdc(e.usdcIn)} USDC`),
      ]
    }
    case 'leg': {
      const side = e.chain === 'base' ? 'base' : 'uni'
      return [p(`exec-${side}`, e.buyToken ? `bought ${tok(e.received)}` : `sold for ${usdc(e.received)}`), p(`leg-${side}`, 'LegExecuted', PARTICLE_MS)]
    }
    case 'legFailed': {
      const side = e.chain === 'base' ? 'base' : 'uni'
      return [p(`leg-${side}`, 'LegFailed')]
    }
    default:
      return []
  }
}

interface Props {
  feed: FeedState
  replay: Replay
  reducedMotion: boolean
  visible: boolean
}

export function FlowMap({ feed, replay, reducedMotion, visible }: Props) {
  const narrow = useMediaQuery('(max-width: 720px)')
  const l = narrow ? NARROW : WIDE
  const now = useClock(reducedMotion ? 500 : undefined, !visible)

  // events seen while the page is open become particles, timed from the moment they were read
  const live = useMemo(() => feed.events.filter((e) => e.at > 0), [feed.events])
  const lastLiveAt = live.reduce((m, e) => Math.max(m, e.at), 0)
  const liveParticles = useMemo(() => live.flatMap(particlesFor), [live])
  const isLive = lastLiveAt > 0 && now - lastLiveAt < LIVE_HOLD_MS
  // the replay starts over once the live burst is done
  const rt = (((now - (lastLiveAt > 0 ? lastLiveAt + LIVE_HOLD_MS : 0)) % REPLAY_LOOP_MS) + REPLAY_LOOP_MS) % REPLAY_LOOP_MS

  const replayParticles: Particle[] = useMemo(
    () =>
      replay.steps.flatMap((s) =>
        s.particles.map(({ edge, label }, k) => {
          const delay = edge.startsWith('leg') ? PARTICLE_MS : edge.startsWith('lasna') ? 900 : 0
          return { id: `replay:${replay.nonce}:${s.at}:${k}`, edge, label, start: s.at + delay, dur: PARTICLE_MS }
        }),
      ),
    [replay],
  )
  const heading = replayHeading(replay, useClock(30_000, !visible))

  const active: { p: Particle; t: number }[] = isLive
    ? liveParticles.map((p) => ({ p, t: (now - p.start) / p.dur })).filter((x) => x.t >= 0 && x.t <= 1)
    : replayParticles.map((p) => ({ p, t: (rt - p.start) / p.dur })).filter((x) => x.t >= 0 && x.t <= 1)

  const hot = new Set<NodeKey>()
  for (const { p, t } of active) hot.add(t > 0.85 ? EDGES[p.edge].to : EDGES[p.edge].from)

  const step = isLive ? -1 : replay.steps.reduce((acc, s, i) => (rt >= s.at ? i : acc), -1)
  const profitOn = !isLive && replay.profit !== null && rt >= REPLAY_PROFIT_AT

  const pb = feed.pools[0]
  const pu = feed.pools[1]
  const r = feed.reactive

  return (
    <div className="flow">
      <div className="flow-head">
        <span className={isLive ? 'mode mode-live' : 'mode mode-replay'}>
          <i aria-hidden="true" />
          {isLive ? 'LIVE' : 'REPLAY'}
        </span>
        <span className="flow-note">
          {isLive ? 'Events from the chains, as they arrive' : heading.note}
        </span>
      </div>
      <svg className="flow-svg" viewBox={`0 0 ${l.w} ${l.h}`} role="img" aria-label="Map of one arbitrage cycle across Base, Reactive Lasna and Unichain">
        {(Object.keys(EDGES) as Edge[]).map((e) => (
          <path key={e} d={pathD(l, e)} className="edge" stroke={EDGES[e].color} />
        ))}

        <Node l={l} k="lasna" hot={hot.has('lasna')} color="var(--lasna)" title="REACTIVE · LASNA" lines={[`trades ${r ? r.trades.toString() : '…'}`, `${r ? formatUnits(r.balance, 18, 2) : '…'} lREACT`, r?.paused ? 'PAUSED' : 'watching both pools']} big />
        <Node l={l} k="execBase" hot={hot.has('execBase')} color="var(--base)" title="EXECUTOR · BASE" lines={[r ? `${usdc(r.sides[0].usdc)} USDC` : '…', r ? `${tok(r.sides[0].token)} ${TOKEN_SYMBOL}` : '…']} />
        <Node l={l} k="execUni" hot={hot.has('execUni')} color="var(--uni)" title="EXECUTOR · UNICHAIN" lines={[r ? `${usdc(r.sides[1].usdc)} USDC` : '…', r ? `${tok(r.sides[1].token)} ${TOKEN_SYMBOL}` : '…']} />
        <Node l={l} k="poolBase" hot={hot.has('poolBase')} color="var(--base)" title="POOL · BASE" lines={[pb && Number.isFinite(pb.price) ? `${pb.price.toFixed(7)}` : '…', pb ? `tick ${pb.tick}` : '…']} />
        <Node l={l} k="poolUni" hot={hot.has('poolUni')} color="var(--uni)" title="POOL · UNICHAIN" lines={[pu && Number.isFinite(pu.price) ? `${pu.price.toFixed(7)}` : '…', pu ? `tick ${pu.tick}` : '…']} />
        <text x={l.nodes.mktBase.x} y={l.nodes.mktBase.y - 10} className="mkt" textAnchor="start">market</text>
        <text x={l.nodes.mktUni.x} y={l.nodes.mktUni.y - 10} className="mkt" textAnchor="end">market</text>

        {active.map(({ p, t }) => {
          const pt = at(l, p.edge, t)
          const trail = [0.06, 0.12, 0.18].map((d) => at(l, p.edge, Math.max(0, t - d)))
          return (
            <g key={p.id} className="particle">
              {trail.map((q, i) => (
                <circle key={i} cx={q.x} cy={q.y} r={4 - i} fill={EDGES[p.edge].color} opacity={0.5 - i * 0.15} />
              ))}
              <circle cx={pt.x} cy={pt.y} r={5.5} fill={EDGES[p.edge].color} />
              <text x={pt.x + 12} y={pt.y - 10} className="plabel">{p.label}</text>
            </g>
          )
        })}

        {profitOn && (
          <g className="profit-pop">
            <text x={l.nodes.lasna.x} y={l.nodes.lasna.y + (narrow ? 118 : 108)} textAnchor="middle" className="profit-text">
              {replay.profit} USDC
            </text>
          </g>
        )}
      </svg>

      <div className="steps-head">REPLAY · {heading.title}, from its real transactions</div>
      <ol className="steps">
        {replay.steps.map((s, i) => (
          <li key={s.tx} className={i === step ? 'on' : i < step ? 'done' : ''}>
            <span className="step-t">{s.real}</span>
            <span className="step-l">
              <b>{s.label}</b>
              <span>{s.detail}</span>
            </span>
            <TxLink chain={s.chain} hash={s.tx} />
          </li>
        ))}
        {replay.profit !== null && (
          <li className={profitOn ? 'on profit' : 'profit'}>
            <span className="step-t">{replay.profitReal}</span>
            <span className="step-l">
              <b>Profit {replay.profit} USDC</b>
              <span>USDC received on the sell leg minus USDC paid on the buy leg</span>
            </span>
            <span className="tx-dim">both legs</span>
          </li>
        )}
      </ol>
    </div>
  )
}

function Node({ l, k, hot, color, title, lines, big }: { l: Layout; k: NodeKey; hot: boolean; color: string; title: string; lines: string[]; big?: boolean }) {
  const p = l.nodes[k]
  const narrow = l.w < 600
  const w = big ? (narrow ? 220 : 300) : narrow ? 170 : 250
  const h = big ? (narrow ? 92 : 108) : narrow ? 70 : 86
  const lh = narrow ? 19 : 23
  return (
    <g className={hot ? 'node hot' : 'node'} transform={`translate(${p.x - w / 2} ${p.y - h / 2})`}>
      <rect width={w} height={h} rx={4} stroke={color} />
      <rect width={4} height={h} fill={color} />
      <text x={16} y={narrow ? 22 : 26} className={narrow ? 'ntitle ntitle-s' : 'ntitle'} fill={color}>{title}</text>
      {lines.map((t, i) => (
        <text key={i} x={16} y={(narrow ? 44 : 52) + i * lh} className={narrow ? 'nline' : 'nline nline-l'}>{t}</text>
      ))}
    </g>
  )
}
