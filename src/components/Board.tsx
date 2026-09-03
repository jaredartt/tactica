import { useMemo } from 'react'
import type { MatchState, Side, Unit } from '../lib/types'

const TILE = 88
const GAP = 6
const TILT = 52 // degrees the board leans away from the viewer

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

  const occupied = useMemo(
    () => new Set(state.units.map((u) => `${u.x},${u.y}`)),
    [state.units],
  )

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

  const boardW = w * TILE + (w - 1) * GAP
  const boardH = h * TILE + (h - 1) * GAP

  return (
    <div className="arena">
      <div className="arena-scene" style={{ width: boardW, height: boardH * Math.cos((TILT * Math.PI) / 180) + 180 }}>
        <div
          className="board"
          style={{
            width: boardW,
            height: boardH,
            transform: `rotateX(${TILT}deg)`,
          }}
          onClick={() => onSelect(null)}
        >
          <div className="board-glow" />

          {Array.from({ length: w * h }, (_, i) => {
            const x = i % w
            const y = Math.floor(i / w)
            const key = `${x},${y}`
            const canMove = reachable.has(key)
            return (
              <div
                key={key}
                className={[
                  'tile',
                  (x + y) % 2 ? 'tile-b' : 'tile-a',
                  canMove ? 'tile-move' : '',
                ].join(' ')}
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
              tilt={TILT}
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
      </div>
    </div>
  )
}

function UnitCard({
  unit,
  tilt,
  mine,
  selected,
  targetable,
  onClick,
}: {
  unit: Unit
  tilt: number
  mine: boolean
  selected: boolean
  targetable: boolean
  onClick: (e: React.MouseEvent) => void
}) {
  const hpPct = Math.max(0, Math.min(100, (unit.hp / unit.maxHp) * 100))
  return (
    <div
      className="unit-anchor"
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
        // The tilt is handed to CSS as a variable rather than set as an inline
        // transform, so the hover/float/selected animations can still compose
        // with it instead of being overridden by the inline style.
        style={
          {
            '--tilt': `${-tilt}deg`,
            '--accent': unit.accent,
          } as React.CSSProperties
        }
        onClick={onClick}
        title={`${unit.name} — ${unit.hp}/${unit.maxHp} HP · ATK ${unit.atk} · MOV ${unit.mov} · RNG ${unit.rng}`}
      >
        <div className="unit-art">
          {unit.art ? <img src={unit.art} alt="" /> : <span className="unit-initial">{unit.name[0]}</span>}
        </div>
        <div className="unit-name">{unit.name}</div>
        <div className="unit-hpbar">
          <span style={{ width: `${hpPct}%` }} />
        </div>
        <div className="unit-hp">{unit.hp}</div>
        {targetable && <div className="unit-crosshair" />}
      </div>
      <div className="unit-shadow" />
    </div>
  )
}
