import { createClient, http } from 'viem'
import { getBlockNumber } from 'viem/actions'
import { CHAINS, REACTIVE_DEPLOY_BLOCK, type ChainKey } from '../config/testnet.ts'
import { traceContext, traceTrade, tradeLogs, type ClosedLog, type Clients, type RequestLog, type Stamp, type TradeTimeline } from './latency.ts'
import { isTxHash } from './math.ts'

/** Lasna windows searched back from the head, about 2.7 h each */
export const MAX_WINDOWS = 3

/** The newest trade the reactive contract has closed, with its close. A trade still open is skipped. */
export function newestClosed(requested: readonly RequestLog[], closed: ReadonlyMap<bigint, ClosedLog>) {
  let best: RequestLog | null = null
  for (const r of requested) if (closed.has(r.nonce) && (best === null || r.nonce > best.nonce)) best = r
  return best ? { request: best, close: closed.get(best.nonce) as ClosedLog } : null
}

const client = (url: string) => createClient({ transport: http(url, { batch: true, timeout: 10_000, retryCount: 0 }) })
let clients: Clients | null = null

/** Reads the chains for the newest closed trade; null when none is in the last MAX_WINDOWS windows. */
export async function findLastTrade(): Promise<TradeTimeline | null> {
  clients ??= { base: client(CHAINS.base.rpcUrl), unichain: client(CHAINS.unichain.rpcUrl), lasna: client(CHAINS.lasna.rpcUrl) }
  const c = clients
  const head = await getBlockNumber(c.lasna)
  const max = CHAINS.lasna.maxLogRange
  const requested: RequestLog[] = []
  // a close lands a few blocks after its request, so closes from newer windows are kept for older ones
  const closed = new Map<bigint, ClosedLog>()
  for (let w = 0n, to = head; w < BigInt(MAX_WINDOWS) && to >= REACTIVE_DEPLOY_BLOCK; w++, to -= max + 1n) {
    const from = to - max < REACTIVE_DEPLOY_BLOCK ? REACTIVE_DEPLOY_BLOCK : to - max
    const logs = await tradeLogs(c, from, to)
    requested.push(...logs.requested)
    for (const [n, cl] of logs.closed) closed.set(n, cl)
    const hit = newestClosed(requested, closed)
    if (hit) return traceTrade(c, await traceContext(c, head), hit.request, hit.close)
  }
  return null
}

type Json = Record<string, unknown>
const big = (v: unknown) => (typeof v === 'string' && /^-?\d+$/.test(v) ? BigInt(v) : null)

const CHAIN_KEYS: readonly ChainKey[] = ['base', 'unichain', 'lasna']

function stampOf(v: unknown): Stamp | null {
  const s = v as Json | null
  if (!s || !isTxHash(s.tx) || typeof s.ts !== 'number' || big(s.block) === null) return null
  const chain = CHAIN_KEYS.find((k) => k === s.chain)
  return chain ? { chain, tx: s.tx, block: big(s.block) as bigint, ts: s.ts } : null
}

function amounts<K extends string>(v: unknown, keys: readonly K[]) {
  const o = v as Json | null
  if (!o || typeof o.buyToken !== 'boolean') return null
  const out = { buyToken: o.buyToken } as { buyToken: boolean } & Record<K, bigint>
  for (const k of keys) {
    const b = big(o[k])
    if (b === null) return null
    ;(out as Record<string, unknown>)[k] = b
  }
  return out
}

/** A timeline from the bundled report, or null when it lacks what the replay needs. */
export function timelineFromJson(v: unknown): TradeTimeline | null {
  const t = v as Json | null
  const requested = stampOf(t?.requested)
  const nonce = big(t?.nonce)
  if (!t || !requested || nonce === null || !Array.isArray(t.legs) || t.legs.length !== 2) return null
  const leg = (l: unknown) => {
    const s = stampOf(l)
    if (!s || s.chain === 'lasna') return null
    const ok = (l as Json).ok === true
    return { ...s, ok, fill: ok ? amounts((l as Json).fill, ['paid', 'received'] as const) : null }
  }
  const o = stampOf(t.origin)
  const closed = stampOf(t.closed)
  const c = t.closed as Json | null
  return {
    nonce,
    cheapSide: Number(t.cheapSide),
    origin: o ? { ...o, swap: amounts((t.origin as Json).swap, ['usdc', 'token'] as const) } : null,
    requested,
    legs: [leg(t.legs[0]), leg(t.legs[1])],
    closed: closed && c ? { ...closed, timedOut: c.timedOut === true, legFailed: c.legFailed === true } : null,
    pending: t.pending === true,
  }
}
