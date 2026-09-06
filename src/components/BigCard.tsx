import type { Obstacle, Unit } from '../lib/types'
import { reachText } from '../lib/types'
import { artUrl } from '../lib/art'

/** Which edge of the board the card opens against. Yours on the left, theirs
 *  on the right, so a card never covers the rail on its own side. */
export type CardSide = 'left' | 'right'

/** The three slashes from the mark. Same shape as the favicon, drawn small
 *  enough that it reads as a bullet rather than a logo. */
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
 * The card as it is printed: the illustration edge to edge, the name on a
 * white band across the top, the health in a coloured block cut into the
 * corner, and everything you can do with it on bands along the bottom.
 *
 * The board shows a zoomed crop of the same picture; this is the only place
 * the whole illustration is visible, so nothing sits over the middle of it.
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
          <h3>{unit.name}</h3>
          {unit.role && <p>{unit.role}</p>}
        </div>
        <div className="bc-hp">
          <b>{unit.hp}</b><i>/{unit.maxHp}</i>
        </div>
      </div>

      <div className="bc-bottom">
        <div className="bc-band">
          <b>{unit.dmin}–{unit.dmax}</b>
          <span>{unit.heals ? 'PWR' : 'DMG'}</span>
        </div>
        <div className="bc-row">
          <span className="bc-chip"><em>MOV</em><b>{unit.mov}</b></span>
          <span className="bc-chip"><em>RNG</em><b>{reachText(unit.rmin, unit.rmax)}</b></span>
          {unit.burned && <span className="bc-chip bc-chip-burn"><b>BURNING</b></span>}
        </div>
        {unit.ability && (
          <div className="bc-say"><span className="bc-glyph"><Mark /></span><p>{unit.ability}</p></div>
        )}
      </div>
    </aside>
  )
}

/** A tree gets the same card. It has health and a rule, which is all the card
 *  is for -- and reading it is the only way to find out a tree is worth 30 HP
 *  before you have hit one. */
export function TreeBigCard({ tree, side }: { tree: Obstacle; side: CardSide }) {
  return (
    <aside className={`bigcard bigcard-${side} bigcard-tree`}>
      <img className="bc-art" src={`${import.meta.env.BASE_URL}tree.webp`} alt="" />
      <div className="bc-top">
        <div className="bc-id"><h3>Tree</h3><p>Terrain</p></div>
        <div className="bc-hp"><b>{tree.hp}</b><i>/{tree.maxHp}</i></div>
      </div>
      <div className="bc-bottom">
        <div className="bc-row">
          <span className="bc-chip"><em>BLOCKS</em><b>FEET &amp; ARROWS</b></span>
        </div>
        <div className="bc-say">
          <span className="bc-glyph"><Mark /></span>
          <p>Nobody walks through it and nobody shoots past it. Anyone can cut it
             down, and Wuzu simply steps over it.</p>
        </div>
      </div>
    </aside>
  )
}
