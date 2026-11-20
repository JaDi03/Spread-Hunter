import { useEffect, useState, type RefObject } from 'react'

/** True while the element is on screen, so off-screen animations stop drawing. */
export function useInView(ref: RefObject<Element | null>) {
  const [inView, setInView] = useState(false)
  useEffect(() => {
    const el = ref.current
    if (!el) return
    const io = new IntersectionObserver(([e]) => setInView(e.isIntersecting))
    io.observe(el)
    return () => io.disconnect()
  }, [ref])
  return inView
}
