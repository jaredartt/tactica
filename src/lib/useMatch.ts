import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from './supabase'
import { serverNow, touchMatch } from './api'
import type { MatchRow, Message } from './types'

/**
 * Live view of one match.
 *
 * Realtime is the fast path. The 5-second poll underneath it is the safety
 * net: websockets drop on flaky wifi and on laptop sleep, and a turn-based
 * game that silently stops updating is the worst possible bug to debug. At
 * this player count the extra queries cost nothing.
 */
export function useMatch(matchId: string | null) {
  const [match, setMatch] = useState<MatchRow | null>(null)
  const [error, setError] = useState<string | null>(null)
  const seen = useRef<string>('')

  const pull = useCallback(async () => {
    if (!matchId) return
    const { data, error } = await supabase.from('matches').select('*').eq('id', matchId).maybeSingle()
    if (error) {
      setError(error.message)
      return
    }
    if (!data) return
    const row = data as MatchRow
    // Ignore stale rows that arrive out of order.
    if (row.updated_at >= seen.current) {
      seen.current = row.updated_at
      setMatch(row)
    }
  }, [matchId])

  useEffect(() => {
    if (!matchId) {
      setMatch(null)
      return
    }
    seen.current = ''
    pull()

    const channel = supabase
      .channel(`match:${matchId}`)
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'matches', filter: `id=eq.${matchId}` },
        (payload) => {
          const row = payload.new as MatchRow
          if (row.updated_at >= seen.current) {
            seen.current = row.updated_at
            setMatch(row)
          }
        },
      )
      .subscribe()

    // Heartbeat: this is what keeps the room from being swept. Sent
    // immediately so a freshly opened room is never a candidate, then every
    // ten seconds against a 45-second grace -- three misses before a room is
    // considered empty, which survives a refresh or a phone waking up.
    touchMatch(matchId)
    const beat = setInterval(() => touchMatch(matchId), 10_000)

    const poll = setInterval(pull, 5000)
    return () => {
      supabase.removeChannel(channel)
      clearInterval(poll)
      clearInterval(beat)
    }
  }, [matchId, pull])

  return { match, error, refresh: pull }
}

export function useMessages(matchId: string | null) {
  const [messages, setMessages] = useState<Message[]>([])

  useEffect(() => {
    if (!matchId) {
      setMessages([])
      return
    }
    let alive = true
    supabase
      .from('match_messages')
      .select('*')
      .eq('match_id', matchId)
      .order('created_at', { ascending: true })
      .limit(200)
      .then(({ data }) => {
        if (alive && data) setMessages(data as Message[])
      })

    const channel = supabase
      .channel(`chat:${matchId}`)
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'match_messages', filter: `match_id=eq.${matchId}` },
        (payload) => {
          const msg = payload.new as Message
          setMessages((prev) => (prev.some((m) => m.id === msg.id) ? prev : [...prev, msg]))
        },
      )
      .subscribe()

    return () => {
      alive = false
      supabase.removeChannel(channel)
    }
  }, [matchId])

  return messages
}

/** Offset between this browser's clock and Postgres's, so the countdown is
 *  honest even if the user's laptop clock is minutes off. */
export function useServerClock() {
  const [offset, setOffset] = useState(0)
  useEffect(() => {
    let alive = true
    const sync = async () => {
      const t0 = Date.now()
      const server = await serverNow()
      const rtt = Date.now() - t0
      if (alive) setOffset(server + rtt / 2 - Date.now())
    }
    sync()
    const id = setInterval(sync, 60_000)
    return () => {
      alive = false
      clearInterval(id)
    }
  }, [])
  return offset
}
