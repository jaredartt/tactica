import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { MatchState, Obstacle, Side, Unit } from '../lib/types'
import { artUrl, faceUrl } from '../lib/art'
import {
  canAct, deployTiles, draw, drawSign, flipFor, key, ownSide, reachable, targetsFor,
  willCounter,
} from '../lib/rules'
import {
  playBurn, playChop, playCounter, playDown, playHit, playMend, playMove, playParry,
  playPlace, playSelect,
} from '../lib/sfx'

// No pixel sizes here on purpose. The board is a CSS grid that fills whatever
// space it is given and keeps its aspect ratio.
const MAX_TILT = 16   // degrees the card leans toward the cursor
const FX_MS = 1300

interface Props {
  state: MatchState
  mySide: Side | null
  isMyTurn: boolean
  deploying: boolean
  selectedId: string | null
  onSelect: (id: string | null) => void
  onMove: (x: number, y: number) => void
  onAttack: (targetId: string) => void
  onDefend: (unitId: string) => void
  /** Close the open go without striking. Takes no unit: the server already
   *  knows which one is mid-go, and asking it is how the two stay agreed. */
  onWait: () => void
  onDeploy: (unitId: string, x: number, y: number) => void
  /** The unit or tree the pointer is over. The card it opens is drawn beside
   *  the board, not inside it, so the board reports and Match renders. */
  onHover: (id: string | null) => void
}

const watching = (side: Side | null) => side === null

interface Blow {
  seq: number
  atk: string
  tgt: string
  dmg: number
  heal: number
  counter: number
  burnAtk: number
  burnTgt: number
  killedTgt: boolean
  killedAtk: boolean
  atkAt: { x: number; y: number }
  tgtAt: { x: number; y: number }
  atkUnit: Unit
  tgtUnit: Unit | null
}

/**
 * What the board is waiting for. Fire Emblem's shape: clicking a unit of yours
 * opens its menu and nothing is lit, and only once you have chosen Move or
 * Attack does the board light up for the thing you chose. Lighting both at
 * once -- which is what this did before -- makes a tile and a target look like
 * alternatives when they are two halves of one go.
 */
type Mode = 'menu' | 'move' | 'attack'

export function Board({
  state, mySide, isMyTurn, deploying, selectedId, onSelect, onMove, onAttack, onDefend,
  onWait, onDeploy, onHover,
}: Props) {
  const { w, h } = state.board
  const trees: Obstacle[] = state.obstacles ?? []
  const selected = state.units.find((u) => u.id === selectedId) ?? null

  // The board turns half a turn for the host, and for nobody else -- see
  // flipFor(), which is where the surprise in that sentence is explained. 0019
  // gave the halves back to the rows, and the whole point of doing the turn in
  // the client is that the database never learns about it: one set of
  // coordinates, two pictures of it. You are always at the bottom, looking up.
  //
  // Every coordinate that reaches the screen goes through draw(), and nothing
  // that reaches the server does. If you find yourself flipping a coordinate
  // anywhere else, it belongs here instead.
  const flip = flipFor(mySide)
  const at = (p: { x: number; y: number }) => {
    const d = draw(p, w, h, flip)
    return ({ gridColumn: d.x + 1, gridRow: d.y + 1 }) as React.CSSProperties
  }

  // A card changes square by changing which grid cell it is in, which is
  // instant and unreadable, so we play the change back: put the card where it
  // used to be and let it travel. Ease-out only -- a piece that starts fast
  // and settles reads as a move, one that starts slow reads as a drag.
  //
  // What moved is decided from the units' OWN coordinates, and the distance
  // from the current tile pitch. Comparing screen rectangles between renders
  // was wrong: the arena is sized from its container, so anything that changes
  // the page height -- the strip under the board growing a line, the away
  // notice appearing, a phone rotating -- shifts every card a few pixels, and
  // the whole army would slide at once for no reason.
  //
  // And nothing legal moves more than two pieces at a time: a turn moves one,
  // a deployment swap moves two. More than that means the board underneath us
  // was replaced -- a rematch reusing the same unit ids, a reconnect, a
  // spectator arriving mid-game -- where the right answer is to appear, not to
  // fly in from wherever a namesake happened to be standing.
  const seats = useRef(new Map<string, { x: number; y: number }>())
  const slots = useRef(new Map<string, HTMLDivElement>())
  useLayoutEffect(() => {
    const live = new Set<string>()
    const moves: { el: HTMLDivElement; dx: number; dy: number }[] = []

    for (const u of state.units) {
      live.add(u.id)
      const was = seats.current.get(u.id)
      seats.current.set(u.id, { x: u.x, y: u.y })
      const el = slots.current.get(u.id)
      if (!el || !was || (was.x === u.x && was.y === u.y)) continue
      // An exchange already owns this element's transform; do not fight it.
      if (el.className.includes('fx-')) continue

      const cell = el.getBoundingClientRect()
      const gs = el.parentElement ? getComputedStyle(el.parentElement) : null
      const gapX = parseFloat(gs?.columnGap ?? '0') || 0
      const gapY = parseFloat(gs?.rowGap ?? '0') || 0
      // Drawn deltas, not board deltas: on a flipped board a step north is
      // played back as a step south, and a piece that travels the wrong way
      // and arrives in the right place reads as a glitch rather than a move.
      const sgn = drawSign(flip)
      moves.push({
        el,
        dx: sgn * (was.x - u.x) * (cell.width + gapX),
        dy: sgn * (was.y - u.y) * (cell.height + gapY),
      })
    }

    if (moves.length <= 2) {
      for (const m of moves) {
        m.el.animate(
          [{ transform: `translate(${m.dx}px, ${m.dy}px)` }, { transform: 'translate(0px, 0px)' }],
          { duration: 240, easing: 'cubic-bezier(0.22, 1, 0.36, 1)' },
        )
      }
      // One sound for the whole change, not one per card: a deployment swap
      // is two cards but a single act. Sounding it here rather than in the
      // click handler means the opponent's move is audible too, and means a
      // move the server refused stays silent.
      if (moves.length) (deploying ? playPlace : playMove)()
    }
    for (const id of [...seats.current.keys()]) if (!live.has(id)) seats.current.delete(id)
  })

  // The board a moment ago. A killed unit is gone from `state.units` by the
  // time we hear about it, so the only place its last position still exists
  // is the previous render's copy.
  const before = useRef<{ units: Unit[]; trees: Obstacle[] }>({ units: state.units, trees })
  const lastSeq = useRef<number>(state.fx?.seq ?? 0)
  const [blow, setBlow] = useState<Blow | null>(null)

  useEffect(() => {
    const fx = state.fx
    const prev = before.current
    before.current = { units: state.units, trees }
    if (!fx || fx.seq === lastSeq.current) return
    lastSeq.current = fx.seq

    const a = prev.units.find((u) => u.id === fx.atk)
    const t = prev.units.find((u) => u.id === fx.tgt)
    const wood = prev.trees.find((o) => o.id === fx.tgt)
    if (!a || (!t && !wood)) return

    setBlow({
      seq: fx.seq, atk: fx.atk, tgt: fx.tgt,
      dmg: fx.dmg ?? 0, heal: fx.heal ?? 0, counter: fx.counter ?? 0,
      burnAtk: fx.burnAtk ?? 0, burnTgt: fx.burnTgt ?? 0,
      killedTgt: fx.killedTgt, killedAtk: fx.killedAtk,
      atkAt: { x: a.x, y: a.y },
      tgtAt: t ? { x: t.x, y: t.y } : { x: wood!.x, y: wood!.y },
      atkUnit: a, tgtUnit: t ?? null,
    })
    // The soundtrack of the exchange, scheduled against the same clock the
    // CSS uses. These are the numbers in styles.css: a lunge takes 0.34s and
    // its victim recoils at 0.12s, the answering lunge starts at 0.38s and
    // lands at 0.5s. Sound that drifts off the picture reads as a bug even
    // when the picture is right, so the delays live next to the animation
    // that earns them -- if one moves, move the other.
    const CONTACT = 0.12
    const ANSWER = 0.5
    const power = (n: number) => n / 28

    if (fx.burnAtk || fx.burnTgt) playBurn(0.02)      // fire eating, before anything swings
    if (fx.heal > 0) playMend(CONTACT)
    else if (fx.tree) playChop(CONTACT)
    else if (fx.dmg > 0) playHit(power(fx.dmg), CONTACT)
    // A tree going over is a second, deeper chop, not a body falling.
    if (fx.killedTgt) (fx.tree ? playChop : playDown)(CONTACT + 0.22)
    if (fx.newBurn) playBurn(CONTACT + 0.22)
    if (fx.counter > 0) (fx.parry ? playParry : playCounter)(power(fx.counter), ANSWER)
    if (fx.killedAtk) playDown(ANSWER + 0.22)

    const id = setTimeout(() => setBlow(null), FX_MS)
    return () => clearTimeout(id)
  }, [state])

  const mine = selected && selected.owner === mySide

  const [mode, setMode] = useState<Mode | null>(null)
  // The menu belongs to the selection, so it dies with it -- including when
  // Match drops the selection because the turn flipped under us.
  useEffect(() => { if (!selectedId) setMode(null) }, [selectedId])

  // Where the selected unit COULD go, and what it COULD hit. Both are computed
  // whether or not the board is currently showing them, because the menu needs
  // to know whether Move and Attack are worth offering before you pick one --
  // an enabled button that does nothing is worse than a greyed one.
  const canMove = Boolean(selected && mine && isMyTurn && !selected.moved && canAct(state, selected))
  const canStrike = Boolean(selected && mine && isMyTurn && !selected.acted && canAct(state, selected))

  const litTiles = useMemo(() => {
    if (!selected || !mine) return new Set<string>()
    if (deploying) return deployTiles(state, mySide!)
    if (!canMove) return new Set<string>()
    return reachable(state, selected)
  }, [state, selected, mine, deploying, canMove, mySide])

  const targets = useMemo(() => {
    if (!selected || !mine || deploying || !canStrike) return new Map()
    return targetsFor(state, selected)
  }, [state, selected, mine, deploying, canStrike])

  // And what the board actually draws. In deployment there is no menu -- you
  // are placing, not activating -- so the tiles are lit the moment you pick
  // something up, exactly as they always were.
  const showTiles = deploying || mode === 'move'
  const showTargets = !deploying && mode === 'attack'
  const shownTiles = showTiles ? litTiles : new Set<string>()
  const shownTargets = showTargets ? targets : new Map()

  // Which way a piece leans when it swings. Drawn direction again, for the
  // same reason the travel above is: half a turn of the board turns a lunge
  // north into a lunge south.
  // Where the menu hangs, in drawn coordinates. Null when there is no menu.
  const menuAt = mode === 'menu' && selected ? draw(selected, w, h, flip) : null

  const lungeVars = (from: { x: number; y: number }, to: { x: number; y: number }) =>
    ({
      '--lx': `${drawSign(flip) * Math.sign(to.x - from.x) * 16}%`,
      '--ly': `${drawSign(flip) * Math.sign(to.y - from.y) * 16}%`,
    }) as React.CSSProperties

  /** Clicking one of yours opens its menu -- unless it has nothing left to
   *  spend, in which case the click still selects it so you can read the card,
   *  it just does not offer you a go it would have to refuse. */
  const opensMenu = (u: Unit) =>
    !deploying && isMyTurn && u.owner === mySide && canAct(state, u) && !state.winner

  function pick(u: Unit) {
    if (u.id !== selectedId) playSelect()
    onSelect(u.id)
    setMode(opensMenu(u) ? 'menu' : null)
  }

  function clickTile(x: number, y: number) {
    if (watching(mySide)) return
    if (deploying) {
      // Placing one ends the placing. Leaving the unit selected left its whole
      // half lit up as if you still had something in your hand, which is only
      // true until you put it down.
      if (selected && mine && shownTiles.has(key(x, y))) { onDeploy(selected.id, x, y); onSelect(null) }
      else onSelect(null)
      return
    }
    // Walking does not end the go: the unit may still strike, and move-then-
    // strike is one activation. So the menu comes straight back, standing
    // where the unit now stands, with Move spent and the rest still there.
    if (shownTiles.has(key(x, y))) { onMove(x, y); setMode('menu') }
    else { onSelect(null); setMode(null) }
  }

  function clickUnit(u: Unit) {
    if (watching(mySide)) return
    if (deploying) {
      // Dropping one of yours onto another of yours swaps the pair.
      if (selected && mine && u.owner === mySide && u.id !== selected.id) {
        onDeploy(selected.id, u.x, u.y)
        onSelect(null)
      } else { if (u.id !== selectedId) playSelect(); onSelect(u.id === selectedId ? null : u.id) }
      return
    }
    // Aiming. Attacking has its own sound a moment later, from the exchange;
    // putting one here as well would double every blow.
    if (shownTargets.has(u.id)) { onAttack(u.id); setMode(null); return }
    // Clicking the open menu's own unit closes it, which is the second way out
    // besides Cancel and the one a thumb finds first.
    if (u.id === selectedId && mode) { setMode(null); return }
    pick(u)
  }

  // The tinted half is always the NEAR one -- which for a player is their own,
  // because the flip has already put them at the bottom. A spectator turns
  // nothing, so the near half of their board is the guest's, and tinting it is
  // the honest reading: it says "this end", not "yours", and there is nothing
  // that is theirs to say.
  const halfSide: Side = mySide ?? 'guest'

  return (
    <div
      className={`board${blow ? ' fx-playing' : ''}${watching(mySide) ? ' is-watching' : ''}`}
      style={{ '--cols': w, '--rows': h } as React.CSSProperties}
      onClick={() => { onSelect(null); setMode(null) }}
    >
      {Array.from({ length: w * h }, (_, i) => {
        const x = i % w
        const y = Math.floor(i / w)
        const k = key(x, y)
        const lit = shownTiles.has(k)
        return (
          <div
            key={k}
            // Explicit placement, not auto-flow: everything else on this grid
            // is placed by coordinate, and CSS grid positions definite items
            // first, so auto-flowed tiles would be pushed off the end.
            style={at({ x, y })}
            className={[
              'tile',
              ownSide(halfSide, y, h) ? 'tile-mine' : 'tile-theirs',
              lit ? (deploying ? 'tile-deploy' : 'tile-move') : '',
            ].join(' ')}
            onClick={(e) => { e.stopPropagation(); clickTile(x, y) }}
          />
        )
      })}

      {/* Where your ground stops. The tint on the tiles says it quietly; this
          says it at a glance, which is what you want while deploying. It sits
          on the far edge of row h/2 whichever way up the board is drawn --
          the flip moves which rows that row is between, not where the seam is
          on the screen, because the seam is always across the middle. */}
      <div
        className="halfline"
        aria-hidden="true"
        style={{ gridColumn: '1 / -1', gridRow: Math.floor(h / 2) + 1 }}
      />

      {trees.map((t) => (
        <Tree
          key={t.id}
          tree={t}
          style={at(t)}
          targetable={shownTargets.has(t.id)}
          shaking={blow?.tgt === t.id}
          falling={blow?.tgt === t.id && blow.killedTgt}
          onHover={(over) => onHover(over ? t.id : null)}
          onClick={(e) => {
            e.stopPropagation()
            if (shownTargets.has(t.id)) { onAttack(t.id); setMode(null) }
            else { onSelect(null); setMode(null) }
          }}
        />
      ))}

      {state.units.map((u) => {
        const striking = blow?.atk === u.id
        const struck = blow?.tgt === u.id
        const target = shownTargets.get(u.id)
        return (
          <UnitCard
            key={u.id}
            unit={u}
            slot={at(u)}
            yours={mySide !== null && u.owner === mySide}
            watching={watching(mySide)}
            selected={u.id === selectedId}
            target={target ? target.kind : null}
            counters={target ? willCounter(selected!, target) : false}
            slotClass={[
              striking ? 'fx-strike' : '',
              struck && !blow?.killedTgt && !blow?.heal ? 'fx-hurt' : '',
              struck && blow!.heal > 0 ? 'fx-mend' : '',
              struck && blow!.counter > 0 ? 'fx-strike-late' : '',
              striking && blow!.counter > 0 && !blow!.killedAtk ? 'fx-hurt-late' : '',
            ].join(' ')}
            slotVars={
              striking && blow
                ? lungeVars(blow.atkAt, blow.tgtAt)
                : struck && blow
                  ? lungeVars(blow.tgtAt, blow.atkAt)
                  : undefined
            }
            onHover={(over) => onHover(over ? u.id : null)}
            slotRef={(el) => { if (el) slots.current.set(u.id, el); else slots.current.delete(u.id) }}
            onClick={(e) => { e.stopPropagation(); clickUnit(u) }}
          />
        )
      })}

      {/* The action menu. Anchored to the tile the unit is standing on and
          drawn over the board rather than beside it, so your eye never leaves
          the piece you are giving an order to.
          It opens away from the nearest edge -- leftward from the right-hand
          columns, upward from the bottom rows -- because .center clips what
          overflows it, and a menu half off the screen is a menu you cannot
          finish using. Those are DRAWN columns, so the rule holds either way
          up the board is turned. */}
      {menuAt && selected && (
        <div className="actmenu-slot" style={at(selected)}>
          <div
            className={[
              'actmenu',
              menuAt.x > (w - 1) / 2 ? 'is-left' : '',
              menuAt.y > (h - 1) / 2 ? 'is-up' : '',
            ].join(' ')}
            role="menu"
            aria-label={`${selected.name} — choose an action`}
            onClick={(e) => e.stopPropagation()}
          >
            <div className="actmenu-head">{selected.name}</div>
            <button
              role="menuitem"
              disabled={!canMove || litTiles.size === 0}
              onClick={() => setMode('move')}
            >
              Move
            </button>
            <button
              role="menuitem"
              disabled={!canStrike || targets.size === 0}
              onClick={() => setMode('attack')}
            >
              {selected.heals ? 'Strike / Mend' : 'Attack'}
            </button>
            {/* Kept in the menu, and kept off. Every unit's ability is written
                on its card already, and leaving the slot out until Phase C
                would move the other four items under the player's thumb on the
                day it lands. */}
            <button role="menuitem" disabled title="Abilities are not built yet.">
              Ability
            </button>
            <button
              role="menuitem"
              disabled={!canStrike}
              title="Halves what lands on this unit until its next turn."
              onClick={() => { onDefend(selected.id); setMode(null) }}
            >
              Defend
            </button>
            {/* Only for the unit that is already mid-go. For anyone else there
                is nothing open to close, and submit_wait would end somebody
                else's go instead -- it takes no unit, it ends whichever one
                the server has open. */}
            {(state.active ?? null) === selected.id && (
              <button role="menuitem" onClick={() => { onWait(); setMode(null) }}>
                Wait
              </button>
            )}
            <button
              role="menuitem"
              className="actmenu-cancel"
              onClick={() => { onSelect(null); setMode(null) }}
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {/* Everything below is transient: it exists only while an exchange plays. */}
      {blow && (
        <>
          {blow.killedTgt && blow.tgtUnit && (
            <div className="unit-ghost" style={at(blow.tgtAt)}>
              <GhostCard unit={blow.tgtUnit} />
            </div>
          )}
          {blow.killedAtk && (
            <div className="unit-ghost unit-ghost-late" style={at(blow.atkAt)}>
              <GhostCard unit={blow.atkUnit} />
            </div>
          )}
          {blow.heal > 0
            ? <div className="dmg dmg-heal" style={at(blow.tgtAt)}>+{blow.heal}</div>
            : <div className="dmg" style={at(blow.tgtAt)}>-{blow.dmg}</div>}
          {blow.counter > 0 && (
            <div className="dmg dmg-late" style={at(blow.atkAt)}>-{blow.counter}</div>
          )}
          {blow.burnTgt > 0 && (
            <div className="dmg dmg-burn dmg-late" style={at(blow.tgtAt)}>-{blow.burnTgt}</div>
          )}
          {blow.burnAtk > 0 && (
            <div className="dmg dmg-burn dmg-late" style={at(blow.atkAt)}>-{blow.burnAtk}</div>
          )}
        </>
      )}
    </div>
  )
}

/** A tree. A crop of the painting rather than a glyph, because a tile of
 *  woodland reads as cover at a glance and an icon reads as a piece. */
function Tree({
  tree, style, targetable, shaking, falling, onClick, onHover,
}: {
  tree: Obstacle
  style: React.CSSProperties
  targetable: boolean
  shaking: boolean
  falling: boolean
  onClick: (e: React.MouseEvent) => void
  onHover: (over: boolean) => void
}) {
  const pct = Math.max(0, Math.min(100, (tree.hp / tree.maxHp) * 100))
  return (
    <div className="tree-slot" style={style}>
      <div
        className={['tree', targetable ? 'is-target' : '', shaking ? 'is-hit' : '',
                    falling ? 'is-falling' : ''].join(' ')}
        onClick={onClick}
        onMouseEnter={() => onHover(true)}
        onMouseLeave={() => onHover(false)}
      >
        <img src={`${import.meta.env.BASE_URL}tree.webp`} alt="" />
        {/* An untouched tree shows no bar. Thirty HP is a fact you read off
            the card, not something the board has to shout at you six times. */}
        {pct < 100 && (
          <div className="tree-hp">
            <span style={{ width: `${pct}%` }} />
            <b>{tree.hp}</b>
          </div>
        )}
      </div>
    </div>
  )
}

/** The zoomed crop, falling back to the whole illustration if the crop is
 *  not there. onError fires once and then the src is the full picture, so
 *  this cannot loop. */
function Portrait({ unit }: { unit: Unit }) {
  return (
    <img
      src={faceUrl(unit.art)!}
      alt=""
      onError={(e) => {
        const el = e.currentTarget
        const full = artUrl(unit.art)
        if (full && el.src !== full) el.src = full
      }}
    />
  )
}

function GhostCard({ unit }: { unit: Unit }) {
  return (
    <div className={`unit unit-ghost-card ${unit.owner === 'host' ? 'unit-host' : 'unit-guest'}`}
         style={{ '--accent': unit.accent } as React.CSSProperties}>
      <div className="unit-face">
        <div className="unit-art">
          {unit.art ? <Portrait unit={unit} /> : <span className="unit-initial">{unit.name[0]}</span>}
        </div>
      </div>
    </div>
  )
}

function UnitCard({
  unit, slot, yours, watching, selected, target, counters, slotClass, slotVars, onClick, onHover,
  slotRef,
}: {
  unit: Unit
  slot: React.CSSProperties
  yours: boolean
  watching: boolean
  selected: boolean
  target: 'foe' | 'ally' | 'tree' | null
  counters: boolean
  slotClass: string
  slotVars?: React.CSSProperties
  onClick: (e: React.MouseEvent) => void
  onHover: (over: boolean) => void
  slotRef: (el: HTMLDivElement | null) => void
}) {
  const hpPct = Math.max(0, Math.min(100, (unit.hp / unit.maxHp) * 100))

  // The piece on the board no longer leans toward the pointer -- it holds
  // still and only lifts, because a token that tips while you are trying to
  // read the art is the art losing. The movement moved to the big card
  // opening beside the board, which still takes its angles from here: the
  // arena's --brx/--bry. Written straight to the DOM rather than held in
  // state, because this fires on every mouse move and re-rendering the board
  // sixty times a second to tilt one card is not a trade worth making.
  function lean(e: React.MouseEvent<HTMLDivElement>) {
    const r = e.currentTarget.getBoundingClientRect()
    const px = (e.clientX - r.left) / r.width - 0.5
    const py = (e.clientY - r.top) / r.height - 0.5
    const arena = e.currentTarget.closest('.arena') as HTMLElement | null
    arena?.style.setProperty('--bry', `${(px * MAX_TILT * 2).toFixed(1)}deg`)
    arena?.style.setProperty('--brx', `${(-py * MAX_TILT * 2).toFixed(1)}deg`)
  }
  function settle(e: React.MouseEvent<HTMLDivElement>) {
    const arena = e.currentTarget.closest('.arena') as HTMLElement | null
    arena?.style.setProperty('--bry', '0deg')
    arena?.style.setProperty('--brx', '0deg')
  }

  const portrait = unit.art
    ? <Portrait unit={unit} />
    : <span className="unit-initial">{unit.name[0]}</span>

  return (
    <div ref={slotRef} className={`unit-slot ${slotClass}`.trim()} style={{ ...slot, ...slotVars }}>
      <div
        className={[
          'unit',
          // Colour is the SIDE, never "mine" -- otherwise the guest sees their
          // own units in the host's colour, and a spectator sees both armies
          // as the enemy.
          unit.owner === 'host' ? 'unit-host' : 'unit-guest',
          yours ? 'is-yours' : '',
          watching ? 'is-inert' : '',
          selected ? 'is-selected' : '',
          target ? `is-target is-target-${target}` : '',
          unit.burned ? 'is-burned' : '',
          unit.defending ? 'is-guarding' : '',
          // `spent` is the server's word for "this one has had its go", and it
          // is the honest one now: a unit that moved and chose not to strike
          // is finished for the turn without ever having acted. The old test
          // is kept behind it for a match that was already running when 0019
          // landed and whose units carry no `spent` at all.
          (unit.spent ?? (unit.moved && unit.acted)) ? 'is-spent' : '',
        ].join(' ')}
        style={{ '--accent': unit.accent } as React.CSSProperties}
        onMouseMove={lean}
        onMouseEnter={() => onHover(true)}
        onMouseLeave={(e) => { settle(e); onHover(false) }}
        onClick={onClick}
      >
        {/* On the board a card is its picture and nothing else. The name and
            the numbers are one hover away; what you need at a glance is who it
            is and how much of it is left. */}
        <div className="unit-face">
          <div className="unit-art">{portrait}</div>
          <div className="unit-hpbar">
            <span className="unit-hpfill" style={{ width: `${hpPct}%` }} />
            <b className="unit-hpnum">{unit.hp}</b>
          </div>
        </div>

        {unit.burned && <div className="unit-burn" title="Burning: loses 5 HP whenever it strikes">🔥</div>}
        {unit.defending && (
          <div className="unit-guard" title="Guard up: halves what lands on it until its next turn">🛡</div>
        )}
        {target === 'ally' && <div className="unit-crosshair is-mend" />}
        {target === 'foe' && <div className={`unit-crosshair${counters ? ' is-risky' : ''}`} />}
      </div>
    </div>
  )
}
