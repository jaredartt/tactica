import { useEffect, useMemo, useRef, useState } from 'react'
import { Board } from './Board'
import { Chat } from './Chat'
import { BattleLog } from './BattleLog'
import { useMatch, useMessages, useServerClock } from '../lib/useMatch'
import { endTurn, forceTimeout, leaveMatch, requestRematch, resignMatch, submitAttack, submitMove } from '../lib/api'
import { TURN_SECONDS, type Profile, type Side } from '../lib/types'

export function Match({ matchId, profile, onLeave, onGoTo }: {
  matchId: string
  profile: Profile
  onLeave: () => void
  onGoTo: (id: string) => void
}) {
  function leave() {
    // Tell the server first so an emptied room disappears at once rather than
    // waiting for the sweep. Closing the tab instead is covered by the sweep.
    leaveMatch(matchId)
    onLeave()
  }

  const { match, refresh } = useMatch(matchId)
  const messages = useMessages(matchId)
  const clockOffset = useServerClock()

  const [selected, setSelected] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [now, setNow] = useState(Date.now())
  const [askedRematch, setAskedRematch] = useState(false)
  const firedFor = useRef<string>('')

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 200)
    return () => clearInterval(id)
  }, [])

  const mySide: Side | null = !match
    ? null
    : match.host_id === profile.id
      ? 'host'
      : match.guest_id === profile.id
        ? 'guest'
        : null

  const state = match?.state
  const isMyTurn = Boolean(match && mySide && match.status === 'active' && state?.turn === mySide)

  const remaining = useMemo(() => {
    if (!match?.turn_deadline || match.status !== 'active') return null
    return (new Date(match.turn_deadline).getTime() - (now + clockOffset)) / 1000
  }, [match?.turn_deadline, match?.status, now, clockOffset])

  // Nobody is running a game server, so the clients enforce the clock by
  // *asking* the database to expire the turn. The function refuses unless the
  // deadline has genuinely passed according to Postgres, so this is safe to
  // call from either player or from a spectator.
  useEffect(() => {
    if (!match || match.status !== 'active' || remaining === null) return
    const stamp = `${match.id}:${state?.turnNumber}`
    if (remaining < -2 && firedFor.current !== stamp) {
      firedFor.current = stamp
      forceTimeout(match.id).then(refresh)
    }
  }, [remaining, match, state?.turnNumber, refresh])

  // The rematch is signalled by the finished room pointing at a new one, which
  // arrives over the realtime subscription we are already holding. Whoever
  // asked second created it; both sides get here the same way.
  useEffect(() => {
    const next = match?.next_match_id
    if (next && next !== matchId) {
      leaveMatch(matchId)
      onGoTo(next)
    }
  }, [match?.next_match_id, matchId, onGoTo])

  // Clear the selection whenever the turn flips.
  useEffect(() => setSelected(null), [state?.turn, state?.turnNumber])

  async function guard(fn: () => Promise<unknown>) {
    setErr(null)
    try {
      await fn()
      await refresh()
    } catch (e) {
      setErr((e as Error).message)
      await refresh()
      setTimeout(() => setErr(null), 3500)
    }
  }

  if (!match) {
    return (
      <div className="center-stage">
        <p className="muted">Loading match…</p>
      </div>
    )
  }

  const s = match.state
  const pct = remaining === null ? 0 : Math.max(0, Math.min(1, remaining / TURN_SECONDS))
  const urgent = remaining !== null && remaining <= 8

  return (
    <div className="match">
      <header className="matchbar">
        <button className="linkbtn" onClick={leave}>
          ← Lobby
        </button>

        <div className="scoreline">
          <Nameplate name={match.host_name} side="host" active={s.turn === 'host' && match.status === 'active'} you={mySide === 'host'} />
          <span className="vs">vs</span>
          <Nameplate
            name={match.guest_name ?? 'waiting…'}
            side="guest"
            active={s.turn === 'guest' && match.status === 'active'}
            you={mySide === 'guest'}
          />
        </div>

        <div className="matchbar-right">
          <button
            className="roomcode"
            title="Copy room code"
            onClick={() => navigator.clipboard?.writeText(match.code)}
          >
            {match.code}
          </button>
          {mySide === null && <span className="pill spectating">watching</span>}
        </div>
      </header>

      {match.status === 'active' && (
        <div className={`timerbar ${urgent ? 'urgent' : ''}`}>
          <div className="timerfill" style={{ width: `${pct * 100}%` }} />
          <span className="timertext">
            {isMyTurn
              ? 'Your turn'
              : mySide
                ? 'Opponent thinking'
                : `${s.turn === 'host' ? match.host_name : match.guest_name} to act`}
            {' · '}
            {Math.max(0, Math.ceil(remaining ?? 0))}s
          </span>
        </div>
      )}

      <div className="stage">
        <Chat matchId={match.id} profile={profile} messages={messages} role={mySide ? 'player' : 'spectator'} />

        <main className="center">
          {match.status === 'waiting' ? (
            <div className="waiting">
              <p className="muted">Send this code to your opponent</p>
              <div className="bigcode">{match.code}</div>
              <button className="btn" onClick={() => navigator.clipboard?.writeText(match.code)}>
                Copy code
              </button>
            </div>
          ) : (
            <>
              <Board
                state={s}
                mySide={mySide}
                isMyTurn={isMyTurn}
                selectedId={selected}
                onSelect={setSelected}
                onMove={(x, y) => selected && guard(() => submitMove(match.id, selected, x, y))}
                onAttack={(target) => selected && guard(() => submitAttack(match.id, selected, target))}
              />

              <div className="actionbar">
                {s.winner ? (
                  <>
                    <div className="verdict">
                      {(s.winner === 'host' ? match.host_name : match.guest_name) ?? 'Someone'} wins
                      {s.winner === mySide ? ' — that is you.' : '.'}
                    </div>
                    <button
                      className="btn primary"
                      disabled={askedRematch}
                      onClick={() =>
                        guard(async () => {
                          const next = await requestRematch(match.id)
                          if (next) onGoTo(next)
                          else setAskedRematch(true)
                        })
                      }
                    >
                      {askedRematch ? 'Waiting for them…' : 'Rematch'}
                    </button>
                    <span className="hint">
                      {askedRematch
                        ? 'It starts the moment they accept. Sides swap.'
                        : 'Both of you have to want it.'}
                    </span>
                  </>
                ) : mySide ? (
                  <>
                    <button className="btn primary" onClick={() => guard(() => endTurn(match.id))} disabled={!isMyTurn}>
                      End turn
                    </button>
                    <button className="btn ghost" onClick={() => guard(() => resignMatch(match.id))}>
                      Resign
                    </button>
                    <span className="hint">
                      {isMyTurn
                        ? 'Click a unit, then a lit tile to move or a marked enemy to strike.'
                        : 'Waiting for your opponent.'}
                    </span>
                  </>
                ) : (
                  <span className="hint">
                    Spectating — you can chat, but the board isn&rsquo;t yours to touch.
                  </span>
                )}
              </div>
            </>
          )}
          {err && <div className="toast">{err}</div>}
        </main>

        <BattleLog log={s.log} />
      </div>
    </div>
  )
}

function Nameplate({ name, side, active, you }: { name: string; side: Side; active: boolean; you: boolean }) {
  return (
    <span className={`nameplate ${side} ${active ? 'active' : ''}`}>
      {name}
      {you && <em>you</em>}
    </span>
  )
}
