import { useEffect, useRef, useState } from 'react'
import type { FeedState } from '../chain/feed'
import { feeFloor, spread } from '../chain/math'
import { RC_STATE_LABEL, rcState } from '../chain/rcState'
import { TOKEN_SYMBOL } from '../config/testnet'
import { useClock } from './useClock'

/** Digits that changed since the last value flash for a moment. */
function Ticker({ value, digits }: { value: number | undefined; digits: number }) {
  const text = value === undefined || !Number.isFinite(value) ? null : value.toFixed(digits)
  const prev = useRef<string | null>(null)
  const [changed, setChanged] = useState<boolean[]>([])
  const [dir, setDir] = useState<'up' | 'down' | null>(null)

  useEffect(() => {
    if (text === null) return
    const p = prev.current
    if (p !== null && p !== text) {
      setChanged(text.split('').map((c, i) => c !== p[i]))
      setDir(Number(text) > Number(p) ? 'up' : 'down')
      const id = setTimeout(() => setChanged([]), 1200)
      prev.current = text
      return () => clearTimeout(id)
    }
    prev.current = text
  }, [text])

  if (text === null) return <span className="ticker ticker-wait">0.0000000</span>
  return (
    <span className={`ticker ${dir ?? ''}`}>
      {text.split('').map((c, i) => (
        <span key={i} className={changed[i] ? 'flash' : undefined}>{c}</span>
      ))}
    </span>
  )
}

export function PriceDuel({ feed }: { feed: FeedState }) {
  const a = feed.pools[0]
  const b = feed.pools[1]
  const now = Math.floor(useClock(1000) / 1000)
  const raw = a && b ? spread(a.price, b.price) : undefined
  // an uninitialized pool gives no price: show nothing rather than NaN
  const s = raw !== undefined && Number.isFinite(raw) ? raw : undefined
  const st = feed.reactive ? rcState(feed.reactive, now) : null
  const floor = a && b ? feeFloor(a.fee, b.fee) : undefined
  const dearer = a && b ? (a.price > b.price ? 'Base' : b.price > a.price ? 'Unichain' : null) : null
  // the gauge spans 0 to 3x the fee floor so the floor sits at a third
  const span = floor ? floor * 3 : 0.003
  const fill = s !== undefined ? Math.min(1, s / span) : 0
  const above = s !== undefined && floor !== undefined && s > floor

  return (
    <section className="duel" aria-label="Live HUNT price on each chain">
      <div className="duel-side duel-base">
        <div className="duel-label"><i className="dot dot-base" />BASE SEPOLIA</div>
        <div className="duel-price"><Ticker value={a?.price} digits={7} /></div>
        <div className="duel-unit">USDC per {TOKEN_SYMBOL}</div>
        <div className="duel-raw">sqrtPriceX96 {a ? a.sqrtPriceX96.toString() : '…'}</div>
      </div>

      <div className="duel-mid">
        <div className="duel-label">SPREAD</div>
        <div className={above ? 'spread-num above' : 'spread-num'}>
          {s !== undefined ? `${(s * 100).toFixed(4)}%` : '…'}
        </div>
        <div className="gauge" role="meter" aria-valuemin={0} aria-valuemax={span * 100} aria-valuenow={s !== undefined ? s * 100 : 0} aria-label="Spread against the fee floor">
          <div className="gauge-fill" style={{ transform: `scaleX(${fill})` }} />
          <div className="gauge-floor" style={{ left: `${(1 / 3) * 100}%` }} />
        </div>
        <div className="duel-floor">
          {floor !== undefined ? `pool fees take ${(floor * 100).toFixed(4)}%` : 'reading pool fees…'}
          {dearer && s !== undefined && s > 0 ? <span> · dearer on {dearer}</span> : null}
        </div>
        <div className="duel-verdict">
          {s === undefined
            ? 'reading both pool prices'
            : above
              ? st === 'armed'
                ? 'above the fees: the next swap can start a trade if the profit beats the minimum'
                : `above the fees, but the contract is ${st ? RC_STATE_LABEL[st] : 'still loading'}`
              : 'below the fees: nothing to take'}
        </div>
      </div>

      <div className="duel-side duel-uni">
        <div className="duel-label"><i className="dot dot-uni" />UNICHAIN SEPOLIA</div>
        <div className="duel-price"><Ticker value={b?.price} digits={7} /></div>
        <div className="duel-unit">USDC per {TOKEN_SYMBOL}</div>
        <div className="duel-raw">sqrtPriceX96 {b ? b.sqrtPriceX96.toString() : '…'}</div>
      </div>
    </section>
  )
}
