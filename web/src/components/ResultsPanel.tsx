import { formatUnits } from '../chain/math'
import { CHAINS, SIDES, TOKEN_DECIMALS, TOKEN_SYMBOL, USDC_DECIMALS } from '../config/testnet'
import data from '../data/latency.json'

interface ResultsJson {
  trades: number
  complete: number
  oneLeg: number
  realizedUsdc: string
  tokenDrift: string
  sides: [{ usdc: string; token: string }, { usdc: string; token: string }]
}

const report = data as unknown as { measuredAt: string; results?: ResultsJson }

const big = (v: string) => (/^-?\d+$/.test(v) ? BigInt(v) : 0n)
const signed = (v: bigint, decimals: number, shown: number) => `${v > 0n ? '+' : ''}${formatUnits(v, decimals, shown)}`

export function ResultsPanel() {
  const r = report.results
  // a report written before the results existed has nothing to show
  if (!r) return null
  const date = report.measuredAt.slice(0, 10)

  return (
    <section className="latency results" aria-label="Trading results">
      <div className="lat-head">
        <span>RESULTS</span>
        <span className="tape-sub">
          every executed leg of the {r.trades === 1 ? '1 trade' : `${r.trades} trades`} on chain as of {date}, from the Executors&apos; LegExecuted events
        </span>
      </div>
      <div className="lat-figs">
        <div className="lat-fig">
          <div className="lat-num res-num">
            {signed(big(r.realizedUsdc), USDC_DECIMALS, 6)} <small>USDC</small>
          </div>
          <div className="lat-label">realized profit</div>
          <div className="lat-sub">
            {r.complete === 1 ? '1 complete trade' : `${r.complete} complete trades`}, after both pool fees, before gas and Reactive fees
          </div>
        </div>
        <div className="lat-fig">
          <div className="lat-num res-num res-drift">
            {signed(big(r.tokenDrift), TOKEN_DECIMALS, 4)} <small>{TOKEN_SYMBOL}</small>
          </div>
          <div className="lat-label">{TOKEN_SYMBOL} left over or short</div>
          <div className="lat-sub">a buy and its sell never match to the last unit</div>
        </div>
      </div>
      <dl className="lat-legs res-sides">
        {SIDES.map((s) => (
          <div key={s.side}>
            <dt>Executor · {CHAINS[s.chain].name}</dt>
            <dd>
              <span>{signed(big(r.sides[s.side].usdc), USDC_DECIMALS, 6)} USDC</span>
              <span>{signed(big(r.sides[s.side].token), TOKEN_DECIMALS, 4)} {TOKEN_SYMBOL}</span>
            </dd>
          </div>
        ))}
      </dl>
      <p className="lat-note">
        Change of each Executor&apos;s balances since the deployment, from its own legs only: a buy spends USDC and gains{' '}
        {TOKEN_SYMBOL}, a sell does the opposite.
        {r.oneLeg > 0 ? ` ${r.oneLeg === 1 ? '1 trade' : `${r.oneLeg} trades`} executed only one leg: counted in the balances, not in the profit.` : ''}
      </p>
    </section>
  )
}
