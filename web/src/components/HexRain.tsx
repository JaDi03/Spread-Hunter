import { useEffect, useRef } from 'react'

interface Drop {
  x: number
  y: number
  speed: number
  text: string
  color: string
}

const FONT_PX = 12
const MAX_DROPS = 80
const FRAME_MS = 33

/** Background of falling hex: block and transaction hashes the page has just read from the chains. */
export function HexRain({ hashes, reducedMotion, visible }: { hashes: string[]; reducedMotion: boolean; visible: boolean }) {
  const ref = useRef<HTMLCanvasElement>(null)
  const pool = useRef<string[]>([])
  useEffect(() => {
    pool.current = hashes
  }, [hashes])

  useEffect(() => {
    const canvas = ref.current
    if (!canvas || reducedMotion || !visible) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return
    let raf = 0
    let w = 0
    let h = 0
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const drops: Drop[] = []
    const palette = ['rgba(35,70,200,', 'rgba(184,18,95,', 'rgba(10,112,56,', 'rgba(20,20,18,']

    const resize = () => {
      w = canvas.clientWidth
      h = canvas.clientHeight
      canvas.width = Math.floor(w * dpr)
      canvas.height = Math.floor(h * dpr)
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    }
    resize()
    const ro = new ResizeObserver(resize)
    ro.observe(canvas)

    const spawn = () => {
      const src = pool.current
      if (src.length === 0) return
      const text = src[Math.floor(Math.random() * Math.min(src.length, 40))].slice(2, 2 + 10 + Math.floor(Math.random() * 18))
      drops.push({
        x: Math.floor((Math.random() * w) / FONT_PX) * FONT_PX,
        y: -text.length * FONT_PX,
        speed: 1.2 + Math.random() * 2.2,
        text,
        color: palette[Math.floor(Math.random() * palette.length)],
      })
    }

    let last = performance.now()
    const frame = (t: number) => {
      if (t - last < FRAME_MS) {
        raf = requestAnimationFrame(frame)
        return
      }
      const dt = Math.min(64, t - last) / 16
      last = t
      ctx.clearRect(0, 0, w, h)
      ctx.font = `${FONT_PX}px "JetBrains Mono", monospace`
      if (drops.length < MAX_DROPS && Math.random() < 0.4) spawn()
      for (let i = drops.length - 1; i >= 0; i--) {
        const d = drops[i]
        d.y += d.speed * dt
        for (let j = 0; j < d.text.length; j++) {
          const yy = d.y + j * FONT_PX
          if (yy < -FONT_PX || yy > h + FONT_PX) continue
          const head = j === d.text.length - 1
          // dark glyphs on paper: kept faint so the map and its labels stay readable
          const a = head ? 0.22 : 0.02 + (j / d.text.length) * 0.08
          ctx.fillStyle = `${d.color}${a})`
          ctx.fillText(d.text[j], d.x, yy)
        }
        if (d.y > h) drops.splice(i, 1)
      }
      raf = requestAnimationFrame(frame)
    }
    raf = requestAnimationFrame(frame)
    return () => {
      cancelAnimationFrame(raf)
      ro.disconnect()
    }
  }, [reducedMotion, visible])

  return <canvas ref={ref} className="rain" aria-hidden="true" />
}
