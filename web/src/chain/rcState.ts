import type { ReactiveLive } from './feed'

export type RcState = 'paused' | 'cooling' | 'inFlight' | 'noPrice' | 'noInventory' | 'armed'

export const RC_STATE_LABEL: Record<RcState, string> = {
  paused: 'paused',
  cooling: 'cooling down',
  inFlight: 'trade in flight',
  noPrice: 'waiting for both prices',
  noInventory: 'waiting for both inventories',
  armed: 'armed',
}

/** Whether a swap can start a trade now, with the same checks the reactive contract makes before trading. */
export function rcState(r: ReactiveLive, nowSec: number): RcState {
  if (r.paused) return 'paused'
  if (Number(r.cooldownUntil) > nowSec) return 'cooling'
  if (r.inFlight) return 'inFlight'
  if (!r.sides[0].priced || !r.sides[1].priced) return 'noPrice'
  if (!r.sides[0].stocked || !r.sides[1].stocked) return 'noInventory'
  return 'armed'
}
