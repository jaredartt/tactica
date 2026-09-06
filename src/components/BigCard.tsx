import { useLayoutEffect, useRef } from 'react'
import type { Obstacle, Unit } from '../lib/types'
import { reachText } from '../lib/types'
import { artUrl } from '../lib/art'

/** Which edge of the board the card opens against. Yours on the left, theirs
 *  on the right, so a card never covers the rail on its own side. */
export type CardSide = 'left' | 'right'

/** The three slashes from the mark, small enough to read as a bullet. */
function Mark() {
  return (
    <svg className="bc-mark" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M8.6 3 2.6 21h3.6L12.2 3Z" />
      <path d="M14.2 3 8.2 21h3.6L17.8 3Z" />
      <path d="M19.8 3 13.8 21h3.6L23.4 3Z" />
    </svg>
  )
}

/**
 * A name is never truncated -- it is shrunk until it fits.
 *
 * "Dione & Grifo" is twice the width of "Fey" and has to sit beside a block
 * wide enough for 120/120, so no single font size works for both. An ellipsis
 * is the wrong answer for the one place a character's name is written out, so
 * this steps the size down until the text stops overflowing. The card mounts
 * fresh on every hover, so this runs once per card and measures one element.
 */
function FitName({ children }: { children: string }) {
  const ref = useRef<HTMLHeadingElement>(null)
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    let k = 1
    el.style.setProperty('--fit', '1')
    while (el.scrollWidth > el.clientWidth + 0.5 && k > 0.56) {
      k -= 0.04
      el.style.setProperty('--fit', k.toFixed(2))
    }
  })
  return <h3 ref={ref} className="bc-name">{children}</h3>
}

/**
 * The card as it would be printed: the illustration edge to edge, the name on
 * a white band cut into the top left, the health in a coloured block cut into
 * the top right, and one bar of numbers plus one line of rules text along the
 * bottom.
 *
 * Everything here is measured against how much of the picture it hides. The
 * board already shows a zoomed crop; this is the only place the whole
 * illustration is visible, so the middle two thirds of it stay clear.
 */
export function UnitBigCard({ unit, side }: { unit: Unit; side: CardSide }) {
  return (
    <aside
      className={`bigcard bigcard-${side} ${unit.owner === 'host' ? 'unit-host' : 'unit-guest'}`}
      style={{ '--accent': unit.accent } as React.CSSProperties}
    >
      {unit.art && <img className="bc-art" src={artUrl(unit.art)!} alt="" />}
      <div className="bc-top">
        <div className="bc-id">
          <FitName>{unit.name}</FitName>
          {unit.role && <p>{unit.role}</p>}
        </div>
        <div className="bc-hp"><b>{unit.hp}</b><i>/{unit.maxHp}</i></div>
      </div>

      <div className="bc-bottom">
        <div className="bc-stats">
          <span><em>{unit.heals ? 'PWR' : 'DMG'}</em><b>{unit.dmin}–{unit.dmax}</b></span>
          <span><em>MOV</em><b>{unit.mov}</b></span>
          <span><em>RNG</em><b>{reachText(unit.rmin, unit.rmax)}</b></span>
          {unit.burned && <span className="bc-burn"><b>BURNING</b></span>}
        </div>
        {unit.ability && (
          <div className="bc-say"><span className="bc-glyph"><Mark /></span><p>{unit.ability}</p></div>
        )}
      </div>
    </aside>
  )
}

/** A tree gets the same card. It has health and a rule, which is all a card
 *  is for -- and it is the only way to learn a tree is worth 30 before you
 *  have hit one. */
export function TreeBigCard({ tree, side }: { tree: Obstacle; side: CardSide }) {
  return (
    <aside className={`bigcard bigcard-${side} bigcard-tree`}>
      <img className="bc-art" src={`${import.meta.env.BASE_URL}tree.webp`} alt="" />
      <div className="bc-top">
        <div className="bc-id"><FitName>Tree</FitName><p>Terrain</p></div>
        <div className="bc-hp"><b>{tree.hp}</b><i>/{tree.maxHp}</i></div>
      </div>
      <div className="bc-bottom">
        <div className="bc-stats">
          <span><em>BLOCKS</em><b>FEET &amp; ARROWS</b></span>
        </div>
        <div className="bc-say">
          <span className="bc-glyph"><Mark /></span>
          <p>Anyone can cut it down. Wuzu simply steps over it.</p>
        </div>
      </div>
    </aside>
  )
}
