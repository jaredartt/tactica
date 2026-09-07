import { supabase } from './supabase'
import type { MatchRow, Unit } from './types'

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

/** Save your team. The server re-checks the count, the duplicates and that
 *  every card is really in the roster. */
export async function setDeck(deck: string[]): Promise<string[]> {
  const { data, error } = await supabase.rpc('set_deck', { p_deck: deck })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return data as string[]
}

/**
 * Move one of your units during deployment. Dropping onto one of your own
 * swaps the two.
 *
 * Returns YOUR units and nothing else, because during this phase the two armies
 * are not in the match row -- your opponent's positions are somewhere you have
 * no permission to look, which is the only way to stop someone reading them
 * out of the network tab and setting up against what they saw.
 */
export async function deployUnit(
  matchId: string, unitId: string, x: number, y: number,
): Promise<Unit[]> {
  const { data, error } = await supabase
    .rpc('deploy_unit', { p_match: matchId, p_unit: unitId, p_x: x, p_y: y })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return (data ?? []) as Unit[]
}

/** Your own half of a deployment in progress. Null once the match has started,
 *  when both armies are on the board for real. */
export async function myDeploy(matchId: string): Promise<Unit[] | null> {
  const { data, error } = await supabase.rpc('my_deploy', { p_match: matchId })
  if (error) { console.warn('my_deploy:', error.message); return null }
  return (data as Unit[] | null) ?? null
}

/** Lock your half in. The match starts when both players have. */
export async function setReady(matchId: string) {
  return unwrap(await supabase.rpc('set_ready', { p_match: matchId }).single())
}

/** Take the win from an opponent who has gone. The server refuses while their
 *  browser is still sending its heartbeat, so a reload can never lose you a
 *  match -- the message it sends back says exactly that. */
export async function claimWin(matchId: string) {
  return unwrap(await supabase.rpc('claim_win', { p_match: matchId }).single())
}

/** Practice against the machine. A real room with a real board -- the bot
 *  plays through the same Postgres functions your clicks do. */
export async function createBotMatch(level: number): Promise<MatchRow> {
  return unwrap(await supabase.rpc('create_bot_match', { p_level: level }).single())
}

/** Ask the bot for its next single action. Safe for anyone to call: the server
 *  refuses unless it really is a bot match and really is the bot's turn. */
export async function botStep(matchId: string) {
  const { error } = await supabase.rpc('bot_step', { p_match: matchId })
  if (error) console.warn('bot_step:', error.message)
}

export interface QueueState {
  match: string | null
  waiting: number
}

/** Keeps you in the ranked queue and looks for an opponent. Called every
 *  couple of seconds while the queue screen is open; stop calling and you
 *  drop out on your own after twenty-five seconds. */
export async function rankedTick(): Promise<QueueState> {
  const { data, error } = await supabase.rpc('ranked_tick')
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
  return data as QueueState
}

export async function leaveRanked() {
  const { error } = await supabase.rpc('leave_ranked')
  if (error) console.warn('leave_ranked:', error.message)
}

/** "Not today." Clears both asks, so whoever invited gets their button back
 *  instead of waiting on an answer that is never coming. */
export async function declineRematch(matchId: string) {
  const { error } = await supabase.rpc('decline_rematch', { p_match: matchId })
  if (error) throw new Error(error.message.replace(/^.*?:\s*/, ''))
}
