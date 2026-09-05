import type { MatchState, Obstacle, Side, Unit } from './types'

/**
 * The client's copy of the geometry in 0005_roster_terrain_deploy.sql.
 *
 * It decides nothing. Every one of these questions is asked again by the
 * Postgres function before anything moves, and the answer that counts is that
 * one. This exists so the board can light up the squares you may use BEFORE
 * you click, which is the whole difference between a tactics game and a
 * guessing game.
 *
 * If you change a rule, change it in the migration first and then here.
 */

export const key = (x: number, y: number) => `${x},${y}`

/** Reach counts a diagonal as one step. Attacks and counters use this. */
export const cheb = (a: { x: number; y: number }, b: { x: number; y: number }) =>
  Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y))

/** The host defends the bottom of the canonical board. */
export const ownHalf = (side: Side, y: number, h: number) =>
  side === 'host' ? y >= Math.floor(h / 2) : y < Math.floor(h / 2)

export function occupied(state: MatchState): Set<string> {
  const s = new Set<string>()
  for (const u of state.units) s.add(key(u.x, u.y))
  for (const o of state.obstacles ?? []) s.add(key(o.x, o.y))
  return s
}

/**
 * Every tile a unit can walk to. A breadth-first walk of the grid, not a
 * distance test: movement is orthogonal and a tree has to be walked around,
 * so the shape is a diamond with bites taken out of it.
 */
export function reachable(state: MatchState, u: Unit): Set<string> {
  const { w, h } = state.board
  const blocked = occupied(state)
  const seen = new Set<string>([key(u.x, u.y)])
  const out = new Set<string>()
  let front: { x: number; y: number }[] = [{ x: u.x, y: u.y }]

  for (let step = 0; step < u.mov && front.length; step++) {
    const next: { x: number; y: number }[] = []
    for (const p of front) {
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        const nx = p.x + dx
        const ny = p.y + dy
        const k = key(nx, ny)
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue
        if (seen.has(k) || blocked.has(k)) continue
        seen.add(k)
        out.add(k)
        next.push({ x: nx, y: ny })
      }
    }
    front = next
  }
  return out
}

/**
 * Is a tree standing in the shot? A tree blocks if its centre lies within half
 * a tile of the straight line between the two. Units never block -- you can
 * shoot past your own people, you just cannot shoot through wood.
 */
export function losClear(
  state: MatchState,
  a: { x: number; y: number },
  b: { x: number; y: number },
): boolean {
  const den = Math.hypot(b.x - a.x, b.y - a.y)
  if (den === 0) return true
  for (const o of state.obstacles ?? []) {
    if ((o.x === a.x && o.y === a.y) || (o.x === b.x && o.y === b.y)) continue
    if (o.x < Math.min(a.x, b.x) || o.x > Math.max(a.x, b.x)) continue
    if (o.y < Math.min(a.y, b.y) || o.y > Math.max(a.y, b.y)) continue
    const num = Math.abs((b.x - a.x) * (a.y - o.y) - (a.x - o.x) * (b.y - a.y))
    if (num / den < 0.5) return false
  }
  return true
}

export type Target =
  | { kind: 'foe'; unit: Unit }
  | { kind: 'ally'; unit: Unit }
  | { kind: 'tree'; tree: Obstacle }

/** Everything the selected unit could act on right now. */
export function targetsFor(state: MatchState, u: Unit): Map<string, Target> {
  const out = new Map<string, Target>()
  const inReach = (p: { x: number; y: number }) => {
    const d = cheb(u, p)
    return d >= u.rmin && d <= u.rmax && losClear(state, u, p)
  }
  for (const other of state.units) {
    if (other.id === u.id || !inReach(other)) continue
    if (other.owner === u.owner) {
      if (u.heals) out.set(other.id, { kind: 'ally', unit: other })
    } else {
      out.set(other.id, { kind: 'foe', unit: other })
    }
  }
  for (const t of state.obstacles ?? []) {
    if (inReach(t)) out.set(t.id, { kind: 'tree', tree: t })
  }
  return out
}

/** Would this target hit back? Purely informational, for the hover hint. */
export function willCounter(u: Unit, t: Target): boolean {
  if (t.kind !== 'foe') return false
  const d = cheb(u, t.unit)
  return d >= t.unit.crmin && d <= t.unit.crmax
}

/** Where a unit may stand during deployment: your half, minus what is there. */
export function deployTiles(state: MatchState, side: Side): Set<string> {
  const { w, h } = state.board
  const trees = new Set((state.obstacles ?? []).map((o) => key(o.x, o.y)))
  const out = new Set<string>()
  for (let y = 0; y < h; y++) {
    if (!ownHalf(side, y, h)) continue
    for (let x = 0; x < w; x++) if (!trees.has(key(x, y))) out.add(key(x, y))
  }
  return out
}
