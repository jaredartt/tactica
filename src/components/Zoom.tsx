import { useCallback, useEffect, useRef, useState } from 'react'
import { lessMotion } from '../lib/settings'

/**
 * The Smash-menu transition: the tile you pressed grows until it IS the page.
 *
 * A FLIP, not a route change. On the click we take the tile's rectangle, drop
 * a solid block of its own colour exactly over it, and let CSS carry that block
 * out past the edges of the screen. The page mounts underneath with a wash of
 * the same colour already filling it, so the moment the block is removed there
 * is nothing to see -- the wash then shrinks to a header band, and that shrink
 * is what makes it read as arriving somewhere rather than as a panel opening.
 *
 * The block NEVER straightens up. It used to animate its skew back to zero on
 * the way out, which meant the shape you clicked turned into a different shape
 * before it left, and the eye reads that as a pop rather than as a move. It now
 * keeps the menu's lean the whole way and simply grows past the corners -- one
 * scale and one translate, both on the GPU, and no geometry change at all.
 */
export interface ZoomTarget {
  id: string
  tint: string
}

const OUT_MS = 360
const SKEW = -8      // the menu's lean, in degrees; the block keeps it throughout

/**
 * How far this particular tile has to grow to swallow the screen. The 1.6 /
 * 1.5 are slack for the lean and for the corners a skewed rectangle leaves
 * uncovered -- cheaper than the trigonometry, and the block is a flat colour
 * so nobody can tell it overshot. Recomputed on the way back rather than
 * remembered, in case the window changed size while the page was open.
 */
function growFrom(r: DOMRect) {
  const s = Math.max((innerWidth * 1.6) / r.width, (innerHeight * 1.5) / r.height)
  const tx = innerWidth / 2 - (r.left + r.width / 2)
  const ty = innerHeight / 2 - (r.top + r.height / 2)
  return `translate(${tx}px, ${ty}px) scale(${s}) skewX(${SKEW}deg)`
}

export function useZoom() {
  const [rect, setRect] = useState<DOMRect | null>(null)
  const [grow, setGrow] = useState('')
  const [tint, setTint] = useState('#000')
  const [open, setOpen] = useState(false)
  const [page, setPage] = useState<string | null>(null)
  const origin = useRef<DOMRect | null>(null)
  const timer = useRef<number | undefined>(undefined)

  // The setting in Settings, or the one in the operating system. Either.
  const reduced = lessMotion()

  const zoomTo = useCallback(
    (el: HTMLElement, target: ZoomTarget) => {
      const r = el.getBoundingClientRect()
      origin.current = r
      setTint(target.tint)
      if (reduced) {
        setPage(target.id)
        return
      }
      setGrow(growFrom(r))
      setRect(r)
      setOpen(false)
      // one frame at the tile's size, then let the transition do the rest
      requestAnimationFrame(() => requestAnimationFrame(() => setOpen(true)))
      window.clearTimeout(timer.current)
      timer.current = window.setTimeout(() => {
        setPage(target.id)
        setRect(null)
      }, OUT_MS)
    },
    [reduced],
  )

  /**
   * Leaving runs the same move backwards.
   *
   * The block is mounted already at full size -- there is no previous state
   * for it to transition from, so that first frame simply paints -- the page
   * is dropped underneath it in the same commit, and only then does it shrink
   * back into the tile it came out of. Which is why `origin` is kept: the tile
   * itself is unmounted while a page is open, so its rectangle is the only
   * record of where the door was.
   */
  const close = useCallback(() => {
    const r = origin.current
    if (reduced || !r) {
      setPage(null); setRect(null); setOpen(false)
      return
    }
    setGrow(growFrom(r))
    setRect(r)
    setOpen(true)     // painted, not animated: nothing to come from
    setPage(null)
    requestAnimationFrame(() => requestAnimationFrame(() => setOpen(false)))
    window.clearTimeout(timer.current)
    timer.current = window.setTimeout(() => setRect(null), OUT_MS)
  }, [reduced])

  useEffect(() => () => window.clearTimeout(timer.current), [])

  const zoomer = rect ? (
    <div
      className={`zoomer${open ? ' is-open' : ''}`}
      style={{
        left: rect.left, top: rect.top, width: rect.width, height: rect.height,
        background: tint,
        transform: open ? grow : `translate(0px, 0px) scale(1) skewX(${SKEW}deg)`,
      }}
      aria-hidden="true"
    />
  ) : null

  return { zoomTo, close, page, tint, zoomer }
}

/** A menu destination: full bleed, its own colour, and a way back. */
export function Page({
  title, tint, onClose, wide, children,
}: {
  title: string
  tint: string
  onClose: () => void
  /** Edge to edge instead of a reading column. For pages that are pictures. */
  wide?: boolean
  children: React.ReactNode
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  return (
    <section className="page" style={{ '--tint': tint } as React.CSSProperties}>
      <div className="page-wash" aria-hidden="true" />
      <header className="page-head">
        <button className="page-back" onClick={onClose} aria-label="Back to the menu">←</button>
        <h2>{title}</h2>
      </header>
      <div className={`page-body${wide ? ' is-wide' : ''}`}>{children}</div>
    </section>
  )
}
