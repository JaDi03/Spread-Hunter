import { useMemo, useRef } from 'react'
import { useFeed } from './chain/useFeed'
import { FlowMap } from './components/FlowMap'
import { HexRain } from './components/HexRain'
import { LatencyPanel } from './components/LatencyPanel'
import { PriceDuel } from './components/PriceDuel'
import { SpreadChart } from './components/SpreadChart'
import { StatusBar } from './components/StatusBar'
import { Tape } from './components/Tape'
import { useInView } from './components/useInView'
import { useMediaQuery } from './components/useMediaQuery'
import { Vault } from './components/Vault'
import { CHAINS, REACTIVE_CONTRACT, REPO_URL, SIDES } from './config/testnet'
import { REPLAY_STEPS } from './replay'

export default function App() {
  const feed = useFeed()
  const reducedMotion = useMediaQuery('(prefers-reduced-motion: reduce)')
  const mapRef = useRef<HTMLDivElement>(null)
  const mapVisible = useInView(mapRef)
  const rainHashes = useMemo(
    () => [...feed.hashes, ...REPLAY_STEPS.map((s) => s.tx), REACTIVE_CONTRACT, ...SIDES.flatMap((s) => [s.executor, s.poolId])],
    [feed.hashes],
  )

  return (
    <div className="page">
      <header className="top">
        <div className="brand">
          <img className="logo" src="/logo.svg" alt="SpreadHunter" width="177" height="30" />
          <span className="net">TESTNET</span>
        </div>
        <StatusBar feed={feed} />
      </header>

      <section className="intro">
        <h1>
          Same token, two chains, <em>two prices.</em>
          <span className="h1-sub">A reactive contract buys the cheap one and sells the dear one in seconds.</span>
        </h1>
        <p>
          Prices, inventories and events are read live from Base Sepolia, Unichain Sepolia and Reactive Lasna, with no server of ours in between. The replay of the first cycle is marked as such.
        </p>
      </section>

      <PriceDuel feed={feed} />

      <section className="stage">
        <div className="stage-map" ref={mapRef}>
          <HexRain hashes={rainHashes} reducedMotion={reducedMotion} visible={mapVisible} />
          <FlowMap feed={feed} reducedMotion={reducedMotion} visible={mapVisible} />
        </div>
        <Tape feed={feed} />
      </section>

      <LatencyPanel />

      <section className="lower">
        <SpreadChart feed={feed} />
        <Vault feed={feed} />
      </section>

      <section className="how" aria-label="How it works">
        <h2>How a cycle works</h2>
        <ol>
          <li><b>01</b><span>Each chain has an Executor holding USDC and HUNT, trading on one Uniswap V4 pool.</span></li>
          <li><b>02</b><span>The reactive contract on Lasna subscribes to the swaps of both pools and to both inventories.</span></li>
          <li><b>03</b><span>A swap moves one price. The contract sizes the trade that makes the most USDC after both pool fees, capped by the owner's limits and the inventory.</span></li>
          <li><b>04</b><span>If the profit beats the minimum, it sends two callbacks in one reaction: buy on the cheap chain, sell on the dear one. No bridge.</span></li>
        </ol>
      </section>

      <footer className="foot">
        <p>
          HUNT is a test token and the pools were made for this demo: testnets have no pools with real liquidity.
        </p>
        <ul>
          <li><a href={`${CHAINS.lasna.explorer}/address/${REACTIVE_CONTRACT}`} target="_blank" rel="noopener noreferrer">SpreadHunterReactive · Lasna ↗</a></li>
          {SIDES.map((s) => (
            <li key={s.side}><a href={`${CHAINS[s.chain].explorer}/address/${s.executor}`} target="_blank" rel="noopener noreferrer">Executor · {CHAINS[s.chain].name} ↗</a></li>
          ))}
          <li><a href={REPO_URL} target="_blank" rel="noopener noreferrer">Source on GitHub ↗</a></li>
        </ul>
      </footer>
    </div>
  )
}
