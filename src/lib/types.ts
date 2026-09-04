export type Side = 'host' | 'guest'

export interface Unit {
  id: string
  owner: Side
  cardId: string
  name: string
  hp: number
  maxHp: number
  atk: number
  mov: number
  rng: number
  accent: string
  art: string | null
  ability: string
  x: number
  y: number
  moved: boolean
  acted: boolean
}

export interface LogEntry {
  n: number
  turn: number
  text: string
}

/** Structured record of the last attack, written by the database so the
 *  clients can animate it without parsing the log text. */
export interface Fx {
  seq: number
  atk: string
  tgt: string
  dmg: number
  killedTgt: boolean
  counter: number
  killedAtk: boolean
}

export interface MatchState {
  v: number
  board: { w: number; h: number }
  turn: Side
  turnNumber: number
  units: Unit[]
  log: LogEntry[]
  winner: Side | null
  fx?: Fx
}

export interface MatchRow {
  id: string
  code: string
  host_id: string
  guest_id: string | null
  host_name: string
  guest_name: string | null
  status: 'waiting' | 'active' | 'finished'
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

export interface Profile {
  id: string
  username: string
  is_admin: boolean
  lp: number
  wins: number
  losses: number
  games: number
  streak: number
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
