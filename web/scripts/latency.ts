// Measures every SpreadHunter trade on chain, from the swap that started it to both legs, and writes a JSON summary.
// Usage: pnpm latency [output.json]   (default: src/data/latency.json, which the dashboard shows)
import { writeFileSync } from 'node:fs'
import { createClient, http } from 'viem'
import { getBlockNumber } from 'viem/actions'
import { latencyOf, stats, traceTrades, type Clients, type TradeTimeline } from '../src/chain/latency.ts'
import { resultsOf } from '../src/chain/results.ts'
import { CHAINS, REACTIVE_CONTRACT, REACTIVE_DEPLOY_BLOCK } from '../src/config/testnet.ts'

const out = process.argv[2] ?? 'src/data/latency.json'
// the summary covers every trade; the dashboard bundles only the newest timelines
const KEEP_TIMELINES = 20

const client = (url: string) => createClient({ transport: http(url, { batch: true, timeout: 20_000, retryCount: 3 }) })
const clients: Clients = { base: client(CHAINS.base.rpcUrl), unichain: client(CHAINS.unichain.rpcUrl), lasna: client(CHAINS.lasna.rpcUrl) }

const head = await getBlockNumber(clients.lasna)
const trades = await traceTrades(clients, REACTIVE_DEPLOY_BLOCK, head, (m) => process.stderr.write(`  ${m}\n`))
const rows = trades.map((t) => ({ t, l: latencyOf(t) }))

const fmt = (v: number | null) => (v === null ? '  n/a' : `${v >= 0 ? ' ' : ''}${v} s`.padStart(5))
console.log('\nnonce  swap->Lasna*  swap->leg0  swap->leg1  swap->both  request->closed (Lasna clock)  ok')
for (const { l } of rows) {
  const ok = l.ok ? 'yes' : l.pending ? 'in flight' : 'no'
  console.log(`${String(l.nonce).padStart(5)}  ${fmt(l.originToRequestCrossClock).padStart(12)}  ${fmt(l.originToLeg[0]).padStart(10)}  ${fmt(l.originToLeg[1]).padStart(10)}  ${fmt(l.originToLegsDone).padStart(10)}  ${fmt(l.requestToClosed).padStart(29)}  ${ok}`)
}

const done = rows.filter((r) => r.l.ok && r.l.originToLegsDone !== null).map((r) => r.l.originToLegsDone as number)
const closed = rows.filter((r) => r.l.ok && r.l.requestToClosed !== null).map((r) => r.l.requestToClosed as number)
const summary = { swapToBothLegs: stats(done), requestToClosedOnLasna: stats(closed) }
const results = resultsOf(trades)
console.log('realized:', results.realizedUsdc.toString(), 'USDC units from', results.complete, 'complete trades; one leg only:', results.oneLeg)
console.log("\n* subtracts two chains' clocks, so it can come out negative")
console.log('swap -> both legs executed:', summary.swapToBothLegs ?? 'no complete trade yet')
console.log('request -> reactive contract knows the result (Lasna clock):', summary.requestToClosedOnLasna ?? 'no complete trade yet')

const json = {
  measuredAt: new Date().toISOString(),
  reactiveContract: REACTIVE_CONTRACT,
  lasnaBlocks: [REACTIVE_DEPLOY_BLOCK.toString(), head.toString()],
  resolution:
    "differences of whole-second block timestamps, +-1 s. Lasna times are only compared with Lasna times; originToRequestCrossClock subtracts two chains' clocks",
  trades: trades.length,
  failed: rows.filter((r) => !r.l.ok && !r.l.pending).length,
  inFlight: rows.filter((r) => r.l.pending).length,
  summary,
  // every executed leg since the deployment, not only the bundled timelines
  results: toJson(results),
  // newest first
  timelines: rows
    .slice(-KEEP_TIMELINES)
    .reverse()
    .map(({ t, l }) => ({ ...serialize(t), latency: { ...l, nonce: l.nonce.toString() } })),
}
writeFileSync(out, `${JSON.stringify(json, null, 2)}\n`)
console.log(`\nwrote ${out}`)

function toJson(v: unknown) {
  return JSON.parse(JSON.stringify(v, (_k, x: unknown) => (typeof x === 'bigint' ? x.toString() : x))) as Record<string, unknown>
}

function serialize(t: TradeTimeline) {
  return toJson(t)
}
