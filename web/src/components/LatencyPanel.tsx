import data from '../data/latency.json'
import type { ChainKey } from '../config/testnet'
import { TxLink } from './TxLink'

interface StampJson {
  chain: ChainKey
  tx: string
  ts: number
}

interface TimelineJson {
  nonce: string
  origin: StampJson | null
  requested: StampJson
  legs: [(StampJson & { ok: boolean }) | null, (StampJson & { ok: boolean }) | null]
  closed: (StampJson & { timedOut: boolean; legFailed: boolean }) | null
  latency: { originToLeg: [number | null, number | null]; originToLegsDone: number | null; requestToClosed: number | null; ok: boolean; pending: boolean }
}

interface StatsJson {
  n: number
  min: number
  median: number
  mean: number
  max: number
}

const report = data as unknown as {
  measuredAt: string
  trades: number
  failed: number
  inFlight: number
  summary: { swapToBothLegs: StatsJson | null; requestToClosedOnLasna: StatsJson | null }
  timelines: TimelineJson[]
}

const MIN_RULER_S = 4
const SHOWN = 5

function Figure({ label, s, clock }: { label: string; s: StatsJson | null; clock: string }) {
  return (
    <div className="lat-fig">
      <div className="lat-num">{s ? `${s.median} s` : 'n/a'}</div>
      <div className="lat-label">{label}</div>
      <div className="lat-sub">
        {s ? (s.n === 1 ? `1 trade · ${clock}` : `median of ${s.n} trades · worst ${s.max} s · ${clock}`) : 'no complete trade yet'}
      </div>
    </div>
  )
}

export function LatencyPanel() {
  const date = report.measuredAt.slice(0, 10)
  const shown = report.timelines.slice(0, SHOWN)
  // without the origin swap there is no zero to measure from, so nothing goes on the ruler
  const marks = (t: TimelineJson) =>
    !t.origin
      ? []
      : [
      { key: 'swap', at: 0, label: 'swap', chain: t.origin.chain },
      { key: 'leg0', at: t.latency.originToLeg[0], label: 'buy/sell on Base', chain: 'base' as const },
      { key: 'leg1', at: t.latency.originToLeg[1], label: 'buy/sell on Unichain', chain: 'unichain' as const },
    ].filter((m): m is { key: string; at: number; label: string; chain: ChainKey } => m.at !== null)
  const legText = (t: TimelineJson, side: 0 | 1) => {
    const leg = t.legs[side]
    const at = t.latency.originToLeg[side]
    if (!leg) return t.latency.pending ? 'in flight' : 'not found'
    const when = at === null ? 'time unknown' : `${at} s`
    return leg.ok ? when : `failed, ${when}`
  }
  const status = (t: TimelineJson) =>
    t.latency.ok ? { cls: 'ok', text: 'both legs executed' } : t.latency.pending ? { cls: 'warn', text: 'in flight' } : { cls: 'bad', text: 'a leg failed or is missing' }

  return (
    <section className="latency" aria-label="Measured latency">
      <div className="lat-head">
        <span>MEASURED LATENCY</span>
        <span className="tape-sub">
          {report.trades === 1 ? 'the 1 trade' : `the ${report.trades} trades`} on chain as of {date}, from block timestamps
          {report.trades > shown.length ? `; newest ${shown.length} shown` : ''}
        </span>
      </div>
      <div className="lat-figs">
        <Figure label="from the swap to both legs executed" s={report.summary.swapToBothLegs} clock="Base and Unichain clocks" />
        <Figure label="from the request to the contract knowing both results" s={report.summary.requestToClosedOnLasna} clock="Lasna clock" />
      </div>
      <ul className="lat-rows">
        {shown.map((t) => {
          const ms = marks(t)
          // the ruler grows to fit the slowest leg, and never starts before the swap
          const span = Math.max(MIN_RULER_S, Math.ceil(Math.max(0, ...ms.map((m) => m.at))))
          const pos = (at: number) => `${(Math.max(0, at) / span) * 100}%`
          const st = status(t)
          return (
            <li key={t.nonce}>
              <div className="lat-row-head">
                <b>Trade #{t.nonce}</b>
                <span className={st.cls}>{st.text}</span>
              </div>
              <div className="ruler" aria-hidden="true">
                {Array.from({ length: MIN_RULER_S + 1 }, (_, i) => (
                  <span key={i} className="tick" style={{ left: pos((i * span) / MIN_RULER_S) }}>{Math.round((i * span) / MIN_RULER_S)} s</span>
                ))}
                {ms.map((m) => (
                  <span key={m.key} className={`mark mark-${m.chain}`} style={{ left: pos(m.at) }} title={`${m.label} at ${m.at} s`} />
                ))}
              </div>
              <dl className="lat-legs">
                <div><dt>Swap</dt><dd>{t.origin ? <>0 s <TxLink chain={t.origin.chain} hash={t.origin.tx} /></> : 'not found'}</dd></div>
                <div><dt>Lasna asks for the legs</dt><dd>after the swap, before the legs* <TxLink chain="lasna" hash={t.requested.tx} /></dd></div>
                <div><dt>Leg on Base</dt><dd>{legText(t, 0)} {t.legs[0] ? <TxLink chain="base" hash={t.legs[0].tx} /> : null}</dd></div>
                <div><dt>Leg on Unichain</dt><dd>{legText(t, 1)} {t.legs[1] ? <TxLink chain="unichain" hash={t.legs[1].tx} /> : null}</dd></div>
              </dl>
            </li>
          )
        })}
      </ul>
      <p className="lat-note">
        * Lasna&apos;s block clock can read behind Base and Unichain: in trade #1 its request is stamped a second before the swap that caused it. So Lasna times are compared only with other Lasna times, and every figure is a difference of whole-second block timestamps, accurate to about 1 s.
      </p>
    </section>
  )
}
