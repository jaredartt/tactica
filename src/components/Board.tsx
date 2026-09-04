import { useMemo } from 'react'
import type { MatchState, Side, Unit } from '../lib/types'

const TILE = 104
const GAP = 10
const MAX_TILT = 16 // degrees the card leans toward the cursor

interface Props {
  state: MatchState
  mySide: Side | null
  isMyTurn: boolean
  selectedId: string | null
  onSelect: (id: string | null) => void
  onMove: (x: number, y: number) => void
  onAttack: (targetId: string) => void
}

const manhattan = (a: { x: number; y: number }, b: { x: number; y: number }) =>
  Math.abs(a.x - b.x) + Math.abs(a.y - b.y)

export function Board({ state, mySide, isMyTurn, selectedId, onSelect, onMove, onAttack }: Props) {
  const { w, h } = state.board
  const selected = state.units.find((u) => u.id === selectedId) ?? null

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

  return (
    <div
      className="board"
      style={{
        width: w * TILE + (w - 1) * GAP,
        height: h * TILE + (h - 1) * GAP,
      }}
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
            style={{ left: x * (TILE + GAP), top: y * (TILE + GAP), width: TILE, height: TILE }}
            onClick={(e) => {
              e.stopPropagation()
              if (canMove) onMove(x, y)
              else onSelect(null)
            }}
          >
            {canMove && <span className="tile-dot" />}
          </div>
        )
      })}

      {state.units.map((u) => (
        <UnitCard
          key={u.id}
          unit={u}
          mine={u.owner === mySide}
          selected={u.id === selectedId}
          targetable={targets.has(u.id)}
          onClick={(e) => {
            e.stopPropagation()
            if (targets.has(u.id)) onAttack(u.id)
            else onSelect(u.id === selectedId ? null : u.id)
          }}
        />
      ))}
    </div>
  )
}

function UnitCard({
  unit,
  mine,
  selected,
  targetable,
  onClick,
}: {
  unit: Unit
  mine: boolean
  selected: boolean
  targetable: boolean
  onClick: (e: React.MouseEvent) => void
}) {
  const hpPct = Math.max(0, Math.min(100, (unit.hp / unit.maxHp) * 100))

  // The card leans toward the pointer. Writing the angles to CSS variables
  // rather than to `transform` lets the stylesheet own the scale and the
  // resting state, so hover, selection and tilt compose instead of fighting.
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

  return (
    <div
      className="unit-slot"
      style={{ left: unit.x * (TILE + GAP), top: unit.y * (TILE + GAP), width: TILE, height: TILE }}
    >
      <div
        className={[
          'unit',
          mine ? 'unit-mine' : 'unit-foe',
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
          <div className="unit-art">
            {unit.art ? <img src={unit.art} alt="" /> : <span className="unit-initial">{unit.name[0]}</span>}
          </div>
          <div className="unit-name">{unit.name}</div>
          <div className="unit-hpbar">
            <span style={{ width: `${hpPct}%` }} />
          </div>
        </div>

        {/* Revealed on hover, once the card is big enough to read. */}
        <div className="unit-detail">
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
