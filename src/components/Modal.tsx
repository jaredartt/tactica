import { useEffect, useRef } from 'react'
import { IconClose } from './Icons'

/**
 * A panel in the middle of the screen with the app dimmed and blurred behind
 * it. Escape closes it, so does the backdrop, and focus goes into it on open
 * so the keyboard is not left behind on the page underneath.
 */
export function Modal({
  title, onClose, children,
}: {
  title: string
  onClose: () => void
  children: React.ReactNode
}) {
  const box = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', onKey)
    box.current?.focus()
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  return (
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div
        className="modal" role="dialog" aria-modal="true" aria-label={title}
        ref={box} tabIndex={-1}
      >
        <header className="modal-head">
          <h2>{title}</h2>
          <button className="modal-x" onClick={onClose} aria-label="Close">
            <IconClose />
          </button>
        </header>
        {children}
      </div>
    </div>
  )
}
