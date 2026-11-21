import type { FeedState } from '../chain/feed'
import { formatUnits } from '../chain/math'
import { RC_STATE_LABEL, rcState } from '../chain/rcState'
import { CHAINS, REACTIVE_CONTRACT, SIDES, TOKEN_DECIMALS, TOKEN_SYMBOL, USDC_DECIMALS } from '../config/testnet'
import { useClock } from './useClock'

export function Vault({ feed }: { feed: FeedState }) {
  const r = feed.reactive
  const now = Math.floor(useClock(1000) / 1000)
  const st = r ? rcState(r, now) : null

  return (
    <section className="vault" aria-label="Trading balances and reactive contract state">
      <div className="vault-head">
        <span>TRADING BALANCES</span>
        <span className="tape-sub">USDC and HUNT each Executor trades from, as the reactive contract last saw it</span>
      </div>
      {SIDES.map((s) => {
        const seen = r?.sides[s.side]
        const price = feed.pools[s.side]?.price
        const u = seen ? Number(formatUnits(seen.usdc, USDC_DECIMALS, 6).replaceAll(',', '')) : 0
        const tv = seen && price ? Number(formatUnits(seen.token, TOKEN_DECIMALS, 6).replaceAll(',', '')) * price : 0
        const share = u + tv > 0 ? u / (u + tv) : 0.5
        return (
          <div key={s.side} className={`inv inv-${s.chain}`}>
            <div className="inv-row">
              <a href={`${CHAINS[s.chain].explorer}/address/${s.executor}`} target="_blank" rel="noopener noreferrer">{CHAINS[s.chain].name} ↗</a>
              <span className="inv-total">{u + tv > 0 ? `≈ ${(u + tv).toFixed(2)} USDC` : '…'}</span>
            </div>
            <div className="bar" aria-hidden="true">
              <div className="bar-usdc" style={{ transform: `scaleX(${share})` }} />
            </div>
            <div className="inv-row inv-sub">
              <span>{seen ? formatUnits(seen.usdc, USDC_DECIMALS, 2) : '…'} USDC</span>
              <span>{seen ? formatUnits(seen.token, TOKEN_DECIMALS, 2) : '…'} {TOKEN_SYMBOL}</span>
            </div>
          </div>
        )
      })}
      <dl className="rc">
        <div><dt>Trades</dt><dd>{r ? r.trades.toString() : '…'}</dd></div>
        <div><dt>State</dt><dd className={st === 'paused' ? 'bad' : st === 'armed' ? 'ok' : 'warn'}>{st ? RC_STATE_LABEL[st] : '…'}</dd></div>
        <div><dt>Failed in a row</dt><dd>{r ? `${r.failuresInARow} / 3` : '…'}</dd></div>
        <div><dt>Gas left</dt><dd>{r ? `${formatUnits(r.balance, 18, 3)} lREACT` : '…'}</dd></div>
      </dl>
      <a className="rc-link" href={`${CHAINS.lasna.explorer}/address/${REACTIVE_CONTRACT}`} target="_blank" rel="noopener noreferrer">
        Reactive contract on Lasna ↗
      </a>
    </section>
  )
}
