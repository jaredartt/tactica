import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { MatchState, Obstacle, Side, Unit } from '../lib/types'
import { artUrl, faceUrl } from '../lib/art'
import { deployTiles, key, ownSide, reachable, targetsFor, willCounter } from '../lib/rules'
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

export function Board({
  state, mySide, isMyTurn, deploying, selectedId, onSelect, onMove, onAttack, onDeploy, onHover,
}: Props) {
  const { w, h } = state.board
  const trees: Obstacle[] = state.obstacles ?? []
  const selected = state.units.find((u) => u.id === selectedId) ?? null

  // Nothing is rotated or mirrored. The host holds the left, the guest holds
  // the right, and both players -- and anyone watching -- look at the same
  // board with the same square in the same place, so "the tree by your
  // archer" means one thing to both of them. Which units are yours is carried
  // by colour, which is what colour was already doing everywhere else.
  const at = (p: { x: number; y: number }) =>
    ({ gridColumn: p.x + 1, gridRow: p.y + 1 }) as React.CSSProperties

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
      moves.push({
        el,
        dx: (was.x - u.x) * (cell.width + gapX),
        dy: (was.y - u.y) * (cell.height + gapY),
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

  // Where the selected unit may go. In deployment that is your whole half; in
  // battle it is however far it can actually walk.
  const litTiles = useMemo(() => {
    if (!selected || !mine) return new Set<string>()
    if (deploying) return deployTiles(state, mySide!)
    if (!isMyTurn || selected.moved) return new Set<string>()
    return reachable(state, selected)
  }, [state, selected, mine, deploying, isMyTurn, mySide])

  const targets = useMemo(() => {
    if (!selected || !mine || deploying || !isMyTurn || selected.acted) return new Map()
    return targetsFor(state, selected)
  }, [state, selected, mine, deploying, isMyTurn])

  const lungeVars = (from: { x: number; y: number }, to: { x: number; y: number }) =>
    ({
      '--lx': `${Math.sign(to.x - from.x) * 16}%`,
      '--ly': `${Math.sign(to.y - from.y) * 16}%`,
    }) as React.CSSProperties

  function clickTile(x: number, y: number) {
    if (watching(mySide)) return
    if (deploying) {
      // Placing one ends the placing. Leaving the unit selected left its whole
      // half lit up as if you still had something in your hand, which is only
      // true until you put it down.
      if (selected && mine && litTiles.has(key(x, y))) { onDeploy(selected.id, x, y); onSelect(null) }
      else onSelect(null)
      return
    }
    if (litTiles.has(key(x, y))) onMove(x, y)
    else onSelect(null)
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
    // Attacking has its own sound a moment later, from the exchange; putting
    // one here as well would double every blow.
    if (targets.has(u.id)) onAttack(u.id)
    else { if (u.id !== selectedId) playSelect(); onSelect(u.id === selectedId ? null : u.id) }
  }

  // A spectator has no ground of their own, so they get the host's reading --
  // the left is tinted, the right is not -- rather than a board with no
  // orientation at all.
  const halfSide: Side = mySide ?? 'host'

  return (
    <div
      className={`board${blow ? ' fx-playing' : ''}${watching(mySide) ? ' is-watching' : ''}`}
      style={{ '--cols': w, '--rows': h } as React.CSSProperties}
      onClick={() => onSelect(null)}
    >
      {Array.from({ length: w * h }, (_, i) => {
        const x = i % w
        const y = Math.floor(i / w)
        const k = key(x, y)
        const lit = litTiles.has(k)
        return (
          <div
            key={k}
            // Explicit placement, not auto-flow: everything else on this grid
            // is placed by coordinate, and CSS grid positions definite items
            // first, so auto-flowed tiles would be pushed off the end.
            style={at({ x, y })}
            className={[
              'tile',
              ownSide(halfSide, x, w) ? 'tile-mine' : 'tile-theirs',
              lit ? (deploying ? 'tile-deploy' : 'tile-move') : '',
            ].join(' ')}
            onClick={(e) => { e.stopPropagation(); clickTile(x, y) }}
          />
        )
      })}

      {/* Where your ground stops. The tint on the tiles says it quietly; this
          says it at a glance, which is what you want while deploying. */}
      <div
        className="halfline"
        aria-hidden="true"
        style={{ gridRow: '1 / -1', gridColumn: Math.floor(w / 2) + 1 }}
      />

      {trees.map((t) => (
        <Tree
          key={t.id}
          tree={t}
          style={at(t)}
          targetable={targets.has(t.id)}
          shaking={blow?.tgt === t.id}
          falling={blow?.tgt === t.id && blow.killedTgt}
          onHover={(over) => onHover(over ? t.id : null)}
          onClick={(e) => {
            e.stopPropagation()
            if (targets.has(t.id)) onAttack(t.id)
            else onSelect(null)
          }}
        />
      ))}

      {state.units.map((u) => {
        const striking = blow?.atk === u.id
        const struck = blow?.tgt === u.id
        const target = targets.get(u.id)
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
          unit.moved && unit.acted ? 'is-spent' : '',
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
        {target === 'ally' && <div className="unit-crosshair is-mend" />}
        {target === 'foe' && <div className={`unit-crosshair${counters ? ' is-risky' : ''}`} />}
      </div>
    </div>
  )
}
