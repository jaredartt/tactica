import { useEffect, useMemo, useRef, useState } from 'react'
import type { MatchState, Side, Unit } from '../lib/types'

// No pixel sizes here on purpose. The board is a CSS grid that fills whatever
// space it is given and keeps its aspect ratio, so a 5x5 arena fits a phone
// and a monitor without either one measuring anything.
const MAX_TILT = 16   // degrees the card leans toward the cursor
const FX_MS = 1200   // how long an exchange stays on screen (the counter
                     // lands partway through, via CSS animation-delay)

interface Props {
  state: MatchState
  mySide: Side | null
  isMyTurn: boolean
  selectedId: string | null
  onSelect: (id: string | null) => void
  onMove: (x: number, y: number) => void
  onAttack: (targetId: string) => void
}

// A spectator has no side. They may look at anything and touch nothing.
const watching = (side: Side | null) => side === null

const manhattan = (a: { x: number; y: number }, b: { x: number; y: number }) =>
  Math.abs(a.x - b.x) + Math.abs(a.y - b.y)

interface Blow {
  seq: number
  atk: string
  tgt: string
  dmg: number
  counter: number
  killedTgt: boolean
  killedAtk: boolean
  atkAt: { x: number; y: number }
  tgtAt: { x: number; y: number }
  atkUnit: Unit
  tgtUnit: Unit
}

export function Board({ state, mySide, isMyTurn, selectedId, onSelect, onMove, onAttack }: Props) {
  const { w, h } = state.board
  const selected = state.units.find((u) => u.id === selectedId) ?? null

  // The board a moment ago. A killed unit is gone from `state.units` by the
  // time we hear about it, so the only place its last position still exists
  // is the previous render's copy.
  const before = useRef<Unit[]>(state.units)
  const lastSeq = useRef<number>(state.fx?.seq ?? 0)
  const [blow, setBlow] = useState<Blow | null>(null)

  useEffect(() => {
    const fx = state.fx
    const prev = before.current
    before.current = state.units
    if (!fx || fx.seq === lastSeq.current) return
    lastSeq.current = fx.seq

    const a = prev.find((u) => u.id === fx.atk)
    const t = prev.find((u) => u.id === fx.tgt)
    if (!a || !t) return

    setBlow({
      seq: fx.seq, atk: fx.atk, tgt: fx.tgt,
      dmg: fx.dmg, counter: fx.counter,
      killedTgt: fx.killedTgt, killedAtk: fx.killedAtk,
      atkAt: { x: a.x, y: a.y }, tgtAt: { x: t.x, y: t.y },
      atkUnit: a, tgtUnit: t,
    })
    const id = setTimeout(() => setBlow(null), FX_MS)
    return () => clearTimeout(id)
  }, [state])

  const occupied = useMemo(() => new Set(state.units.map((u) => `${u.x},${u.y}`)), [state.units])

  const reachable = useMemo(() => {
    const s = new Set<string>()
    if (!selected || selected.owner !== mySide || !isMyTurn || selected.moved) return s
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const d = manhattan(selected, { x, y })
        if (d > 0 && d <= selected.mov && !occupied.has(`${x},${y}`)) s.add(`${x},${y}`)
      }
    }
    return s
  }, [selected, mySide, isMyTurn, w, h, occupied])

  const targets = useMemo(() => {
    const s = new Set<string>()
    if (!selected || selected.owner !== mySide || !isMyTurn || selected.acted) return s
    for (const u of state.units) {
      if (u.owner !== selected.owner && manhattan(selected, u) <= selected.rng) s.add(u.id)
    }
    return s
  }, [selected, mySide, isMyTurn, state.units])

  const at = (p: { x: number; y: number }) =>
    ({ gridColumn: p.x + 1, gridRow: p.y + 1 }) as React.CSSProperties

  // Which way the attacker leans when it strikes. A percentage, not pixels,
  // so the lunge is the same fraction of a tile at any board size.
  const lungeVars = (from: { x: number; y: number }, to: { x: number; y: number }) =>
    ({
      '--lx': `${Math.sign(to.x - from.x) * 16}%`,
      '--ly': `${Math.sign(to.y - from.y) * 16}%`,
    }) as React.CSSProperties

  return (
    <div
      className={`board${blow ? ' fx-playing' : ''}${watching(mySide) ? ' is-watching' : ''}`}
      style={{ '--cols': w, '--rows': h } as React.CSSProperties}
      onClick={() => onSelect(null)}
    >
      {Array.from({ length: w * h }, (_, i) => {
        const x = i % w
        const y = Math.floor(i / w)
        const key = `${x},${y}`
        const canMove = reachable.has(key)
        return (
          <div
            key={key}
            className={['tile', canMove ? 'tile-move' : ''].join(' ')}
            // Explicit placement, not auto-flow. The unit cards below are
            // placed by coordinate, and CSS grid positions definite items
            // FIRST -- so auto-flowed tiles would skip every occupied cell and
            // four of them would spill into an implicit sixth row.
            style={{ gridColumn: x + 1, gridRow: y + 1 }}
            onClick={(e) => {
              e.stopPropagation()
              if (watching(mySide)) return
              if (canMove) onMove(x, y)
              else onSelect(null)
            }}
          >
            {canMove && <span className="tile-dot" />}
          </div>
        )
      })}

      {state.units.map((u) => {
        const striking = blow?.atk === u.id
        const struck = blow?.tgt === u.id
        return (
          <UnitCard
            key={u.id}
            unit={u}
            yours={mySide !== null && u.owner === mySide}
            watching={watching(mySide)}
            selected={u.id === selectedId}
            targetable={targets.has(u.id)}
            slotClass={[
              striking ? 'fx-strike' : '',
              struck && !blow?.killedTgt ? 'fx-hurt' : '',
              // the counterattack is the same exchange, half a beat later
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
            onClick={(e) => {
              e.stopPropagation()
              if (watching(mySide)) return
              if (targets.has(u.id)) onAttack(u.id)
              else onSelect(u.id === selectedId ? null : u.id)
            }}
          />
        )
      })}

      {/* Everything below is transient: it exists only while an exchange plays. */}
      {blow && (
        <>
          {blow.killedTgt && (
            <div className="unit-ghost" style={at(blow.tgtAt)}>
              <GhostCard unit={blow.tgtUnit} />
            </div>
          )}
          {blow.killedAtk && (
            <div className="unit-ghost unit-ghost-late" style={at(blow.atkAt)}>
              <GhostCard unit={blow.atkUnit} />
            </div>
          )}
          <div className="dmg" style={at(blow.tgtAt)}>-{blow.dmg}</div>
          {blow.counter > 0 && (
            <div className="dmg dmg-late" style={at(blow.atkAt)}>-{blow.counter}</div>
          )}
        </>
      )}
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
  unit, yours, watching, selected, targetable, slotClass, slotVars, onClick,
}: {
  unit: Unit
  yours: boolean
  watching: boolean
  selected: boolean
  targetable: boolean
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
    <div
      className={`unit-slot ${slotClass}`.trim()}
      style={{ gridColumn: unit.x + 1, gridRow: unit.y + 1, ...slotVars }}
    >
      <div
        className={[
          'unit',
          // Colour is the SIDE, never "mine" -- otherwise the guest sees their
          // own units in the host's colour while their nameplate is the other,
          // and a spectator sees both armies as the enemy.
          unit.owner === 'host' ? 'unit-host' : 'unit-guest',
          yours ? 'is-yours' : '',
          watching ? 'is-inert' : '',
          selected ? 'is-selected' : '',
          targetable ? 'is-target' : '',
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

        {/* Opens on hover, once the card is large enough to read. Keeps the
            illustration, because that is how you recognise the card. */}
        <div className="unit-detail">
          <div className="unit-detail-art">{portrait}</div>
          <div className="unit-detail-name">{unit.name}</div>
          <dl className="unit-stats">
            <div><dt>HP</dt><dd>{unit.hp}/{unit.maxHp}</dd></div>
            <div><dt>ATK</dt><dd>{unit.atk}</dd></div>
            <div><dt>MOV</dt><dd>{unit.mov}</dd></div>
            <div><dt>RNG</dt><dd>{unit.rng}</dd></div>
          </dl>
          {unit.ability && <p className="unit-ability">{unit.ability}</p>}
        </div>

        <div className="unit-hp">{unit.hp}</div>
        {targetable && <div className="unit-crosshair" />}
      </div>
    </div>
  )
}
