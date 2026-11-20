import { describe, expect, it } from 'vitest'
import { liveAt } from './feed'
import { rcState } from './rcState'
import type { ReactiveLive } from './feed'

describe('liveAt', () => {
  const now = 1_700_000_000_000

  it('shows a recent event on the map', () => {
    expect(liveAt('base', false, 1000n, 950n, now)).toBe(now)
    expect(liveAt('lasna', false, 1000n, 985n, now)).toBe(now)
  })

  it('keeps old events read after a pause off the map', () => {
    // a trade 50 minutes old on Lasna, read when the tab comes back
    expect(liveAt('lasna', false, 10_000n, 7_000n, now)).toBe(0)
    expect(liveAt('base', false, 10_000n, 9_800n, now)).toBe(0)
  })

  it('never marks the first read as live', () => {
    expect(liveAt('unichain', true, 1000n, 1000n, now)).toBe(0)
  })
})

const side = { usdc: 1n, token: 1n, stocked: true, priced: true }
const base: ReactiveLive = { sides: [side, side], paused: false, trades: 0n, failuresInARow: 0, cooldownUntil: 0n, balance: 0n, inFlight: false }

describe('rcState', () => {
  it('is armed only when every check the contract makes passes', () => {
    expect(rcState(base, 100)).toBe('armed')
    expect(rcState({ ...base, paused: true }, 100)).toBe('paused')
    expect(rcState({ ...base, cooldownUntil: 200n }, 100)).toBe('cooling')
    expect(rcState({ ...base, inFlight: true }, 100)).toBe('inFlight')
    expect(rcState({ ...base, sides: [{ ...side, priced: false }, side] }, 100)).toBe('noPrice')
    expect(rcState({ ...base, sides: [side, { ...side, stocked: false }] }, 100)).toBe('noInventory')
  })
})
