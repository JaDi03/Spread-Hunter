import { useEffect, useState } from 'react'
import type { FeedState } from '../chain/feed'
import { CHAINS, type ChainKey } from '../config/testnet'

const STALE_MS = 20_000

export function StatusBar({ feed }: { feed: FeedState }) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [])

  return (
    <ul className="status" aria-label="Connection to each chain">
      {(['base', 'lasna', 'unichain'] as ChainKey[]).map((k) => {
        const s = feed.status[k]
        const age = s.updatedAt ? Math.round((now - s.updatedAt) / 1000) : null
        const stale = s.failing || (s.updatedAt !== null && now - s.updatedAt > STALE_MS)
        const label = s.updatedAt === null ? (s.failing ? 'not answering, retrying' : 'connecting') : stale ? `last read ${age}s ago, retrying` : `${Math.round(s.latencyMs ?? 0)} ms`
        return (
          <li key={k} className={`chip chip-${k} ${stale ? 'stale' : s.updatedAt ? 'up' : ''}`}>
            <i aria-hidden="true" />
            <span className="chip-name">{CHAINS[k].name}</span>
            <span className="chip-val">{label}</span>
          </li>
        )
      })}
    </ul>
  )
}
