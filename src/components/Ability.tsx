import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { readAbility } from '../lib/keywords'

/**
 * An ability sentence, with its vague words in purple and their numbers one
 * pointer away.
 *
 * "Slightly increased parry and crit rates" is the sentence a card should say.
 * "5%->10%" is the thing you need once, while deciding whether to trade. Both
 * on the card at once makes a card nobody reads; neither makes a card nobody
 * can plan with. So the number comes out of the sentence and goes behind the
 * word it qualifies -- see keywords.ts, which reads the marks straight out of
 * the database text rather than keeping a list of vague words in two
 * languages.
 *
 * THE BUBBLE IS A PORTAL, and it has to be. Every place this is used sits
 * inside something that clips: the card's rules strip is line-clamped, the
 * strip under the board is one line with an ellipsis, and both are inside a
 * box with `overflow: hidden`. A tooltip drawn inside any of them is a tooltip
 * with its top cut off. `position: fixed` does not rescue it either -- the
 * card carries a transform, which makes it the containing block for its own
 * fixed descendants, so the clip still applies.
 *
 * `plain` is for the roster grid in My Kingdom. The tile there is itself a
 * <button>, so a button inside it would be invalid and its clicks would be the
 * tile's clicks anyway. There the word is coloured and the number stays in the
 * sentence where it was written -- a browsing view keeps everything visible,
 * and the reading view is the card.
 */
export function Ability({ text, className, plain }: {
  text: string | null | undefined
  className?: string
  plain?: boolean
}) {
  const bits = readAbility(text)
  const [open, setOpen] = useState<{ note: string; x: number; y: number } | null>(null)
  const box = useRef<HTMLSpanElement>(null)

  const show = useCallback((el: HTMLElement, note: string) => {
    const r = el.getBoundingClientRect()
    setOpen({ note, x: r.left + r.width / 2, y: r.top })
  }, [])
  const hide = useCallback(() => setOpen(null), [])

  // A bubble is about a word in a particular place on the screen, and both the
  // word and the screen move. Rather than follow them, it goes. A press
  // anywhere else closes it too, which is the only way out of one opened by a
  // finger -- there is no pointer to take away.
  useEffect(() => {
    if (!open) return
    const away = (e: Event) => {
      if (!(e.target instanceof Node) || !box.current?.contains(e.target)) hide()
    }
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape') hide() }
    document.addEventListener('pointerdown', away, true)
    window.addEventListener('scroll', hide, true)
    window.addEventListener('resize', hide)
    window.addEventListener('keydown', key)
    return () => {
      document.removeEventListener('pointerdown', away, true)
      window.removeEventListener('scroll', hide, true)
      window.removeEventListener('resize', hide)
      window.removeEventListener('keydown', key)
    }
  }, [open, hide])

  if (!text) return null

  return (
    <span className={className} ref={box}>
      {bits.map((b, i) =>
        b.note === undefined ? (
          <span key={i}>{b.text}</span>
        ) : plain ? (
          <span key={i}>
            <b className="kw">{b.text}</b>
            {' ('}<span className="kw-inline">{b.note}</span>{')'}
          </span>
        ) : (
          <button
            key={i} type="button" className="kw"
            aria-expanded={open?.note === b.note}
            /*
             * POINTER EVENTS, NOT MOUSE EVENTS, and the difference is the
             * whole of it.
             *
             * With mouseenter-to-open and click-to-toggle, a tap could never
             * open anything: a tap fires a compatibility mouseenter FIRST, so
             * the bubble was already open by the time the click arrived and
             * the click closed it again. It looked like a flash and it was
             * caught by the browser suite rather than by reading this.
             *
             * Pointer events carry pointerType, so the two inputs can be told
             * apart and given the behaviour each actually has. A mouse hovers
             * and the bubble follows the pointer. A finger cannot hover, so
             * the press decides, and pressing anywhere else closes it -- there
             * is no pointer to take away.
             */
            onPointerEnter={(e) => {
              if (e.pointerType === 'mouse') show(e.currentTarget, b.note!)
            }}
            onPointerLeave={(e) => { if (e.pointerType === 'mouse') hide() }}
            onPointerDown={(e) => {
              if (e.pointerType === 'mouse') return
              if (open?.note === b.note) hide()
              else show(e.currentTarget, b.note!)
            }}
            onFocus={(e) => show(e.currentTarget, b.note!)}
            onBlur={hide}
            // Never decides anything. It is here so that pointing at a word
            // inside a card does not also press the card, and pressing a word
            // on the board does not also put a unit down.
            onClick={(e) => { e.preventDefault(); e.stopPropagation() }}
          >
            {b.text}
            {/* Always there for a screen reader, which has no pointer to
                hover with and no reason to be told about a bubble. */}
            <i className="sr">{` (${b.note})`}</i>
          </button>
        ),
      )}
      {open && !plain && <Bubble note={open.note} x={open.x} y={open.y} />}
    </span>
  )
}

/**
 * Centred over the word, nudged back onto the screen if that put it off.
 *
 * The nudge is written straight to the element rather than held in state, and
 * the measurement is taken with it reset to zero first. Held in state it goes
 * stale: moving from one keyword to the next keeps the component mounted, so
 * the second bubble would be measured through the first one's offset, find
 * itself comfortably on screen, and sit there still wearing it.
 */
function Bubble({ note, x, y }: { note: string; x: number; y: number }) {
  const ref = useRef<HTMLDivElement>(null)

  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    el.style.setProperty('--nudge', '0px')
    const r = el.getBoundingClientRect()
    const over = Math.max(0, r.right - (window.innerWidth - 8)) - Math.max(0, 8 - r.left)
    if (over) el.style.setProperty('--nudge', `${-over}px`)
  }, [note, x, y])

  return createPortal(
    <div ref={ref} className="kwbubble" role="tooltip" style={{ left: x, top: y }}>
      {note}
    </div>,
    document.body,
  )
}
