import { supabase } from './supabase'
import type { MatchRow } from './types'

/**
 * Every one of these is a call to a Postgres function that validates the move
 * before it touches the board. If a call throws, the server said no — show the
 * message and leave local state alone.
 */

function unwrap<T>(res: { data: T | null; error: { message: string } | null }): T {
  if (res.error) throw new Error(res.error.message.replace(/^.*?:\s*/, ''))
  if (res.data === null) throw new Error('empty response')
  return res.data
}

export async function createMatch(): Promise<MatchRow> {
  return unwrap(await supabase.rpc('create_match').single())
}

export async function joinMatch(code: string): Promise<MatchRow> {
  return unwrap(await supabase.rpc('join_match', { p_code: code.toUpperCase().trim() }).single())
}

export async function submitMove(matchId: string, unitId: string, x: number, y: number) {
  return unwrap(
    await supabase.rpc('submit_move', { p_match: matchId, p_unit: unitId, p_x: x, p_y: y }).single(),
  )
}

export async function submitAttack(matchId: string, unitId: string, targetId: string) {
  return unwrap(
    await supabase
      .rpc('submit_attack', { p_match: matchId, p_unit: unitId, p_target: targetId })
      .single(),
  )
}

export async function endTurn(matchId: string) {
  return unwrap(await supabase.rpc('end_turn', { p_match: matchId }).single())
}

export async function resignMatch(matchId: string) {
  return unwrap(await supabase.rpc('resign_match', { p_match: matchId }).single())
}

/** Safe to call from anyone, including spectators. The server ignores it if
 *  the clock has not actually expired. */
export async function forceTimeout(matchId: string) {
  const { error } = await supabase.rpc('force_timeout', { p_match: matchId })
  if (error) console.warn('force_timeout:', error.message)
}

export async function serverNow(): Promise<number> {
  const { data, error } = await supabase.rpc('server_now')
  if (error || !data) return Date.now()
  return new Date(data as string).getTime()
}

/** "I am still in this room." No-op for spectators -- only players hold a
 *  room open, so a match watched by nobody who is playing gets swept. */
export async function touchMatch(matchId: string) {
  const { error } = await supabase.rpc('touch_match', { p_match: matchId })
  if (error) console.warn('touch_match:', error.message)
}

/** Deliberate exit. Deletes the room outright if it just emptied. */
export async function leaveMatch(matchId: string) {
  const { error } = await supabase.rpc('leave_match', { p_match: matchId })
  if (error) console.warn('leave_match:', error.message)
}

/** Safety net for tabs that were closed rather than left. Safe for anyone to
 *  call: it can only remove rooms no player has touched in the grace window. */
export async function sweepMatches() {
  const { error } = await supabase.rpc('sweep_matches')
  if (error) console.warn('sweep_matches:', error.message)
}

/** Ask for a rematch. Returns the new match id once BOTH players have asked,
 *  null while you are still waiting for the other one. */
export async function requestRematch(matchId: string): Promise<string | null> {
  const { data, error } = await supabase.rpc('request_rematch', { p_match: matchId })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data as string | null) ?? null
}
