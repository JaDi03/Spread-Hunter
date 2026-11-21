// Reads every swap of the two pools since the reactive contract went live and writes the price after each one,
// for the spread chart. Reruns only read the blocks after the last run.
// Usage: pnpm swaps [output.json]   (default: src/data/swaps.json)
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { createClient, http, type Client } from 'viem'
import { getBlock, getBlockNumber, getContractEvents, readContract } from 'viem/actions'
import { poolManagerAbi, reactiveAbi } from '../src/chain/abi.ts'
import { BLOCK_SECONDS, blockNear } from '../src/chain/latency.ts'
import { tokenPriceInUsdc } from '../src/chain/math.ts'
import { parseSwapsFile, type ChainSwaps, type PricePoint } from '../src/chain/spreadHistory.ts'
import { CHAINS, REACTIVE_CONTRACT, REACTIVE_DEPLOY_BLOCK, SIDES, TOKEN_DECIMALS, USDC_DECIMALS } from '../src/config/testnet.ts'

const out = process.argv[2] ?? 'src/data/swaps.json'
// one window at a time per chain: Unichain's public RPC rate-limits five parallel eth_getLogs
const PARALLEL = 1

const client = (url: string) => createClient({ transport: http(url, { batch: true, timeout: 20_000, retryCount: 3 }) })

const RATE_LIMITED = -32016
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

/** Retries a call the RPC refused for its rate limit, waiting 2, 4, 8... s; viem does not retry that code. */
async function whenAllowed<T>(call: () => Promise<T>): Promise<T> {
  for (let wait = 2000; ; wait *= 2) {
    try {
      return await call()
    } catch (e) {
      const code = (e as { cause?: { code?: number } }).cause?.code
      if (code !== RATE_LIMITED || wait > 64_000) throw e
      process.stderr.write(`  rate limited, waiting ${wait / 1000} s\n`)
      await sleep(wait)
    }
  }
}
const lasna = client(CHAINS.lasna.rpcUrl)
const previous = existsSync(out) ? parseSwapsFile(JSON.parse(readFileSync(out, 'utf8'))) : null
const deployTs = Number((await getBlock(lasna, { blockNumber: REACTIVE_DEPLOY_BLOCK })).timestamp)

async function readSide(side: 0 | 1): Promise<ChainSwaps> {
  const cfg = SIDES[side]
  const c: Client = client(CHAINS[cfg.chain].rpcUrl)
  const pool = await readContract(lasna, { address: REACTIVE_CONTRACT, abi: reactiveAbi, functionName: 'pool', args: [BigInt(side)] })
  const prev = previous?.[cfg.chain]
  const start = prev ? BigInt(prev.toBlock) + 1n : await blockNear(c, deployTs, BLOCK_SECONDS[cfg.chain])
  const head = await getBlockNumber(c)
  const max = CHAINS[cfg.chain].maxLogRange
  const windows: [bigint, bigint][] = []
  for (let from = start; from <= head; from += max + 1n) windows.push([from, from + max > head ? head : from + max])
  process.stderr.write(`  ${cfg.chain}: blocks ${start}-${head}, ${windows.length} windows\n`)

  const logs = []
  for (let i = 0; i < windows.length; i += PARALLEL) {
    const batch = windows.slice(i, i + PARALLEL)
    const got = await Promise.all(
      batch.map(([from, to]) =>
        whenAllowed(() =>
          getContractEvents(c, { address: cfg.poolManager, abi: poolManagerAbi, eventName: 'Swap', args: { id: cfg.poolId }, fromBlock: from, toBlock: to, strict: true }),
        ),
      ),
    )
    for (const g of got) logs.push(...g)
    if ((i / PARALLEL) % 100 === 0) process.stderr.write(`  ${cfg.chain}: ${i + batch.length}/${windows.length}\n`)
  }

  const times = new Map<bigint, number>()
  for (const bn of new Set(logs.map((l) => l.blockNumber))) times.set(bn, Number((await whenAllowed(() => getBlock(c, { blockNumber: bn }))).timestamp))
  const points: PricePoint[] = logs.map((l) => {
    const price = tokenPriceInUsdc(l.args.sqrtPriceX96, pool.usdcIsCurrency0, USDC_DECIMALS, TOKEN_DECIMALS)
    return [times.get(l.blockNumber) as number, Number(price.toPrecision(8))]
  })
  return { fromBlock: prev?.fromBlock ?? start.toString(), toBlock: head.toString(), points: [...(prev?.points ?? []), ...points] }
}

const [base, unichain] = await Promise.all([readSide(0), readSide(1)])
writeFileSync(out, `${JSON.stringify({ generatedAt: new Date().toISOString(), base, unichain })}\n`)
console.log(`base ${base.points.length} swaps, unichain ${unichain.points.length} swaps; wrote ${out}`)
