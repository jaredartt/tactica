import { useEffect, useMemo, useRef, useState } from 'react'
import type { MatchState, Obstacle, Side, Unit } from '../lib/types'
import { reachText } from '../lib/types'
import { deployTiles, key, ownHalf, reachable, targetsFor, willCounter } from '../lib/rules'

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
  state, mySide, isMyTurn, deploying, selectedId, onSelect, onMove, onAttack, onDeploy,
}: Props) {
  const { w, h } = state.board
  const trees: Obstacle[] = state.obstacles ?? []
  const selected = state.units.find((u) => u.id === selectedId) ?? null

  // Both players look at their own half from the bottom, so the guest's board
  // is the canonical one turned half a circle. A rotation, not a mirror --
  // reflecting would swap left and right and make every diagonal read wrong.
  const flip = mySide === 'guest'
  const vx = (x: number) => (flip ? w - 1 - x : x)
  const vy = (y: number) => (flip ? h - 1 - y : y)
  const at = (p: { x: number; y: number }) =>
    ({ gridColumn: vx(p.x) + 1, gridRow: vy(p.y) + 1 }) as React.CSSProperties

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
      '--lx': `${Math.sign(vx(to.x) - vx(from.x)) * 16}%`,
      '--ly': `${Math.sign(vy(to.y) - vy(from.y)) * 16}%`,
    }) as React.CSSProperties

  function clickTile(x: number, y: number) {
    if (watching(mySide)) return
    if (deploying) {
      if (selected && mine && litTiles.has(key(x, y))) onDeploy(selected.id, x, y)
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
      if (selected && mine && u.owner === mySide && u.id !== selected.id) onDeploy(selected.id, u.x, u.y)
      else onSelect(u.id === selectedId ? null : u.id)
      return
    }
    if (targets.has(u.id)) onAttack(u.id)
    else onSelect(u.id === selectedId ? null : u.id)
  }

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
              ownHalf(halfSide, y, h) ? 'tile-mine' : 'tile-theirs',
              lit ? (deploying ? 'tile-deploy' : 'tile-move') : '',
            ].join(' ')}
            onClick={(e) => { e.stopPropagation(); clickTile(x, y) }}
          >
            {lit && <span className="tile-dot" />}
          </div>
        )
      })}

      {/* Where your ground stops. The tint on the tiles says it quietly; this
          says it at a glance, which is what you want while deploying. */}
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
          targetable={targets.has(t.id)}
          shaking={blow?.tgt === t.id}
          falling={blow?.tgt === t.id && blow.killedTgt}
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

/** A tree. Drawn from the same 45-degree geometry as everything else. */
function Tree({
  tree, style, targetable, shaking, falling, onClick,
}: {
  tree: Obstacle
  style: React.CSSProperties
  targetable: boolean
  shaking: boolean
  falling: boolean
  onClick: (e: React.MouseEvent) => void
}) {
  const pct = Math.max(0, Math.min(100, (tree.hp / tree.maxHp) * 100))
  return (
    <div className="tree-slot" style={style}>
      <div
        className={['tree', targetable ? 'is-target' : '', shaking ? 'is-hit' : '',
                    falling ? 'is-falling' : ''].join(' ')}
        onClick={onClick}
        title={`Tree — ${tree.hp}/${tree.maxHp}`}
      >
        <svg viewBox="0 0 32 32" aria-hidden="true">
          <path d="M16 3 27 15H21l5 7h-7v7h-6v-7H6l5-7H5Z" />
        </svg>
        {pct < 100 && <div className="tree-hp"><span style={{ width: `${pct}%` }} /></div>}
      </div>
    </div>
  )
}

function GhostCard({ unit }: { unit: Unit }) {
  return (
    <div className={`unit unit-ghost-card ${unit.owner === 'host' ? 'unit-host' : 'unit-guest'}`}
         style={{ '--accent': unit.accent } as React.CSSProperties}>
      <div className="unit-face">
        <div className="unit-art">
          {unit.art ? <img src={unit.art} alt="" /> : <span className="unit-initial">{unit.name[0]}</span>}
        </div>
        <div className="unit-name">{unit.name}</div>
      </div>
    </div>
  )
}

function UnitCard({
  unit, slot, yours, watching, selected, target, counters, slotClass, slotVars, onClick,
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
}) {
  const hpPct = Math.max(0, Math.min(100, (unit.hp / unit.maxHp) * 100))

  // The card leans toward the pointer. The angles go to CSS variables rather
  // than straight to `transform`, so the lean composes with the hover scale
  // instead of overwriting it.
  function lean(e: React.MouseEvent<HTMLDivElement>) {
    const r = e.currentTarget.getBoundingClientRect()
    const px = (e.clientX - r.left) / r.width - 0.5
    const py = (e.clientY - r.top) / r.height - 0.5
    e.currentTarget.style.setProperty('--ry', `${(px * MAX_TILT * 2).toFixed(1)}deg`)
    e.currentTarget.style.setProperty('--rx', `${(-py * MAX_TILT * 2).toFixed(1)}deg`)
  }
  function settle(e: React.MouseEvent<HTMLDivElement>) {
    e.currentTarget.style.setProperty('--ry', '0deg')
    e.currentTarget.style.setProperty('--rx', '0deg')
  }

  const portrait = unit.art
    ? <img src={unit.art} alt="" />
    : <span className="unit-initial">{unit.name[0]}</span>

  return (
    <div className={`unit-slot ${slotClass}`.trim()} style={{ ...slot, ...slotVars }}>
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
        onMouseLeave={settle}
        onClick={onClick}
      >
        <div className="unit-face">
          <div className="unit-art">{portrait}</div>
          <div className="unit-name">{unit.name}</div>
          <div className="unit-hpbar"><span style={{ width: `${hpPct}%` }} /></div>
        </div>

        {/* Opens on hover, once the card is large enough to read. */}
        <div className="unit-detail">
          <div className="unit-detail-art">{portrait}</div>
          <div className="unit-detail-name">{unit.name}</div>
          <dl className="unit-stats">
            <div><dt>HP</dt><dd>{unit.hp}/{unit.maxHp}</dd></div>
            <div><dt>{unit.heals ? 'PWR' : 'DMG'}</dt><dd>{unit.dmin}–{unit.dmax}</dd></div>
            <div><dt>MOV</dt><dd>{unit.mov}</dd></div>
            <div><dt>RNG</dt><dd>{reachText(unit.rmin, unit.rmax)}</dd></div>
          </dl>
          {unit.ability && <p className="unit-ability">{unit.ability}</p>}
        </div>

        <div className="unit-hp">{unit.hp}</div>
        {unit.burned && <div className="unit-burn" title="Burning: loses 5 HP whenever it strikes">🔥</div>}
        {target === 'ally' && <div className="unit-crosshair is-mend" />}
        {target === 'foe' && <div className={`unit-crosshair${counters ? ' is-risky' : ''}`} />}
      </div>
    </div>
  )
}
