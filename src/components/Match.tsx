import { useEffect, useMemo, useRef, useState } from 'react'
import { Board } from './Board'
import { Chat } from './Chat'
import { BattleLog } from './BattleLog'
import { TreeBigCard, UnitBigCard } from './BigCard'
import { useMatch, useMessages, useServerClock } from '../lib/useMatch'
import {
  botStep, claimWin, declineRematch, deployUnit, endTurn, forceTimeout, leaveMatch,
  myDeploy, requestRematch, resignMatch, setReady, submitAttack, submitDefend, submitMove,
  submitWait,
} from '../lib/api'
import {
  DEPLOY_SECONDS, TURN_SECONDS, actsCap, reachText,
  type MatchState, type Profile, type Side, type Unit,
  unitPower,
} from '../lib/types'
import { flipFor } from '../lib/rules'
import { playLose, playTurn, playWin } from '../lib/sfx'

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
  const [hovered, setHovered] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [now, setNow] = useState(Date.now())
  // Which rail is showing. Only meaningful on a narrow screen, where the two
  // side panels become tabs instead of columns -- there is no room for both,
  // and a phone should never have to scroll a match.
  // null means neither is showing. On a phone the rails are a sheet that slides
  // over the board rather than a column beside it, and the board is what you
  // came for -- so nothing covers it until you ask.
  const [rail, setRail] = useState<'chat' | 'log' | null>(null)
  // Your own four during deployment. They are not in the match row -- the row
  // is readable by everyone, and a setup you can read is a setup you can play
  // against -- so they arrive through a function that will only ever hand you
  // your own side.
  const [myUnits, setMyUnits] = useState<Unit[] | null>(null)
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
  const deploying = match?.status === 'deploying'
  const isMyTurn = Boolean(match && mySide && match.status === 'active' && state?.turn === mySide)
  // What the board draws. During deployment that is your half and the trees;
  // the other half is genuinely empty, because nothing else has been sent.
  const shown: MatchState | undefined =
    state && match?.status === 'deploying' ? { ...state, units: myUnits ?? [] } : state
  const selectedUnit = shown?.units.find((u) => u.id === selected) ?? null
  const iAmReady = Boolean(mySide && state?.ready?.[mySide])
  const theirSide: Side | null = mySide === 'host' ? 'guest' : mySide === 'guest' ? 'host' : null

  // Read off the row rather than kept in this component: an invitation has to
  // survive a reload, and both players have to see the same one.
  const iAsked = Boolean(match && mySide && match[`rematch_${mySide}` as const])
  const theyAsked = Boolean(match && theirSide && match[`rematch_${theirSide}` as const])
  const challenged = Boolean(
    theyAsked && !iAsked && match?.bot == null && !match?.next_match_id && mySide,
  )
  // They have missed three of their own turns in a row. Nothing has been
  // decided by that -- it only puts a button in front of the other player.
  const theyAreAway = Boolean(
    theirSide && state?.away === theirSide && match?.status === 'active' && match?.bot == null,
  )
  const botTurn = Boolean(
    match?.bot != null && match.status === 'active' && state?.turn === 'guest' && !state?.winner,
  )

  // The turn's budget. It belongs to whoever is to move -- there is only one
  // of it -- so this is as true while you are watching them spend it as while
  // you are spending it yourself.
  const actsCapNow = state ? actsCap(state) : 2
  const actsSpent = Math.min(actsCapNow, state?.acts ?? 0)
  const actsLeft = actsCapNow - actsSpent

  const onClock = match?.status === 'active' || deploying
  const clockLength = deploying ? DEPLOY_SECONDS : TURN_SECONDS
  const remaining = useMemo(() => {
    if (!match?.turn_deadline || !onClock) return null
    return (new Date(match.turn_deadline).getTime() - (now + clockOffset)) / 1000
  }, [match?.turn_deadline, onClock, now, clockOffset])

  // Nobody is running a game server, so the clients enforce the clock by
  // *asking* the database to expire the turn. The function refuses unless the
  // deadline has genuinely passed according to Postgres, so this is safe to
  // call from either player or from a spectator.
  useEffect(() => {
    if (!match || !onClock || remaining === null) return
    const stamp = `${match.id}:${match.status}:${state?.turnNumber}`
    if (remaining < -2 && firedFor.current !== stamp) {
      firedFor.current = stamp
      forceTimeout(match.id).then(refresh)
    }
  }, [remaining, match, onClock, state?.turnNumber, refresh])

  useEffect(() => {
    if (!matchId || match?.status !== 'deploying') { setMyUnits(null); return }
    let alive = true
    myDeploy(matchId).then((u) => { if (alive) setMyUnits(u) })
    return () => { alive = false }
  }, [matchId, match?.status])

  // The bot plays one action per call, on a delay, so you watch it think
  // instead of finding its whole turn already done. Every step is a fresh
  // decision made by the server against the board as it now stands -- there is
  // no plan held anywhere on this side. `updated_at` changing is what schedules
  // the next one, so the chain stops on its own the moment the turn flips back.
  useEffect(() => {
    if (!botTurn || !match) return
    const id = setTimeout(() => botStep(match.id).then(refresh), 650)
    return () => clearTimeout(id)
  }, [botTurn, match?.id, match?.updated_at, refresh])

  // The rematch is signalled by the finished room pointing at a new one, which
  // arrives over the realtime subscription we are already holding. Whoever
  // asked second created it; both sides get here the same way.
  //
  // The ref is what stops this from firing more than once for the same room,
  // and it is not paranoia. onGoTo used to be a fresh arrow on every App
  // render, so this effect re-ran on every render -- and the clock above
  // re-renders this component five times a second. Each run restarted the
  // crossing, whose swap lands at 310ms, so the swap never got to run: the
  // wipe block covered the screen and stayed there, matchId never changed,
  // and the condition below never went false. That was the blank white page
  // on a practice rematch. onGoTo is stable now and the crossing ignores a
  // second call, but this is the guard that says the intent out loud: go to a
  // given room once.
  const wentTo = useRef<string>('')
  useEffect(() => {
    const next = match?.next_match_id
    if (!next || next === matchId || wentTo.current === next) return
    wentTo.current = next
    leaveMatch(matchId)
    onGoTo(next)
  }, [match?.next_match_id, matchId, onGoTo])

  async function askRematch() {
    setErr(null)
    try {
      const next = await requestRematch(match!.id)
      if (next) goTo(next)
      else await refresh()
    } catch (e) {
      setErr((e as Error).message)
      setTimeout(() => setErr(null), 3500)
    }
  }

  // Clear the selection whenever the turn flips.
  useEffect(() => setSelected(null), [state?.turn, state?.turnNumber])

  // Two announcements, and both of them have to be careful about what counts
  // as news. A turn is news when it becomes yours and was not yours a moment
  // ago -- not on the first render, where the ref is seeded with whatever is
  // already true, or opening a match on your turn would chime at you, and so
  // would every reconnect. The result is news exactly once, for the same
  // reason: the winner sits in the row for as long as the room exists, so a
  // spectator arriving afterwards, or a refresh, must not replay the fanfare.
  const wasMine = useRef(isMyTurn)
  useEffect(() => {
    if (isMyTurn && !wasMine.current) playTurn()
    wasMine.current = isMyTurn
  }, [isMyTurn])

  const sang = useRef<Side | 'none' | null>(null)
  useEffect(() => {
    const won = state?.winner ?? null
    if (sang.current === null) { sang.current = won ?? 'none'; return }
    if (!won || sang.current === won) return
    sang.current = won
    // A spectator has no side to lose with, so they get the flourish either
    // way rather than a defeat that is not theirs.
    if (mySide === null || won === mySide) playWin()
    else playLose()
  }, [state?.winner, mySide])

  /** Leave for another room. Deliberately not wrapped in guard(): guard
   *  refreshes when it is done, and refreshing the room you have just walked
   *  out of is what used to drop the old finished match back on top of the new
   *  one. */
  function goTo(next: string) {
    leaveMatch(matchId)
    onGoTo(next)
  }

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

  // Your card opens on the left of the board, theirs on the right, so it never
  // reaches across the middle and never lands on the rail beside it. A tree
  // belongs to nobody, so it opens on the side of the board it is standing on.
  const board = shown ?? s
  const hoverUnit = hovered ? board.units.find((u) => u.id === hovered) : undefined
  const hoverTree = hovered ? (board.obstacles ?? []).find((o) => o.id === hovered) : undefined
  const hoverCard = hoverUnit ? (
    <UnitBigCard
      unit={hoverUnit}
      side={hoverUnit.owner === (mySide ?? 'host') ? 'left' : 'right'}
    />
  ) : hoverTree ? (
    <TreeBigCard
      tree={hoverTree}
      // Drawn column, not board column: the host sees the board half a turn
      // round, so a tree on their left is a tree at high x. Board.tsx owns the
      // flip, and this is the one other place a coordinate reaches the screen
      // -- which is why the rule itself lives in flipFor() and neither of them
      // spells it out.
      side={
        (flipFor(mySide) ? board.board.w - 1 - hoverTree.x : hoverTree.x)
          < Math.floor(board.board.w / 2) ? 'left' : 'right'
      }
    />
  ) : null

  const pct = remaining === null ? 0 : Math.max(0, Math.min(1, remaining / clockLength))
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

      {onClock && (
        <div className={`turnbar ${urgent ? 'urgent' : ''}`}>
          <div className="timerbar">
            <div className="timerfill" style={{ width: `${pct * 100}%` }} />
          </div>
          <div className="timertext">
            {deploying
              ? mySide
                ? iAmReady ? 'Waiting for your opponent' : 'Place your units'
                : 'Both sides are deploying'
              : botTurn
                ? `${match.guest_name} is thinking`
              : isMyTurn
                ? 'Your turn'
                : mySide
                  ? 'Opponent thinking'
                  : `${s.turn === 'host' ? match.host_name : match.guest_name} to act`}
            {' · '}
            {Math.max(0, Math.ceil(remaining ?? 0))}s
          </div>

          {/* The two goes. Nothing on screen used to say how many were left,
              which made the server's refusal ("no actions left this turn") the
              first time you heard about the rule. The opening turn has one pip
              rather than two, because it really does have one activation. */}
          {match.status === 'active' && !s.winner && (
            <div
              className="goes"
              role="img"
              aria-label={`${actsLeft} of ${actsCapNow} ${actsCapNow === 1 ? 'go' : 'goes'} left`}
              title={
                (isMyTurn ? 'Your turn: ' : 'Their turn: ') +
                `${actsLeft} of ${actsCapNow} left. One go is one unit's move and strike together.`
              }
            >
              {Array.from({ length: actsCapNow }, (_, i) => (
                <span key={i} className={`go${i < actsSpent ? ' is-used' : ''}`} />
              ))}
            </div>
          )}
        </div>
      )}

      <div className="stage">
        <Chat
          matchId={match.id}
          profile={profile}
          messages={messages}
          role={mySide ? 'player' : 'spectator'}
          open={rail === 'chat'}
        />

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
              <div className="arena">
                {hoverCard}
                <Board
                  state={shown ?? s}
                  mySide={mySide}
                  isMyTurn={isMyTurn}
                  deploying={Boolean(deploying && !iAmReady)}
                  selectedId={selected}
                  onSelect={setSelected}
                  onMove={(x, y) => selected && guard(() => submitMove(match.id, selected, x, y))}
                  onAttack={(target) => selected && guard(() => submitAttack(match.id, selected, target))}
                  onDefend={(unitId) => guard(() => submitDefend(match.id, unitId))}
                  onWait={() => guard(() => submitWait(match.id))}
                  onDeploy={(id, x, y) =>
                    guard(async () => setMyUnits(await deployUnit(match.id, id, x, y)))
                  }
                  onHover={setHovered}
                />
              </div>

              {/* Hover is how you read a card on a desktop, and phones do not
                  have it. Tapping already selects, so the selection doubles as
                  the way to inspect -- which helps on desktop too, since you
                  can read a unit while planning instead of only while pointing
                  at it. */}
              {selectedUnit ? (
                <div className="unitbar" style={{ '--accent': selectedUnit.accent } as React.CSSProperties}>
                  <span className="unitbar-name">{selectedUnit.name}</span>
                  <span className="unitbar-stats">
                    <b>{selectedUnit.hp}</b>/{selectedUnit.maxHp} HP
                    <i /><b>{unitPower(selectedUnit)}</b>{' '}
                    {selectedUnit.heals ? 'PWR' : 'DMG'}
                    <i /><b>{selectedUnit.mov}</b> MOV
                    <i /><b>{reachText(selectedUnit.rmin, selectedUnit.rmax)}</b> RNG
                  </span>
                  {selectedUnit.ability && <span className="unitbar-ability">{selectedUnit.ability}</span>}
                </div>
              ) : (
                /* Mounted even when nothing is selected. If it came and went
                   with the selection it would resize the arena on every tap,
                   and the board would jump under your thumb. */
                <div className="unitbar is-empty">
                  <span className="unitbar-stats">
                    {mySide ? 'Pick a unit to read it' : 'Pick a unit to read it'}
                  </span>
                </div>
              )}

              {/* Three missed turns is a fact, not a verdict. The server will
                  only hand you the win once they have actually dropped -- or
                  after six -- so the button says what it will try and any
                  refusal is shown where it was clicked instead of vanishing. */}
              {theyAreAway && (
                <div className="awaybar">
                  <p>
                    <b>{theirSide === 'host' ? match.host_name : match.guest_name}</b> has not acted
                    for three turns. If they have dropped, the match is yours.
                  </p>
                  <button className="btn small" onClick={() => guard(() => claimWin(match.id))}>
                    Claim the win
                  </button>
                </div>
              )}

              <div className="actionbar">
                {s.winner ? (
                  <>
                    <div className="verdict">
                      {(s.winner === 'host' ? match.host_name : match.guest_name) ?? 'Someone'} wins
                      {s.winner === mySide ? ' — that is you.' : '.'}
                    </div>
                    <button className="btn primary" disabled={iAsked} onClick={askRematch}>
                      {iAsked ? 'Waiting for them…' : 'Rematch'}
                    </button>
                    <span className="hint">
                      {match.bot != null
                        ? 'Starts a fresh board against the same opponent.'
                        : iAsked
                          ? 'It starts the moment they accept. Sides swap.'
                          : match.rematch_declined
                            ? 'They passed on the last one. You can ask again.'
                            : 'Both of you have to want it.'}
                    </span>
                  </>
                ) : deploying ? (
                  mySide ? (
                    <>
                      <button
                        className="btn primary"
                        disabled={iAmReady}
                        onClick={() => guard(() => setReady(match.id))}
                      >
                        {iAmReady ? 'Waiting for them…' : 'Ready'}
                      </button>
                      <button className="btn ghost" onClick={() => guard(() => resignMatch(match.id))}>
                        Leave
                      </button>
                      <span className="hint">
                        {iAmReady
                          ? 'Locked in. It starts when they are ready too.'
                          : 'Pick a unit, then a lit tile. Drop on your own to swap.'}
                      </span>
                    </>
                  ) : (
                    <span className="hint">Both sides are placing their units.</span>
                  )
                ) : mySide ? (
                  <>
                    <button className="btn primary" onClick={() => guard(() => endTurn(match.id))} disabled={!isMyTurn}>
                      End turn
                    </button>
                    <button className="btn ghost" onClick={() => guard(() => resignMatch(match.id))}>
                      Resign
                    </button>
                    <span className="hint">
                      {!isMyTurn
                        ? 'Waiting for your opponent.'
                        : actsLeft === 0
                          ? 'No goes left. End your turn.'
                          : `Pick a unit, then choose from its menu. ${actsLeft} of ` +
                            `${actsCapNow} ${actsCapNow === 1 ? 'go' : 'goes'} left.`}
                    </span>
                  </>
                ) : (
                  <span className="hint">
                    Spectating — you can chat, but the board isn&rsquo;t yours.
                  </span>
                )}
              </div>
            </>
          )}
          {/* Deliberately not a modal: no backdrop, nothing dimmed, nothing you are
          forced to answer before you can look at the board again. It sits over
          the middle, and if you ignore it the match screen is still yours. */}
      {challenged && (
        <div className="challenge" role="status">
          <p className="challenge-text">
            <b>{theirSide === 'host' ? match.host_name : match.guest_name}</b> wants a rematch!
          </p>
          <div className="challenge-acts">
            <button className="btn primary small" onClick={askRematch}>Let&rsquo;s battle!</button>
            <button
              className="btn small"
              onClick={() => guard(() => declineRematch(match.id))}
            >
              Not today
            </button>
          </div>
        </div>
      )}

      {err && <div className="toast">{err}</div>}
        </main>

        <BattleLog log={s.log} open={rail === 'log'} />

        <nav className="railtabs" role="tablist" aria-label="Side panels">
          <button
            role="tab"
            aria-selected={rail === 'chat'}
            onClick={() => setRail((r) => (r === 'chat' ? null : 'chat'))}
          >
            Chat{messages.length > 0 ? ` (${messages.length})` : ''}
          </button>
          <button
            role="tab"
            aria-selected={rail === 'log'}
            onClick={() => setRail((r) => (r === 'log' ? null : 'log'))}
          >
            Battle log
          </button>
        </nav>
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
