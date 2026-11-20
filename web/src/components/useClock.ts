import { useEffect, useState } from 'react'

const FRAME_MS = 33

/** Wall-clock milliseconds, refreshed at about 30 frames a second, or every `everyMs` when given. Stops while `paused`. */
export function useClock(everyMs?: number, paused = false) {
  const [now, setNow] = useState(0)
  useEffect(() => {
    if (paused) return
    if (everyMs !== undefined) {
      const tick = () => setNow(Date.now())
      const first = setTimeout(tick, 0)
      const id = setInterval(tick, everyMs)
      return () => {
        clearTimeout(first)
        clearInterval(id)
      }
    }
    let raf = 0
    let last = 0
    const loop = (t: number) => {
      // about 30 frames a second is smooth for this map and halves the render work
      if (t - last >= FRAME_MS) {
        last = t
        setNow(Date.now())
      }
      raf = requestAnimationFrame(loop)
    }
    raf = requestAnimationFrame(loop)
    return () => cancelAnimationFrame(raf)
  }, [everyMs, paused])
  return now
}
