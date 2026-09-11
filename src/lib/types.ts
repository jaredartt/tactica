export type Side = 'host' | 'guest'

export interface Unit {
  id: string
  owner: Side
  cardId: string
  slug: string
  name: string
  /** Swordsmen, Mage, Herbalist... Flavour and a hover heading, nothing more. */
  role: string
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
  /** The single number a player reads. The roll is pow +/- 5, and dmin/dmax
   *  are derived from it server-side -- they are the dice, this is the stat.
   *  Optional because a match that was already in flight when 0018 landed has
   *  units in its state blob without it; use unitPower() rather than this. */
  pow?: number
  /** Percent chances, out of 100. 5 for almost everyone. */
  parryPct?: number
  critPct?: number
  /** Catches any answer-to-a-parry aimed at it. */
  parryAll?: boolean
  /** Lose it and you lose the match. A kingdom holds exactly one. */
  royal?: boolean
  burns: boolean
  heals: boolean
  /** Steps over trees and lands where they stood. */
  tramples: boolean
  /** Moves by air: distance only, no walking round anything. */
  flies: boolean
  /** Never takes a counter. */
  sneaks: boolean
  /** Mending also puts a burn out. */
  cures: boolean
  /** Answers BEFORE the blow it is answering. If the answer kills, the blow
   *  never lands at all. */
  parries: boolean
  /** Mending reaches every ally in range, not only the one you clicked. */
  blooms: boolean
  burned: boolean
  /** Guard up. Halves what lands on this unit until its OWN next turn, so it
   *  is still standing while the opponent swings -- which is the only moment
   *  it could matter. Raised by submit_defend, dropped by advance_turn. */
  defending?: boolean
  accent: string
  art: string | null
  ability: string
  x: number
  y: number
  moved: boolean
  acted: boolean
  /** This unit has had its whole go this turn and cannot start another.
   *  Optional for the same reason `pow` is: a match already in flight when
   *  0019 landed has units without it. Read it as false when it is missing --
   *  cn_begin_act does exactly that. */
  spent?: boolean
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
  /** The mend also put a fire out. */
  cured: boolean
  /** The counter landed first, so the attack may never have happened. */
  parry: boolean
  /** Ids of the allies a bloom swept up besides the one that was clicked. */
  bloom?: string[]
  tree: boolean
  /** These five have been written by the server since 0018 and were simply
   *  missing from this type. The cinematic needs them, and the board's own
   *  little animation would have been entitled to them all along. */
  crit?: boolean
  critCounter?: boolean
  /** Swings caught, and swings swung -- the parry chain, counted. */
  parries?: number
  chain?: number
  /** What the attacker took off in ANSWER to a parry, as opposed to `dmg`,
   *  which is the opening blow. Lium's free hit lands here. */
  riposte?: number
  /** The exchange blow by blow, in the order it happened, from 0020. Absent on
   *  a match that was already in flight when that landed -- read it through
   *  swingsOf() in cine.ts, never directly. */
  swings?: Swing[]
}

/**
 * One thing that happened inside an exchange. Written by cn_attack in
 * 0020_swings.sql; the comment block at the top of that file is the contract.
 *
 * `why` is the field that earns its place: Lium catching an answer because he
 * is Lium ('all') is not the same event as a 5% roll coming up ('roll'), and a
 * caption that calls both of them a parry is labelling rather than narrating.
 */
export interface Swing {
  k: 'hit' | 'parry' | 'burn' | 'down' | 'heal'
  /** Who swung, caught, burned or fell. */
  by: string
  /** Who received it. Equal to `by` for a burn or a falling. */
  at: string
  dmg?: number
  crit?: boolean
  /** It was an answer, so it was already halved. */
  counter?: boolean
  /** The receiver had a guard up, so it was halved again. */
  def?: boolean
  /** It landed BEFORE the blow it answers. Quick Dagger, and nothing else. */
  first?: boolean
  why?: 'strike' | 'counter' | 'quick' | 'tree' | 'mend' | 'roll' | 'all'
}

export interface MatchState {
  v: number
  board: { w: number; h: number }
  phase: 'deploy' | 'battle'
  ready: Record<Side, boolean>
  obstacles: Obstacle[]
  turn: Side
  turnNumber: number
  /** Activations the side to move has spent this turn, and the unit part-way
   *  through one -- it has moved but has not yet struck, so it may still, and
   *  that costs nothing further. Both from 0019; both absent on an older
   *  match, which is why everything reads them through a default. */
  acts?: number
  active?: string | null
  /** Consecutive turns each side has let expire without touching a unit. */
  idle?: Record<Side, number>
  /** Set once a side reaches three. A fact, not a verdict -- the match keeps
   *  running and the flag clears the moment they act again. */
  away?: Side | null
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
  /** 1, 2 or 3 when the guest seat is the bot; null when it is a person. */
  bot: number | null
  /** Only a match found through the queue moves anybody's number. */
  ranked: boolean
  state: MatchState
  turn_deadline: string | null
  winner: Side | null
  created_at: string
  updated_at: string
  rematch_host: boolean
  rematch_guest: boolean
  /** Somebody said no. Cleared by the next invitation, so it is never final. */
  rematch_declined: boolean
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
  role: string
  hp: number
  mov: number
  rmin: number
  rmax: number
  crmin: number
  crmax: number
  dmin: number
  dmax: number
  /** See Unit.pow. Null only on a card row written before 0018. */
  power: number | null
  parry_pct: number
  crit_pct: number
  parry_all: boolean
  royal: boolean
  burns: boolean
  heals: boolean
  tramples: boolean
  flies: boolean
  sneaks: boolean
  cures: boolean
  parries: boolean
  blooms: boolean
  ability: string
  /** The same sentence in Spanish. Null until somebody writes it, and the
   *  client falls back to English when it is -- see abilityText(). */
  ability_es: string | null
  accent: string
  /** Relative to the site root, e.g. 'cards/dereo.webp'. Run it through
   *  artUrl() before putting it in a src -- the site is not served from /. */
  art_url: string | null
  sort: number
}

export interface Profile {
  id: string
  username: string
  /** A card slug, or null for the plain initial. */
  avatar: string | null
  is_admin: boolean
  lp: number
  wins: number
  losses: number
  games: number
  streak: number
  deck: string[] | null
  /** Sound, motion, theme -- see settings.ts. Optional because a client can be
   *  one deploy ahead of the database, which here is a normal state rather
   *  than a hypothetical. */
  settings?: Record<string, unknown> | null
}

export interface LadderRow {
  id: string
  username: string
  avatar: string | null
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

/** A turn is two activations, and one activation is one unit's whole go --
 *  move, then strike, or either alone. Mirrors cn_acts_cap() in
 *  0019_board_and_actions.sql: the opening turn of a match gets ONE, because
 *  going first with a full turn is worth too much on a board this size. It
 *  reads <= 1 rather than === 1 so a match from before that migration, which
 *  may carry no turnNumber at all, is treated as opening rather than as
 *  unlimited -- the same fallback the server takes. */
export const ACTS_PER_TURN = 2
export const actsCap = (s: { turnNumber?: number }) =>
  (s.turnNumber ?? 1) <= 1 ? 1 : ACTS_PER_TURN

export const TURN_SECONDS = 30
export const DEPLOY_SECONDS = 90
export const DECK_SIZE = 5
export const AWAY_TURNS = 3

/** The three difficulties. The level is the number the server wants; the key
 *  is the name of the words, which live in the dictionary now -- CALM, SHARP
 *  and RUTHLESS are as much a translation as any other sentence, and having
 *  them here as well would be two places to change one. */
export const BOT_LEVELS = [
  { level: 1, key: 'calm' },
  { level: 2, key: 'sharp' },
  { level: 3, key: 'ruthless' },
] as const

export const reachText = (lo: number, hi: number) => (lo === hi ? `${lo}` : `${lo}–${hi}`)

/** The single number to print for a unit or a card. Falls back to the middle
 *  of the old band, which is exactly how 0018 derived `power` in the first
 *  place -- so a match still running from before the migration reads the same
 *  number it would have been given. */
export function unitPower(u: { pow?: number | null; power?: number | null; dmin: number; dmax: number }): number {
  const p = u.pow ?? u.power
  return p ?? Math.round((u.dmin + u.dmax) / 2)
}
