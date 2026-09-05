import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import {
  createBotMatch, createMatch, joinMatch, leaveRanked, rankedTick, setDeck, sweepMatches,
} from '../lib/api'
import {
  BOT_LEVELS, DECK_SIZE, reachText, tierOf,
  type Card, type LadderRow, type MatchRow, type Profile,
} from '../lib/types'
import { Logo } from './Logo'
import { Page, useZoom } from './Zoom'

interface Props {
  profile: Profile
  onEnter: (matchId: string) => void
}

/** Every destination, its colour, and where its tile sits. The colour is used
 *  three times -- the tile, the block that flies out of it, and the band at the
 *  top of the page it lands on -- which is what ties the three together. */
const TILES = [
  { id: 'ranked',   label: 'Ranked',   tint: '#2f4bff', note: 'Play for a place on the ladder' },
  { id: 'bot',      label: 'Practice', tint: '#0e0e14', note: 'Spar with the machine' },
  { id: 'host',     label: 'Host',     tint: '#ff2e93', note: 'Open a room, send the code' },
  { id: 'join',     label: 'Join',     tint: '#7c3aed', note: 'Five letters from a friend' },
  { id: 'deck',     label: 'Deck',     tint: '#10b981', note: 'Four of the six' },
  { id: 'roster',   label: 'Roster',   tint: '#f59e0b', note: 'Every card in the game' },
  { id: 'spectate', label: 'Watch',    tint: '#0ea5e9', note: 'Look in on a live match' },
  { id: 'ladder',   label: 'Ladder',   tint: '#111827', note: 'Who is on top' },
] as const

type PageId = (typeof TILES)[number]['id']

export function Lobby({ profile, onEnter }: Props) {
  const { zoomTo, close, page, zoomer } = useZoom()
  const [rooms, setRooms] = useState<MatchRow[]>([])
  const [roster, setRoster] = useState<Card[]>([])
  const [ladder, setLadder] = useState<LadderRow[]>([])
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [deck, setDeckDraft] = useState<string[]>(profile.deck ?? [])
  const [savedDeck, setSavedDeck] = useState<string[]>(profile.deck ?? [])

  // queue
  const [searching, setSearching] = useState(false)
  const [waiting, setWaiting] = useState(0)
  const [elapsed, setElapsed] = useState(0)
  const since = useRef(0)

  const run = useCallback(
    async (fn: () => Promise<{ id: string }>) => {
      setBusy(true); setErr(null)
      try { onEnter((await fn()).id) } catch (e) { setErr((e as Error).message); close() }
      finally { setBusy(false) }
    },
    [onEnter, close],
  )

  // ---- room list, for the watch page --------------------------------------
  useEffect(() => {
    if (page !== 'spectate') return
    let alive = true
    const load = async () => {
      await sweepMatches()
      const { data } = await supabase
        .from('matches').select('*')
        .in('status', ['waiting', 'deploying', 'active'])
        .order('created_at', { ascending: false }).limit(20)
      if (alive && data) setRooms(data as MatchRow[])
    }
    load()
    const id = setInterval(load, 4000)
    return () => { alive = false; clearInterval(id) }
  }, [page])

  useEffect(() => {
    if ((page !== 'roster' && page !== 'deck') || roster.length) return
    supabase.from('cards').select('*').eq('is_active', true).order('sort')
      .then(({ data }) => data && setRoster(data as Card[]))
  }, [page, roster.length])

  useEffect(() => {
    if (page !== 'ladder') return
    supabase.from('leaderboard').select('*')
      .order('lp', { ascending: false }).order('wins', { ascending: false }).limit(50)
      .then(({ data }) => data && setLadder(data as LadderRow[]))
  }, [page])

  // ---- hosting happens on arrival, so the zoom is the loading screen -------
  useEffect(() => {
    if (page === 'host') run(createMatch)
  }, [page, run])

  // ---- the queue -----------------------------------------------------------
  useEffect(() => {
    if (!searching) return
    let alive = true
    const tick = async () => {
      try {
        const q = await rankedTick()
        if (!alive) return
        setWaiting(q.waiting)
        if (q.match) { setSearching(false); onEnter(q.match) }
      } catch (e) {
        if (alive) { setErr((e as Error).message); setSearching(false) }
      }
    }
    tick()
    const poll = setInterval(tick, 2000)
    const clock = setInterval(() => setElapsed(Math.floor((Date.now() - since.current) / 1000)), 500)
    return () => { alive = false; clearInterval(poll); clearInterval(clock) }
  }, [searching, onEnter])

  // Leaving the page, or the app, drops you out rather than leaving a ghost in
  // the queue for someone to be paired against.
  useEffect(() => {
    if (page !== 'ranked' && searching) { setSearching(false); leaveRanked() }
  }, [page, searching])
  useEffect(() => {
    const bye = () => { if (searching) leaveRanked() }
    window.addEventListener('pagehide', bye)
    return () => { window.removeEventListener('pagehide', bye); bye() }
  }, [searching])

  const deckSet = savedDeck.length === DECK_SIZE
  const effectiveDeck = deckSet ? savedDeck : roster.slice(0, DECK_SIZE).map((c) => c.slug)

  function toggleCard(slug: string) {
    setErr(null)
    setDeckDraft((d) =>
      d.includes(slug) ? d.filter((s) => s !== slug)
      : d.length >= DECK_SIZE ? d : [...d, slug])
  }

  async function saveDeck() {
    setBusy(true); setErr(null)
    try { setSavedDeck(await setDeck(deck)) }
    catch (e) { setErr((e as Error).message) }
    finally { setBusy(false) }
  }

  const tile = TILES.find((t) => t.id === page)
  const title = (id: PageId) =>
    id === 'ranked' ? 'Ranked' : id === 'bot' ? 'Practice' : id === 'host' ? 'Opening a room'
    : id === 'join' ? 'Join by code' : id === 'deck' ? 'Your deck'
    : id === 'roster' ? 'The roster' : id === 'spectate' ? 'Live matches' : 'Ladder'

  return (
    <div className="menu">
      <header className="menu-head">
        <div className="brand">
          <Logo className="logo" title="Crown Nemesis" />
          <h1 className="wordmark small">CROWN NEMESIS</h1>
        </div>
        <div className="menu-who">
          <span className="muted">
            {profile.username}
            {profile.games > 0 && (
              <>{' · '}<b className="ownrank">{tierOf(profile.lp)} {profile.lp}</b></>
            )}
          </span>
          <button className="linkbtn" onClick={() => supabase.auth.signOut()}>Sign out</button>
        </div>
      </header>

      <nav className="menu-grid">
        {TILES.map((t) => (
          <button
            key={t.id}
            className={`mtile mt-${t.id}`}
            style={{ background: t.tint }}
            disabled={busy}
            onClick={(e) => zoomTo(e.currentTarget, { id: t.id, tint: t.tint })}
          >
            <span className="mtile-inner">
              <span className="mtile-label">{t.label}</span>
              <span className="mtile-note">
                {t.id === 'deck' && !deckSet ? 'Not chosen yet'
                 : t.id === 'ladder' && profile.games > 0
                   ? `You are ${tierOf(profile.lp)} on ${profile.lp} LP`
                   : t.note}
              </span>
            </span>
          </button>
        ))}
      </nav>

      {err && <p className="error menu-err">{err}</p>}
      {zoomer}

      {page && tile && (
        <Page title={title(tile.id)} tint={tile.tint} onClose={close}>
          {page === 'ranked' && (
            <div className="modelist">
              <button
                className={`modecard${searching ? ' is-live' : ''}`}
                onClick={() => { since.current = Date.now(); setElapsed(0); setSearching(true) }}
                disabled={searching}
              >
                <span className="modecard-name">1 vs 1</span>
                <span className="modecard-note">
                  {searching
                    ? `Looking for an opponent… ${elapsed}s · ${waiting} in the queue`
                    : 'Paired with someone near your level. The only mode that moves your LP.'}
                </span>
              </button>
              {searching && (
                <>
                  <p className="muted tiny queuenote">
                    The first minute looks for someone close to you. After that it stops being
                    fussy, so a wide gap still finds a game.
                  </p>
                  <button className="btn ghost" onClick={() => { setSearching(false); leaveRanked() }}>
                    Cancel
                  </button>
                </>
              )}
              {!deckSet && (
                <p className="muted tiny queuenote">
                  You have not picked a deck, so you will field {effectiveDeck.join(', ') || 'the default four'}.
                </p>
              )}
            </div>
          )}

          {page === 'bot' && (
            <div className="modelist">
              {BOT_LEVELS.map((b) => (
                <button
                  key={b.level}
                  className="modecard"
                  disabled={busy}
                  onClick={() => run(() => createBotMatch(b.level))}
                >
                  <span className="modecard-name">{b.name}</span>
                  <span className="modecard-note">{b.note}</span>
                </button>
              ))}
              <p className="muted tiny queuenote">
                It brings four random cards and plays by exactly the rules you do. Nothing here
                touches your rating.
              </p>
            </div>
          )}

          {page === 'host' && <p className="muted">Opening a room…</p>}

          {page === 'join' && (
            <form
              className="joinform"
              onSubmit={(e) => { e.preventDefault(); if (code.trim()) run(() => joinMatch(code)) }}
            >
              <input
                className="codeinput" value={code} autoFocus maxLength={5} aria-label="Room code"
                onChange={(e) => setCode(e.target.value.toUpperCase())} placeholder="CODE"
              />
              <button className="btn primary" disabled={busy || !code.trim()}>Join</button>
            </form>
          )}

          {page === 'spectate' && (
            <>
              {rooms.length === 0 && <p className="muted">Nothing running right now.</p>}
              <ul className="roomlist">
                {rooms.map((r) => {
                  const mine = r.host_id === profile.id || r.guest_id === profile.id
                  const open = r.status === 'waiting' && !mine
                  return (
                    <li key={r.id}>
                      <span className="code">{r.code}</span>
                      <span className="names">
                        {r.host_name}
                        {r.guest_name ? ` vs ${r.guest_name}` : ' — waiting for an opponent'}
                      </span>
                      <span className={`pill ${r.status}`}>{r.status}</span>
                      <button
                        className="btn small" disabled={busy}
                        onClick={() => (open ? run(() => joinMatch(r.code)) : onEnter(r.id))}
                      >
                        {mine ? 'Return' : open ? 'Join' : 'Watch'}
                      </button>
                    </li>
                  )
                })}
              </ul>
            </>
          )}

          {page === 'deck' && (
            <>
              <p className="muted deckintro">
                Four of the six, no repeats. Both armies are on the board before the first turn,
                and you arrange yours then.
              </p>
              <div className="deckgrid">
                {roster.map((c) => {
                  const picked = deck.includes(c.slug)
                  return (
                    <button
                      key={c.id} type="button" aria-pressed={picked}
                      className={`dcard${picked ? ' is-picked' : ''}`}
                      style={{ '--accent': c.accent } as React.CSSProperties}
                      onClick={() => toggleCard(c.slug)}
                    >
                      <span className="dcard-pick">{picked ? deck.indexOf(c.slug) + 1 : ''}</span>
                      <span className="dcard-art">
                        {c.art_url ? <img src={c.art_url} alt="" /> : <span>{c.name[0]}</span>}
                      </span>
                      <span className="dcard-name">{c.name}</span>
                      <span className="dcard-stats">
                        <b>{c.hp} HP</b>
                        <b>{c.dmin}–{c.dmax} {c.heals ? 'PWR' : 'DMG'}</b>
                        <b>MOV {c.mov}</b>
                        <b>RNG {reachText(c.rmin, c.rmax)}</b>
                      </span>
                      <span className="dcard-ability">{c.ability}</span>
                    </button>
                  )
                })}
              </div>
              <div className="deckfoot">
                <span className="muted tiny">
                  {deck.length}/{DECK_SIZE} chosen
                  {!deckSet && ` — until you save, you field ${effectiveDeck.join(', ')}`}
                </span>
                <button
                  className="btn primary"
                  disabled={busy || deck.length !== DECK_SIZE || deck.join() === savedDeck.join()}
                  onClick={saveDeck}
                >
                  {deck.join() === savedDeck.join() && deckSet ? 'Saved' : 'Save deck'}
                </button>
              </div>
            </>
          )}

          {page === 'roster' && (
            <div className="rosterlist">
              {roster.map((c) => (
                <article key={c.id} className="rcard" style={{ '--accent': c.accent } as React.CSSProperties}>
                  <div className="rcard-art">
                    {c.art_url ? <img src={c.art_url} alt="" /> : <span>{c.name[0]}</span>}
                  </div>
                  <div className="rcard-body">
                    <h3>{c.name}</h3>
                    <dl className="rcard-stats">
                      <div><dt>HP</dt><dd>{c.hp}</dd></div>
                      <div><dt>{c.heals ? 'PWR' : 'DMG'}</dt><dd>{c.dmin}–{c.dmax}</dd></div>
                      <div><dt>MOV</dt><dd>{c.mov}</dd></div>
                      <div><dt>RNG</dt><dd>{reachText(c.rmin, c.rmax)}</dd></div>
                      <div><dt>CTR</dt><dd>{reachText(c.crmin, c.crmax)}</dd></div>
                    </dl>
                    {c.ability && <p>{c.ability}</p>}
                  </div>
                </article>
              ))}
            </div>
          )}

          {page === 'ladder' && (
            <>
              {ladder.length === 0 && <p className="muted">Nobody has finished a ranked match yet.</p>}
              {ladder.length > 0 && (
                <table className="ladder">
                  <thead>
                    <tr>
                      <th className="num">#</th><th>Player</th><th>Tier</th>
                      <th className="num">LP</th><th className="num">W</th>
                      <th className="num">L</th><th className="num">Streak</th>
                    </tr>
                  </thead>
                  <tbody>
                    {ladder.map((r, i) => (
                      <tr key={r.id} className={r.id === profile.id ? 'is-you' : ''}>
                        <td className="num rank">{i + 1}</td>
                        <td>{r.username}</td>
                        <td><span className={`tier t-${r.tier.toLowerCase()}`}>{r.tier}</span></td>
                        <td className="num lp">{r.lp}</td>
                        <td className="num">{r.wins}</td>
                        <td className="num">{r.losses}</td>
                        <td className={`num streak ${r.streak > 0 ? 'hot' : r.streak < 0 ? 'cold' : ''}`}>
                          {r.streak > 0 ? `${r.streak}W` : r.streak < 0 ? `${-r.streak}L` : '—'}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
              <p className="muted tiny laddernote">
                Only the ranked queue moves these numbers. Points scale with who you beat: taking
                down someone far above you is worth about 40, beating a beginner about 4, and
                losing to one costs the same 40. Once you reach a tier you cannot fall out of it
                this season.
              </p>
            </>
          )}
          {err && <p className="error">{err}</p>}
        </Page>
      )}
    </div>
  )
}
