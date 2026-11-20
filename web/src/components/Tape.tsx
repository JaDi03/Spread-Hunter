import type { FeedEvent, FeedState } from '../chain/feed'
import { formatUnits } from '../chain/math'
import { CHAINS, TOKEN_DECIMALS, TOKEN_SYMBOL, USDC_DECIMALS } from '../config/testnet'
import { TxLink } from './TxLink'

function describe(e: FeedEvent): { tag: string; text: string; tone: string } {
  switch (e.kind) {
    case 'swap':
      return {
        tag: e.byBot ? 'LEG' : 'SWAP',
        tone: e.byBot ? 'bot' : 'mkt',
        text: e.buyToken
          ? `buy ${formatUnits(e.token, TOKEN_DECIMALS, 2)} ${TOKEN_SYMBOL} for ${formatUnits(e.usdc, USDC_DECIMALS, 2)} USDC`
          : `sell ${formatUnits(e.token, TOKEN_DECIMALS, 2)} ${TOKEN_SYMBOL} for ${formatUnits(e.usdc, USDC_DECIMALS, 2)} USDC`,
      }
    case 'trade':
      return {
        tag: 'TRADE',
        tone: 'trade',
        text: `#${e.nonce} buy on ${e.cheapSide === 0 ? 'Base' : 'Unichain'}, ${formatUnits(e.usdcIn, USDC_DECIMALS, 2)} USDC, expects +${formatUnits(e.expectedProfit, USDC_DECIMALS, 6)}`,
      }
    case 'closed':
      return { tag: 'CLOSED', tone: e.legFailed || e.timedOut ? 'bad' : 'trade', text: `#${e.nonce} ${e.timedOut ? 'timed out' : e.legFailed ? 'a leg failed' : 'both legs done'}` }
    case 'paused':
      return { tag: 'PAUSED', tone: 'bad', text: `after ${e.failures} failed trades in a row` }
    case 'leg':
      return { tag: 'LEG', tone: 'bot', text: `${e.buyToken ? 'bought' : 'sold'}: paid ${formatUnits(e.paid, e.buyToken ? USDC_DECIMALS : TOKEN_DECIMALS, 4)}, got ${formatUnits(e.received, e.buyToken ? TOKEN_DECIMALS : USDC_DECIMALS, 4)}` }
    case 'legFailed':
      return { tag: 'FAILED', tone: 'bad', text: 'leg failed, no funds moved' }
  }
}

export function Tape({ feed }: { feed: FeedState }) {
  const blocks = (['base', 'lasna', 'unichain'] as const).map((k) => ({ k, s: feed.status[k] }))
  return (
    <aside className="tape" aria-label="Events from the three chains">
      <div className="tape-head">
        <span>EVENT TAPE</span>
        <span className="tape-sub">recent swaps, trades and legs on the three chains; Lasna trades go back about 2.5 hours</span>
      </div>
      <div className="tape-blocks">
        {blocks.map(({ k, s }) => (
          <div key={k} className={`tb tb-${k}`}>
            <span>{CHAINS[k].short}</span>
            <b>{s.block !== null ? `#${s.block.toString()}` : '…'}</b>
          </div>
        ))}
      </div>
      <ul className="tape-list" aria-live="polite">
        {feed.events.length === 0 && (
          <li className="tape-empty">
            No swaps on the two pools yet. The bot trades only after someone else moves a price, so this fills up as the market moves.
          </li>
        )}
        {feed.events.map((e) => {
          const d = describe(e)
          return (
            <li key={e.id} className={`ev ev-${d.tone}`}>
              <span className={`ev-chain c-${e.chain}`}>{CHAINS[e.chain].short}</span>
              <span className="ev-tag">{d.tag}</span>
              <span className="ev-text">{d.text}</span>
              <TxLink chain={e.chain} hash={e.tx} />
            </li>
          )
        })}
      </ul>
    </aside>
  )
}
