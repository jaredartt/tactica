import { useCallback, useEffect, useRef, useState } from 'react'

/**
 * The transition between the menu and a match.
 *
 * Inside the menu, moving between the grid and a page is the tile growing --
 * see Zoom.tsx. Crossing into a match, or back out of it, has no tile to grow
 * from: the two views share nothing, and React swaps one for the other in a
 * single frame, which reads as the screen glitching rather than as going
 * somewhere.
 *
 * So a leaning block sweeps across, the swap happens while it covers the
 * screen, and it carries on out the far side. Same skew as the menu, so the
 * whole app moves in one shape.
 */
const IN_MS = 260
const OUT_MS = 300

export function useWipe() {
  const [phase, setPhase] = useState<'idle' | 'in' | 'out'>('idle')
  const timers = useRef<number[]>([])

  useEffect(() => () => timers.current.forEach(window.clearTimeout), [])

  const cross = useCallback((swap: () => void) => {
    const reduced =
      typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion: reduce)').matches
    if (reduced) { swap(); return }

    timers.current.forEach(window.clearTimeout)
    timers.current = []
    setPhase('in')
    timers.current.push(
      window.setTimeout(() => { swap(); setPhase('out') }, IN_MS),
      window.setTimeout(() => setPhase('idle'), IN_MS + OUT_MS),
    )
  }, [])

  const wipe = phase === 'idle' ? null : <div className={`wipe is-${phase}`} aria-hidden="true" />
  return { cross, wipe }
}
