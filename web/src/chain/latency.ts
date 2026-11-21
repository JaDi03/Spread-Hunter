import { encodeAbiParameters, keccak256, TransactionReceiptNotFoundError, type Client } from 'viem'
import { getBlock, getBlockNumber, getContractEvents, getTransactionReceipt, readContract } from 'viem/actions'
import { CHAINS, REACTIVE_CONTRACT, SIDES, type ChainKey } from '../config/testnet.ts'
import { executorAbi, reactiveAbi } from './abi.ts'

export interface Stamp {
  chain: ChainKey
  tx: `0x${string}`
  block: bigint
  /** block timestamp, seconds */
  ts: number
}

export interface LegStamp extends Stamp {
  ok: boolean
}

export interface TradeTimeline {
  nonce: bigint
  cheapSide: number
  origin: Stamp | null
  requested: Stamp
  legs: [LegStamp | null, LegStamp | null]
  closed: (Stamp & { timedOut: boolean; legFailed: boolean }) | null
  /** not closed yet and still inside its deadline when the chains were read */
  pending: boolean
}

export interface TradeLatency {
  nonce: bigint
  /** swap to the reactive contract asking for the legs; subtracts two chains' clocks, so it can come out negative */
  originToRequestCrossClock: number | null
  /** swap to each leg on its chain, side 0 then side 1 */
  originToLeg: [number | null, number | null]
  /** swap to the last of the two legs: what a trader feels; Base and Unichain clocks */
  originToLegsDone: number | null
  /** request to the reactive contract knowing how both legs ended, all on Lasna's clock */
  requestToClosed: number | null
  /** both legs executed */
  ok: boolean
  pending: boolean
}

/** Id the reactive contract gives a trade's leg on `side`: keccak256(abi.encode(rc, nonce, side)). */
export function legId(rc: `0x${string}`, nonce: bigint, side: 0 | 1): `0x${string}` {
  return keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }, { type: 'uint256' }], [rc, nonce, BigInt(side)]))
}

export function latencyOf(t: TradeTimeline): TradeLatency {
  const o = t.origin?.ts ?? null
  const since = (ts: number | undefined) => (o === null || ts === undefined ? null : ts - o)
  const legs: [number | null, number | null] = [since(t.legs[0]?.ts), since(t.legs[1]?.ts)]
  const ok = t.legs[0]?.ok === true && t.legs[1]?.ok === true
  // a close by timeout or with a failed leg is not the contract learning both results
  const cleanClose = t.closed !== null && !t.closed.timedOut && !t.closed.legFailed
  return {
    nonce: t.nonce,
    originToRequestCrossClock: since(t.requested.ts),
    originToLeg: legs,
    originToLegsDone: legs[0] !== null && legs[1] !== null ? Math.max(legs[0], legs[1]) : null,
    // Lasna times are only compared with Lasna times: its block clock may not match the other chains'
    requestToClosed: cleanClose && t.closed ? t.closed.ts - t.requested.ts : null,
    ok,
    pending: t.pending,
  }
}

export interface Stats {
  n: number
  min: number
  median: number
  mean: number
  max: number
}

export function stats(values: readonly number[]): Stats | null {
  if (values.length === 0) return null
  const v = [...values].sort((a, b) => a - b)
  const mid = Math.floor(v.length / 2)
  const median = v.length % 2 ? v[mid] : (v[mid - 1] + v[mid]) / 2
  return { n: v.length, min: v[0], median, mean: v.reduce((s, x) => s + x, 0) / v.length, max: v[v.length - 1] }
}

export type Clients = Record<ChainKey, Client>

async function stampOf(c: Client, chain: ChainKey, tx: `0x${string}`, block: bigint): Promise<Stamp> {
  const b = await getBlock(c, { blockNumber: block })
  return { chain, tx, block, ts: Number(b.timestamp) }
}

/** The block on `chain` closest to a timestamp, from the chain's head and its steady block time. */
async function blockNear(c: Client, ts: number, blockSeconds: number): Promise<bigint> {
  const head = await getBlockNumber(c)
  const hb = await getBlock(c, { blockNumber: head })
  let guess = head - BigInt(Math.max(0, Math.round((Number(hb.timestamp) - ts) / blockSeconds)))
  // one correction step: block times drift a little over long spans
  const gb = await getBlock(c, { blockNumber: guess })
  guess += BigInt(Math.round((ts - Number(gb.timestamp)) / blockSeconds))
  return guess < 0n ? 0n : guess > head ? head : guess
}

const BLOCK_SECONDS: Record<'base' | 'unichain', number> = { base: 0.2, unichain: 1 }
/** The contract's MAX_LEG_TIMEOUT and UNLOCK_MARGIN, seconds (SpreadHunterReactive.sol) */
const MAX_LEG_TIMEOUT = 600
const UNLOCK_MARGIN = 60
/** Slack for the clocks of the three chains, seconds */
const CLOCK_SLACK = 60

async function findLeg(clients: Clients, side: 0 | 1, nonce: bigint, fromTs: number, toTs: number): Promise<LegStamp | null> {
  const cfg = SIDES[side]
  const c = clients[cfg.chain]
  const id = legId(REACTIVE_CONTRACT, nonce, side)
  const max = CHAINS[cfg.chain].maxLogRange
  let from = await blockNear(c, fromTs, BLOCK_SECONDS[cfg.chain])
  const end = await blockNear(c, toTs, BLOCK_SECONDS[cfg.chain])
  for (; from <= end; from += max + 1n) {
    const to = from + max > end ? end : from + max
    const range = { address: cfg.executor, abi: executorAbi, fromBlock: from, toBlock: to, strict: true } as const
    const [done, failed] = await Promise.all([
      getContractEvents(c, { ...range, eventName: 'LegExecuted', args: { legId: id } }),
      getContractEvents(c, { ...range, eventName: 'LegFailed', args: { legId: id } }),
    ])
    const hit = done[0] ?? failed[0]
    if (hit) return { ...(await stampOf(c, cfg.chain, hit.transactionHash, hit.blockNumber)), ok: done.length > 0 }
  }
  return null
}

async function findOrigin(clients: Clients, tx: `0x${string}`): Promise<Stamp | null> {
  // only a swap on one of the two pools starts a trade, so the origin is on Base or Unichain
  for (const chain of ['base', 'unichain'] as const) {
    try {
      const r = await getTransactionReceipt(clients[chain], { hash: tx })
      return await stampOf(clients[chain], chain, tx, r.blockNumber)
    } catch (e) {
      // only "no such transaction" means another chain; an RPC failure must stop the run, not hide the trade
      if (!(e instanceof TransactionReceiptNotFoundError)) throw e
    }
  }
  return null
}

/** Every trade the reactive contract requested between two Lasna blocks, with its full timeline. */
export async function traceTrades(clients: Clients, fromBlock: bigint, toBlock: bigint, onProgress?: (msg: string) => void): Promise<TradeTimeline[]> {
  const c = clients.lasna
  const rc = { address: REACTIVE_CONTRACT, abi: reactiveAbi } as const
  const params = await readContract(c, { ...rc, functionName: 'params' })
  const legTimeout = Number(params[3])
  const headTs = Number((await getBlock(c, { blockNumber: toBlock })).timestamp)
  const max = CHAINS.lasna.maxLogRange
  const requested = []
  const closed = new Map<bigint, { tx: `0x${string}`; block: bigint; timedOut: boolean; legFailed: boolean }>()
  for (let from = fromBlock; from <= toBlock; from += max + 1n) {
    const to = from + max > toBlock ? toBlock : from + max
    onProgress?.(`Lasna blocks ${from}-${to}`)
    const range = { ...rc, fromBlock: from, toBlock: to, strict: true } as const
    const [req, clo] = await Promise.all([
      getContractEvents(c, { ...range, eventName: 'TradeRequested' }),
      getContractEvents(c, { ...range, eventName: 'TradeClosed' }),
    ])
    requested.push(...req)
    for (const l of clo) closed.set(l.args.nonce, { tx: l.transactionHash, block: l.blockNumber, timedOut: l.args.timedOut, legFailed: l.args.legFailed })
  }

  const out: TradeTimeline[] = []
  for (const l of requested) {
    const nonce = l.args.nonce
    onProgress?.(`trade #${nonce}`)
    const req: Stamp = { chain: 'lasna', tx: l.transactionHash, block: l.blockNumber, ts: Number(l.args.requestedAt) }
    const originTx = `0x${l.args.originTxHash.toString(16).padStart(64, '0')}` as `0x${string}`
    // legs are searched around the request up to today's leg deadline; a trade made when the owner allowed a
    // longer deadline gets a second search up to the longest one the contract accepts
    const fromTs = req.ts - CLOCK_SLACK
    const toTs = req.ts + legTimeout + CLOCK_SLACK
    const leg = async (side: 0 | 1) =>
      (await findLeg(clients, side, nonce, fromTs, toTs)) ??
      (legTimeout < MAX_LEG_TIMEOUT ? await findLeg(clients, side, nonce, toTs, req.ts + MAX_LEG_TIMEOUT + CLOCK_SLACK) : null)
    const [origin, leg0, leg1] = await Promise.all([findOrigin(clients, originTx), leg(0), leg(1)])
    const cl = closed.get(nonce)
    out.push({
      nonce,
      cheapSide: l.args.cheapSide,
      origin,
      requested: req,
      legs: [leg0, leg1],
      closed: cl ? { ...(await stampOf(c, 'lasna', cl.tx, cl.block)), timedOut: cl.timedOut, legFailed: cl.legFailed } : null,
      // the contract releases a trade at its deadline plus UNLOCK_MARGIN; before that an open trade is in flight
      pending: !cl && req.ts + legTimeout + UNLOCK_MARGIN + CLOCK_SLACK > headTs,
    })
  }
  return out
}
