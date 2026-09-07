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
const IN_MS = 260     // must match the wipe-in animation in styles.css
const OUT_MS = 300
/* The swap waits a little past the sweep rather than exactly on it. A CSS
   animation does not start on the frame its class is applied -- it starts on
   the next one -- so a swap timed to the millisecond lands a frame early and
   shows a sliver of the old view along the trailing edge. */
const SWAP_MS = IN_MS + 50

export function useWipe() {
  const [phase, setPhase] = useState<'idle' | 'in' | 'out'>('idle')
  const timers = useRef<number[]>([])

  useEffect(() => () => timers.current.forEach(window.clearTimeout), [])

  /**
   * Note what this does NOT do: check prefers-reduced-motion and skip. Asking
   * for less motion is not asking for a screen that changes between one frame
   * and the next -- that is the thing this exists to stop. The block still
   * covers, the swap still happens underneath it; the stylesheet just fades it
   * in place instead of sweeping it across. The timing is the same either way,
   * so there is one code path and not two.
   */
  const cross = useCallback((swap: () => void) => {
    timers.current.forEach(window.clearTimeout)
    timers.current = []
    setPhase('in')
    timers.current.push(
      window.setTimeout(() => { swap(); setPhase('out') }, SWAP_MS),
      window.setTimeout(() => setPhase('idle'), SWAP_MS + OUT_MS),
    )
  }, [])

  const wipe = phase === 'idle' ? null : <div className={`wipe is-${phase}`} aria-hidden="true" />
  return { cross, wipe }
}
