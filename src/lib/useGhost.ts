import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from './supabase'
import type { Side } from './types'

/**
 * Where the other player is looking.
 *
 * Duelyst's trick, and the cheapest thing in this project that makes a match
 * feel like it has somebody on the other end of it: you see the tile their
 * pointer is over, which unit they have picked up, and what they are lining it
 * up to do -- half a second before they do it.
 *
 * It rides a Realtime BROADCAST channel and touches the database not at all.
 * None of it is a fact about the game: it is a fact about a pointer, it is
 * gone the moment they move it, and nothing the server decides depends on it.
 * That is also its security model -- a cheater can lie about where their mouse
 * is, and the reward for doing so is that you get a wrong idea about where
 * their mouse is.
 *
 * WHAT DOES NOT GO OVER IT is the part to be careful with, and there are two:
 *
 *  - Deployment. The two half-boards are deliberately unreadable to each other
 *    (`my_deploy` only ever hands you your own), and a pointer hovering the
 *    tile it is about to place a unit on would give the whole setup away one
 *    square at a time. So this only ever runs while the match is ACTIVE.
 *  - Anything hidden. Mist does not exist yet; when it does, a Rogue aiming
 *    from inside it must not broadcast, or invisibility is worth nothing. The
 *    `mute` argument is the hook for that -- pass it true and the ghost goes
 *    quiet without the caller having to tear the channel down.
 *
 * A spectator sends nothing (they have no side) and sees the player to move,
 * which is the one whose thinking is worth watching.
 */
export interface Ghost {
  side: Side
  /** The tile their pointer is over, in BOARD coordinates -- the flip is a
   *  local drawing and the two clients may not agree on it. */
  tile: { x: number; y: number } | null
  /** The unit they have selected, and what their menu is showing. Enough for
   *  the other client to recompute the same highlights from the shared state,
   *  which is why the highlights themselves are not sent. */
  unit: string | null
  mode: 'menu' | 'move' | 'attack' | null
}

/** Ten a second is the client's configured ceiling (see supabase.ts), so send
 *  at half of it and leave room for the chat and the row updates. */
const SEND_MS = 200
/** A pointer that has said nothing for this long has left. Long enough to ride
 *  out a dropped frame or a slow tab, short enough that a ghost never haunts
 *  an empty seat. */
const STALE_MS = 2500

/**
 * The rate limiter, as a plain function so it can be tested without a browser,
 * a channel or a clock.
 *
 * Two rules, and the second is the one that is easy to get wrong. Send nothing
 * if nothing has changed -- a pointer resting inside one square has no news.
 * And when something HAS changed inside the window, hold it and send it at the
 * end of the window rather than dropping it: the last thing you did is the one
 * that matters, and dropping it leaves your ghost standing on a tile you have
 * already left.
 *
 * `now` is injected so a test can move time by hand.
 */
export function throttler<T>(
  send: (v: T) => void,
  ms = SEND_MS,
  now: () => number = Date.now,
  later: (f: () => void, d: number) => unknown = setTimeout,
  cancel: (h: unknown) => void = (h) => clearTimeout(h as ReturnType<typeof setTimeout>),
) {
  let sentBody = ''          // what actually went out last
  let sentAt = -Infinity
  let pending: { body: string; value: T } | null = null
  let timer: unknown = null

  const flush = () => {
    timer = null
    const p = pending
    if (!p) return
    pending = null
    sentBody = p.body
    sentAt = now()
    send(p.value)
  }

  return {
    push(value: T, body: string) {
      // Compared against what was SENT, and both sides of that comparison are
      // the same shape. An earlier version stringified the payload with the
      // side attached on one side of it and without on the other, so the two
      // never matched and every single pointer move went down the wire.
      if (body === sentBody) return
      pending = { body, value }
      if (timer) return
      const wait = ms - (now() - sentAt)
      if (wait <= 0) flush()
      else timer = later(flush, wait)
    },
    stop() { if (timer) cancel(timer); timer = null; pending = null },
  }
}

export function useGhost(
  matchId: string | null, mySide: Side | null, live: boolean, mute = false,
) {
  const [ghost, setGhost] = useState<Ghost | null>(null)
  const chan = useRef<ReturnType<typeof supabase.channel> | null>(null)

  useEffect(() => {
    if (!matchId || !live) { setGhost(null); return }
    const c = supabase
      .channel(`ghost:${matchId}`, { config: { broadcast: { self: false } } })
      .on('broadcast', { event: 'look' }, ({ payload }) => {
        const g = payload as Ghost
        // Your own reflection, arriving because self-broadcast got turned back
        // on or because somebody is spoofing a side. Either way it is noise.
        if (g.side === mySide) return
        setGhost(g)
      })
      .subscribe()
    chan.current = c
    return () => {
      supabase.removeChannel(c)
      chan.current = null
      setGhost(null)
    }
  }, [matchId, live, mySide])

  // Let it go rather than tearing it out from under the eye: every arriving
  // message restarts the clock, and silence ends it.
  useEffect(() => {
    if (!ghost) return
    const id = setTimeout(() => setGhost(null), STALE_MS)
    return () => clearTimeout(id)
  }, [ghost])

  const gate = useRef<ReturnType<typeof throttler<Ghost>> | null>(null)
  if (!gate.current) {
    gate.current = throttler<Ghost>((g) => {
      chan.current?.send({ type: 'broadcast', event: 'look', payload: g })
    })
  }
  useEffect(() => () => gate.current?.stop(), [])

  /**
   * Report where you are looking. Safe to call on every pointer move -- the
   * throttle above decides what is worth saying and when.
   */
  const look = useCallback((g: Omit<Ghost, 'side'>) => {
    if (!chan.current || !mySide || mute) return
    gate.current!.push({ ...g, side: mySide }, JSON.stringify(g))
  }, [mySide, mute])

  return { ghost, look }
}
