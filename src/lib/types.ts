export type Side = 'host' | 'guest'

export interface Unit {
  id: string
  owner: Side
  cardId: string
  slug: string
  name: string
  hp: number
  maxHp: number
  mov: number
  /** Attack reach, in tiles, counting a diagonal as one. An Archer is 2..2 --
   *  it cannot shoot something standing next to it. */
  rmin: number
  rmax: number
  /** Counter reach. Separate from the attack reach on purpose: it is the only
   *  thing that decides whether a defender strikes back. */
  crmin: number
  crmax: number
  dmin: number
  dmax: number
  burns: boolean
  heals: boolean
  burned: boolean
  accent: string
  art: string | null
  ability: string
  x: number
  y: number
  moved: boolean
  acted: boolean
}

/** A tree. Blocks feet and arrows, has 30 HP, and can be cut down. */
export interface Obstacle {
  id: string
  x: number
  y: number
  hp: number
  maxHp: number
}

export interface LogEntry {
  n: number
  turn: number
  text: string
}

/** Structured record of the last exchange, written by the database so the
 *  clients can animate it without parsing the log text. */
export interface Fx {
  seq: number
  atk: string
  tgt: string
  dmg: number
  heal: number
  killedTgt: boolean
  counter: number
  killedAtk: boolean
  burnAtk: number
  burnTgt: number
  newBurn: boolean
  tree: boolean
}

export interface MatchState {
  v: number
  board: { w: number; h: number }
  phase: 'deploy' | 'battle'
  ready: Record<Side, boolean>
  obstacles: Obstacle[]
  turn: Side
  turnNumber: number
  units: Unit[]
  log: LogEntry[]
  winner: Side | null
  fx?: Fx
}

export type MatchStatus = 'waiting' | 'deploying' | 'active' | 'finished'

export interface MatchRow {
  id: string
  code: string
  host_id: string
  guest_id: string | null
  host_name: string
  guest_name: string | null
  status: MatchStatus
  state: MatchState
  turn_deadline: string | null
  winner: Side | null
  created_at: string
  updated_at: string
  rematch_host: boolean
  rematch_guest: boolean
  next_match_id: string | null
}

export interface Message {
  id: number
  match_id: string
  user_id: string
  username: string
  body: string
  created_at: string
}

export interface Card {
  id: string
  slug: string
  name: string
  hp: number
  mov: number
  rmin: number
  rmax: number
  crmin: number
  crmax: number
  dmin: number
  dmax: number
  burns: boolean
  heals: boolean
  ability: string
  accent: string
  art_url: string | null
  sort: number
}

export interface Profile {
  id: string
  username: string
  is_admin: boolean
  lp: number
  wins: number
  losses: number
  games: number
  streak: number
  deck: string[] | null
}

export interface LadderRow {
  id: string
  username: string
  lp: number
  tier: string
  wins: number
  losses: number
  games: number
  streak: number
}

/** Mirrors tier_of() in 0004_ladder.sql. Display only -- the server owns the
 *  floors -- but if you change the thresholds, change them in both places. */
export const TIERS = [
  { at: 1500, name: 'Crown' },
  { at: 1200, name: 'Diamond' },
  { at: 900, name: 'Platinum' },
  { at: 600, name: 'Gold' },
  { at: 300, name: 'Silver' },
  { at: 0, name: 'Bronze' },
] as const

export const tierOf = (lp: number) => TIERS.find((t) => lp >= t.at)!.name

export const TURN_SECONDS = 30
export const DEPLOY_SECONDS = 90
export const DECK_SIZE = 4

export const reachText = (lo: number, hi: number) => (lo === hi ? `${lo}` : `${lo}–${hi}`)
