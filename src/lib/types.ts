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

export interface MatchState {
  v: number
  board: { w: number; h: number }
  turn: Side
  turnNumber: number
  units: Unit[]
  log: LogEntry[]
  winner: Side | null
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
}

export const TURN_SECONDS = 30
