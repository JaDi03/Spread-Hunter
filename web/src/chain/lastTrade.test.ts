import { describe, expect, it } from 'vitest'
import { newestClosed, timelineFromJson } from './lastTrade'
import type { ClosedLog, RequestLog } from './latency'
import { trade1 } from './trade1.fixture'

const req = (nonce: bigint): RequestLog => ({ nonce, cheapSide: 0, tx: trade1.requested.tx, block: 1n, requestedAt: 1n, originTxHash: 1n })
const close: ClosedLog = { tx: trade1.requested.tx, block: 2n, timedOut: false, legFailed: false }

describe('newestClosed', () => {
  it('skips a trade still open and takes the newest closed one', () => {
    const hit = newestClosed([req(5n), req(7n), req(6n)], new Map([[5n, close], [6n, close]]))
    expect(hit?.request.nonce).toBe(6n)
  })

  it('finds nothing when no trade is closed', () => {
    expect(newestClosed([req(1n)], new Map())).toBeNull()
  })
})

describe('timelineFromJson', () => {
  const asJson = (v: unknown) => JSON.parse(JSON.stringify(v, (_k, x: unknown) => (typeof x === 'bigint' ? x.toString() : x))) as unknown

  it('reads back a timeline the latency script wrote', () => {
    expect(timelineFromJson(asJson(trade1))).toEqual(trade1)
  })

  it('rejects a timeline with a bad hash or nonce', () => {
    const bad = asJson(trade1) as Record<string, unknown>
    expect(timelineFromJson({ ...bad, nonce: 'x' })).toBeNull()
    expect(timelineFromJson({ ...bad, requested: { ...(bad.requested as object), tx: 'javascript:1' } })).toBeNull()
  })
})
