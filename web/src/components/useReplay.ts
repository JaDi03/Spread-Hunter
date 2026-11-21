import { useEffect, useState } from 'react'
import type { FeedState } from '../chain/feed'
import { findLastTrade, timelineFromJson } from '../chain/lastTrade'
import data from '../data/latency.json'
import { FIRST_REPLAY, replayFrom, type Replay } from '../replay'

// the newest closed trade in the bundled report stands in until the chains answer
const bundled = ((data as { timelines?: unknown[] }).timelines ?? [])
  .map(timelineFromJson)
  .find((t) => t !== null && t.closed !== null)
const START = bundled ? replayFrom(bundled, 'bundled') : FIRST_REPLAY

// the first lookup waits for the feed's opening reads; a failed one is tried again later, twice at most
const LOOKUP_DELAYS_MS = [3000, 5000, 20_000]

/** The trade the map replays: the newest closed one on chain, looked up on load and after each close seen live. */
export function useReplay(feed: FeedState): Replay {
  const [replay, setReplay] = useState(START)
  const closesSeen = feed.events.filter((e) => e.kind === 'closed' && e.at > 0).length

  useEffect(() => {
    let gone = false
    let timer: ReturnType<typeof setTimeout> | undefined
    const attempt = (i: number) => {
      timer = setTimeout(() => {
        findLastTrade()
          .then((t) => {
            if (!gone && t) setReplay((r) => (t.nonce >= r.nonce ? replayFrom(t, 'chain') : r))
          })
          // the public RPCs rate-limit bursts: a few spaced tries, then the replay it already has stays
          .catch(() => {
            if (!gone && i + 1 < LOOKUP_DELAYS_MS.length) attempt(i + 1)
          })
      }, LOOKUP_DELAYS_MS[i])
    }
    attempt(0)
    return () => {
      gone = true
      clearTimeout(timer)
    }
  }, [closesSeen])

  return replay
}
