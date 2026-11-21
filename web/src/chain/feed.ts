import { createClient, http, type Client } from 'viem'
import { getBalance, getBlock, getContractEvents, readContract } from 'viem/actions'
import {
  CHAINS,
  REACTIVE_CONTRACT,
  SIDES,
  TOKEN_DECIMALS,
  USDC_DECIMALS,
  type ChainKey,
} from '../config/testnet'
import { executorAbi, poolManagerAbi, reactiveAbi, stateViewAbi } from './abi'
import { isTxHash, tokenPriceInUsdc } from './math'

export interface ChainStatus {
  block: bigint | null
  blockHash: string | null
  updatedAt: number | null
  latencyMs: number | null
  failing: boolean
}

export interface PoolLive {
  price: number
  sqrtPriceX96: bigint
  tick: number
  fee: number
}

export interface SideSeen {
  usdc: bigint
  token: bigint
  stocked: boolean
  priced: boolean
}

export interface ReactiveLive {
  sides: [SideSeen, SideSeen]
  paused: boolean
  trades: bigint
  failuresInARow: number
  cooldownUntil: bigint
  balance: bigint
  inFlight: boolean
}

export type FeedEvent =
  | { kind: 'swap'; id: string; chain: ChainKey; at: number; tx: `0x${string}`; byBot: boolean; buyToken: boolean; usdc: bigint; token: bigint }
  | { kind: 'trade'; id: string; chain: 'lasna'; at: number; tx: `0x${string}`; nonce: bigint; cheapSide: number; usdcIn: bigint; tokenAmount: bigint; expectedProfit: bigint }
  | { kind: 'closed'; id: string; chain: 'lasna'; at: number; tx: `0x${string}`; nonce: bigint; timedOut: boolean; legFailed: boolean }
  | { kind: 'paused'; id: string; chain: 'lasna'; at: number; tx: `0x${string}`; failures: number }
  | { kind: 'leg'; id: string; chain: ChainKey; at: number; tx: `0x${string}`; buyToken: boolean; paid: bigint; received: bigint }
  | { kind: 'legFailed'; id: string; chain: ChainKey; at: number; tx: `0x${string}` }

export interface PricePoint {
  t: number
  a: number
  b: number
}

export interface FeedState {
  status: Record<ChainKey, ChainStatus>
  pools: [PoolLive | null, PoolLive | null]
  usdcIsCurrency0: [boolean, boolean] | null
  reactive: ReactiveLive | null
  events: FeedEvent[]
  history: PricePoint[]
}

const MAX_EVENTS = 80
const MAX_HISTORY = 360
const MAX_BACKOFF_MS = 60_000
const RPC_TIMEOUT_MS = 10_000

const emptyStatus = (): ChainStatus => ({ block: null, blockHash: null, updatedAt: null, latencyMs: null, failing: false })

let state: FeedState = {
  status: { base: emptyStatus(), unichain: emptyStatus(), lasna: emptyStatus() },
  pools: [null, null],
  usdcIsCurrency0: null,
  reactive: null,
  events: [],
  history: [],
}

const listeners = new Set<() => void>()

function set(patch: (s: FeedState) => FeedState) {
  state = patch(state)
  for (const l of listeners) l()
}

export function subscribe(l: () => void) {
  listeners.add(l)
  if (listeners.size === 1) start()
  return () => {
    listeners.delete(l)
    if (listeners.size === 0) stop()
  }
}

export function getState() {
  return state
}

// bare clients with only the actions used here keep the bundle small (viem tree-shaking)
const clients: Record<ChainKey, Client> = {
  base: createClient({ transport: http(CHAINS.base.rpcUrl, { batch: true, timeout: RPC_TIMEOUT_MS, retryCount: 0 }) }),
  unichain: createClient({ transport: http(CHAINS.unichain.rpcUrl, { batch: true, timeout: RPC_TIMEOUT_MS, retryCount: 0 }) }),
  lasna: createClient({ transport: http(CHAINS.lasna.rpcUrl, { batch: true, timeout: RPC_TIMEOUT_MS, retryCount: 0 }) }),
}

const lastBlock: Record<ChainKey, bigint | null> = { base: null, unichain: null, lasna: null }
const seen = new Set<string>()

function pushEvents(evts: FeedEvent[]) {
  const fresh = evts.filter((e) => !seen.has(e.id))
  if (fresh.length === 0) return
  for (const e of fresh) seen.add(e.id)
  set((s) => ({ ...s, events: [...fresh.reverse(), ...s.events].slice(0, MAX_EVENTS) }))
}


function logRange(key: ChainKey, head: bigint, firstSpan: bigint) {
  const max = CHAINS[key].maxLogRange
  const prev = lastBlock[key]
  let from = prev === null ? head - firstSpan : prev + 1n
  // after a long pause only the newest window is read: older events are skipped
  if (head - from > max) from = head - max
  return { from, to: head }
}

/** Time an event counts as seen on the map: now if its block is within about 20 s of the head, else 0 (tape only). */
export function liveAt(key: ChainKey, firstRead: boolean, head: bigint, logBlock: bigint, now: number) {
  return !firstRead && head - logBlock <= CHAINS[key].liveBlocks ? now : 0
}

function eventId(tx: string, logIndex: number | null) {
  return `${tx}:${logIndex ?? 0}`
}

async function pollSide(i: 0 | 1) {
  const cfg = SIDES[i]
  const key = cfg.chain
  const c = clients[key]
  const t0 = performance.now()
  const block = await getBlock(c, { blockTag: 'latest' })
  const [slot0, swaps, legs, legsFailed] = await Promise.all([
    readContract(c, { address: cfg.stateView, abi: stateViewAbi, functionName: 'getSlot0', args: [cfg.poolId] }),
    ...(() => {
      const { from, to } = logRange(key, block.number, 40n)
      if (from > to) return [Promise.resolve([]), Promise.resolve([]), Promise.resolve([])] as const
      return [
        getContractEvents(c, { address: cfg.poolManager, abi: poolManagerAbi, eventName: 'Swap', args: { id: cfg.poolId }, fromBlock: from, toBlock: to, strict: true }),
        getContractEvents(c, { address: cfg.executor, abi: executorAbi, eventName: 'LegExecuted', fromBlock: from, toBlock: to, strict: true }),
        getContractEvents(c, { address: cfg.executor, abi: executorAbi, eventName: 'LegFailed', fromBlock: from, toBlock: to, strict: true }),
      ] as const
    })(),
  ])
  const latency = performance.now() - t0
  const firstRead = lastBlock[key] === null
  lastBlock[key] = block.number

  const usdc0 = state.usdcIsCurrency0?.[i] ?? true
  const [sqrtPriceX96, tick, , lpFee] = slot0
  const price = tokenPriceInUsdc(sqrtPriceX96, usdc0, USDC_DECIMALS, TOKEN_DECIMALS)
  const now = Date.now()
  const at = (bn: bigint) => liveAt(key, firstRead, block.number, bn, now)

  const evts: FeedEvent[] = []
  for (const l of swaps) {
    if (!isTxHash(l.transactionHash)) continue
    const a0 = l.args.amount0
    const a1 = l.args.amount1
    const usdcDelta = usdc0 ? a0 : a1
    const tokenDelta = usdc0 ? a1 : a0
    evts.push({
      kind: 'swap',
      id: eventId(l.transactionHash, l.logIndex),
      chain: key,
      at: at(l.blockNumber),
      tx: l.transactionHash,
      byBot: l.args.sender.toLowerCase() === cfg.executor.toLowerCase(),
      // the swapper's side of the delta: negative is what it paid into the pool
      buyToken: usdcDelta < 0n,
      usdc: usdcDelta < 0n ? -usdcDelta : usdcDelta,
      token: tokenDelta < 0n ? -tokenDelta : tokenDelta,
    })
  }
  for (const l of legs) {
    if (!isTxHash(l.transactionHash)) continue
    evts.push({ kind: 'leg', id: eventId(l.transactionHash, l.logIndex), chain: key, at: at(l.blockNumber), tx: l.transactionHash, buyToken: l.args.buyToken, paid: l.args.paid, received: l.args.received })
  }
  for (const l of legsFailed) {
    if (!isTxHash(l.transactionHash)) continue
    evts.push({ kind: 'legFailed', id: eventId(l.transactionHash, l.logIndex), chain: key, at: at(l.blockNumber), tx: l.transactionHash })
  }

  set((s) => {
    const pools = [...s.pools] as FeedState['pools']
    pools[i] = { price, sqrtPriceX96, tick, fee: lpFee }
    const a = pools[0]?.price
    const b = pools[1]?.price
    const history = a !== undefined && b !== undefined ? [...s.history, { t: now, a, b }].slice(-MAX_HISTORY) : s.history
    return {
      ...s,
      pools,
      history,
      status: { ...s.status, [key]: { block: block.number, blockHash: block.hash, updatedAt: now, latencyMs: latency, failing: false } },
    }
  })
  pushEvents(evts)
}

let poolsLoaded = false

async function pollLasna() {
  const c = clients.lasna
  const t0 = performance.now()
  const rc = { address: REACTIVE_CONTRACT, abi: reactiveAbi } as const
  if (!poolsLoaded) {
    const [p0, p1] = await Promise.all([
      readContract(c, { ...rc, functionName: 'pool', args: [0n] }),
      readContract(c, { ...rc, functionName: 'pool', args: [1n] }),
    ])
    poolsLoaded = true
    set((s) => ({ ...s, usdcIsCurrency0: [p0.usdcIsCurrency0, p1.usdcIsCurrency0] }))
  }
  const block = await getBlock(c, { blockTag: 'latest' })
  const { from, to } = logRange('lasna', block.number, CHAINS.lasna.maxLogRange)
  const logArgs = { ...rc, fromBlock: from, toBlock: to, strict: true } as const
  const [s0, s1, flight, paused, trades, failures, cooldown, balance, requested, closed, autoPaused] = await Promise.all([
    readContract(c, { ...rc, functionName: 'sideState', args: [0n] }),
    readContract(c, { ...rc, functionName: 'sideState', args: [1n] }),
    readContract(c, { ...rc, functionName: 'flight' }),
    readContract(c, { ...rc, functionName: 'paused' }),
    readContract(c, { ...rc, functionName: 'nonce' }),
    readContract(c, { ...rc, functionName: 'failuresInARow' }),
    readContract(c, { ...rc, functionName: 'cooldownUntil' }),
    getBalance(c, { address: REACTIVE_CONTRACT }),
    from <= to ? getContractEvents(c, { ...logArgs, eventName: 'TradeRequested' }) : Promise.resolve([]),
    from <= to ? getContractEvents(c, { ...logArgs, eventName: 'TradeClosed' }) : Promise.resolve([]),
    from <= to ? getContractEvents(c, { ...logArgs, eventName: 'AutoPaused' }) : Promise.resolve([]),
  ])
  const latency = performance.now() - t0
  const firstRead = lastBlock.lasna === null
  lastBlock.lasna = block.number
  const now = Date.now()
  const at = (bn: bigint) => liveAt('lasna', firstRead, block.number, bn, now)

  const evts: FeedEvent[] = []
  for (const l of requested) {
    if (!isTxHash(l.transactionHash)) continue
    evts.push({
      kind: 'trade',
      id: eventId(l.transactionHash, l.logIndex),
      chain: 'lasna',
      at: at(l.blockNumber),
      tx: l.transactionHash,
      nonce: l.args.nonce,
      cheapSide: l.args.cheapSide,
      usdcIn: l.args.usdcIn,
      tokenAmount: l.args.tokenAmount,
      expectedProfit: l.args.expectedProfit,
    })
  }
  for (const l of closed) {
    if (!isTxHash(l.transactionHash)) continue
    evts.push({ kind: 'closed', id: eventId(l.transactionHash, l.logIndex), chain: 'lasna', at: at(l.blockNumber), tx: l.transactionHash, nonce: l.args.nonce, timedOut: l.args.timedOut, legFailed: l.args.legFailed })
  }
  for (const l of autoPaused) {
    if (!isTxHash(l.transactionHash)) continue
    evts.push({ kind: 'paused', id: eventId(l.transactionHash, l.logIndex), chain: 'lasna', at: at(l.blockNumber), tx: l.transactionHash, failures: l.args.failuresInARow })
  }

  const side = (x: typeof s0): SideSeen => ({ usdc: x.usdc, token: x.token, stocked: x.stocked, priced: x.priced })
  set((s) => ({
    ...s,
    reactive: { sides: [side(s0), side(s1)], paused, trades, failuresInARow: failures, cooldownUntil: cooldown, balance, inFlight: flight.active },
    status: { ...s.status, lasna: { block: block.number, blockHash: block.hash, updatedAt: now, latencyMs: latency, failing: false } },
  }))
  pushEvents(evts)
}

interface Poller {
  timer: ReturnType<typeof setTimeout> | null
  delay: number
  running: boolean
}

const pollers: Record<ChainKey, Poller> = {
  base: { timer: null, delay: CHAINS.base.pollMs, running: false },
  unichain: { timer: null, delay: CHAINS.unichain.pollMs, running: false },
  lasna: { timer: null, delay: CHAINS.lasna.pollMs, running: false },
}

const jobs: Record<ChainKey, () => Promise<void>> = {
  base: () => pollSide(0),
  unichain: () => pollSide(1),
  lasna: pollLasna,
}

let active = false

function schedule(key: ChainKey, ms: number) {
  const p = pollers[key]
  if (p.timer) clearTimeout(p.timer)
  p.timer = setTimeout(() => void tick(key), ms)
}

async function tick(key: ChainKey) {
  const p = pollers[key]
  if (!active || p.running || document.hidden) return
  p.running = true
  try {
    await jobs[key]()
    p.delay = CHAINS[key].pollMs
  } catch {
    // an RPC that fails or rate-limits is asked less often, up to once a minute
    p.delay = Math.min(p.delay * 2, MAX_BACKOFF_MS)
    set((s) => ({ ...s, status: { ...s.status, [key]: { ...s.status[key], failing: true } } }))
  } finally {
    p.running = false
    if (active) schedule(key, p.delay)
  }
}

function onVisibility() {
  if (document.hidden) {
    for (const k of Object.keys(pollers) as ChainKey[]) {
      const t = pollers[k].timer
      if (t) clearTimeout(t)
    }
  } else if (active) {
    for (const k of Object.keys(pollers) as ChainKey[]) schedule(k, 0)
  }
}

function start() {
  active = true
  document.addEventListener('visibilitychange', onVisibility)
  // Lasna first: it says which currency is USDC in each pool
  void tick('lasna').then(() => {
    schedule('base', 0)
    schedule('unichain', 0)
  })
}

function stop() {
  active = false
  document.removeEventListener('visibilitychange', onVisibility)
  for (const k of Object.keys(pollers) as ChainKey[]) {
    const t = pollers[k].timer
    if (t) clearTimeout(t)
  }
}
