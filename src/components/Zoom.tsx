import { useCallback, useEffect, useRef, useState } from 'react'

/**
 * The Smash-menu transition: the tile you pressed grows until it IS the page.
 *
 * A FLIP, not a route change. On the click we take the tile's rectangle, drop
 * a solid block of its own colour exactly over it, and let CSS carry that block
 * out to the edges of the screen. The page mounts underneath with a wash of the
 * same colour already filling it, so the moment the block is removed there is
 * nothing to see -- the wash then shrinks to a header band, and that shrink is
 * what makes it read as arriving somewhere rather than as a panel opening.
 */
export interface ZoomTarget {
  id: string
  tint: string
}

const OUT_MS = 340

export function useZoom() {
  const [rect, setRect] = useState<DOMRect | null>(null)
  const [tint, setTint] = useState('#000')
  const [open, setOpen] = useState(false)
  const [page, setPage] = useState<string | null>(null)
  const origin = useRef<DOMRect | null>(null)
  const timer = useRef<number | undefined>(undefined)

  const reduced =
    typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion: reduce)').matches

  const zoomTo = useCallback(
    (el: HTMLElement, target: ZoomTarget) => {
      const r = el.getBoundingClientRect()
      origin.current = r
      setTint(target.tint)
      if (reduced) {
        setPage(target.id)
        return
      }
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

  const close = useCallback(() => {
    setPage(null)
    setRect(null)
    setOpen(false)
  }, [])

  useEffect(() => () => window.clearTimeout(timer.current), [])

  const zoomer = rect ? (
    <div
      className={`zoomer${open ? ' is-open' : ''}`}
      style={{
        left: rect.left, top: rect.top, width: rect.width, height: rect.height,
        background: tint,
      }}
      aria-hidden="true"
    />
  ) : null

  return { zoomTo, close, page, tint, zoomer }
}

/** A menu destination: full bleed, its own colour, and a way back. */
export function Page({
  title, tint, onClose, children,
}: {
  title: string
  tint: string
  onClose: () => void
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
      <div className="page-body">{children}</div>
    </section>
  )
}
