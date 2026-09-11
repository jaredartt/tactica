import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import {
  createBotMatch, createMatch, joinMatch, leaveRanked, rankedTick,
  setDeck as setDeck_, sweepMatches,
} from '../lib/api'
import { Comics } from './Comics'
import {
  BOT_LEVELS, DECK_SIZE, reachText, tierOf,
  type Card, type LadderRow, type MatchRow, type Profile,
} from '../lib/types'
import { artUrl } from '../lib/art'
import { Avatar } from './Avatar'
import { IconGear } from './Icons'
import { Logo } from './Logo'
import { ProfileCard } from './ProfileCard'
import { SettingsCard } from './SettingsCard'
import { Page, useZoom } from './Zoom'

interface Props {
  profile: Profile
  onEnter: (matchId: string) => void
  /** The lobby owns the profile panel, so it is the lobby that reports a new
   *  name or face back up to whoever is holding the profile. */
  onProfile: (patch: Partial<Profile>) => void
}

/** Every destination: its colour, the picture behind it, and where its tile
 *  sits. The colour is used three times -- washed over the picture, on the
 *  block that flies out of the tile, and on the band at the top of the page it
 *  lands on -- which is what ties the three together.
 *
 *  `focus` is where the picture is anchored inside a tile far wider than the
 *  picture is: a lower number shows more of the top of it. It is per tile
 *  because these are drawings of people, and one number that keeps every head
 *  on screen does not exist -- the ladder's is a square portrait in a letterbox
 *  and the practice one is a figure standing at the top of a staircase.
 *
 *  Ranked has no picture yet, so its tile is the flat colour until one lands
 *  in public/menu/. A missing background is invisible, not broken. */
const TILES = [
  { id: 'ranked',   label: 'Ranked',     tint: '#d92d20', art: 'menu/ranked.webp',   focus: '22%',
    note: 'Play for a place on the ladder' },
  { id: 'bot',      label: 'Practice',   tint: '#e8701a', art: 'menu/practice.webp', focus: '0%',
    note: 'Spar with the machine' },
  { id: 'friends',  label: 'Vs Friends', tint: '#d9a41b', art: 'menu/friends.webp',  focus: '28%',
    note: 'Open a room, or join one' },
  { id: 'spectate', label: 'Watch',      tint: '#2f9e52', art: 'menu/watch.webp',    focus: '32%',
    note: 'Look in on a live match' },
  { id: 'ladder',   label: 'Ladder',     tint: '#2f4bff', art: 'cards/dereo.webp',   focus: '14%',
    note: 'Who is on top' },
  { id: 'team',     label: 'My Kingdom',    tint: '#7c3aed', art: 'menu/team.webp',     focus: '26%',
    note: 'Five of the eleven' },
  { id: 'comics',   label: 'Comics',     tint: '#0f8b8d', art: 'menu/comics.webp',   focus: '4%',
    note: 'The story behind the board' },
] as const

type PageId = (typeof TILES)[number]['id']

export function Lobby({ profile, onEnter, onProfile }: Props) {
  const { zoomTo, close, page, zoomer } = useZoom()
  const [rooms, setRooms] = useState<MatchRow[]>([])
  const [roster, setRoster] = useState<Card[]>([])
  const [ladder, setLadder] = useState<LadderRow[]>([])
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [deck, setDeckDraft] = useState<string[]>(profile.deck ?? [])
  const [savedDeck, setSavedDeck] = useState<string[]>(profile.deck ?? [])
  const [saving, setSaving] = useState(false)

  // queue
  const [overlay, setOverlay] = useState<null | 'profile' | 'settings'>(null)

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
      // Practice is not a spectacle. A bot match is you and a machine, so it
      // is left off the list entirely -- the room still exists and its code
      // still works, so a friend you hand it to can walk in and watch. It is
      // simply not advertised.
      const { data } = await supabase
        .from('matches').select('*')
        .in('status', ['waiting', 'deploying', 'active'])
        .is('bot', null)
        .order('created_at', { ascending: false }).limit(20)
      if (alive && data) setRooms(data as MatchRow[])
    }
    load()
    const id = setInterval(load, 4000)
    return () => { alive = false; clearInterval(id) }
  }, [page])

  useEffect(() => {
    if (page !== 'team' || roster.length) return
    supabase.from('cards').select('*').eq('is_active', true).order('sort')
      .then(({ data }) => data && setRoster(data as Card[]))
  }, [page, roster.length])

  useEffect(() => {
    if (page !== 'ladder') return
    supabase.from('leaderboard').select('*')
      .order('lp', { ascending: false }).order('wins', { ascending: false }).limit(50)
      .then(({ data }) => data && setLadder(data as LadderRow[]))
  }, [page])

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

  // A team saved before the roster changed still sits in profiles.deck, slug
  // for slug -- the server never rewrites it, it just refuses to field it and
  // hands back the default instead. So the draft has to be cleaned when the
  // roster arrives, or My Team shows "5/5 chosen" over a grid where four of
  // the five are cards that no longer exist and only one has a number on it.
  useEffect(() => {
    if (!roster.length) return
    const have = new Set(roster.map((c) => c.slug))
    setDeckDraft((d) => (d.every((s) => have.has(s)) ? d : d.filter((s) => have.has(s))))
    setSavedDeck((d) => (d.every((s) => have.has(s)) ? d : d.filter((s) => have.has(s))))
  }, [roster])

  // Mirrors deck_of(): a card retired from the roster invalidates the whole
  // team, and the server quietly fields the default instead. If the client did
  // not agree, this page would claim a team was saved while the match used
  // something else.
  const live = new Set(roster.map((c) => c.slug))
  const deckSet = savedDeck.length === DECK_SIZE && savedDeck.every((s) => live.has(s))
  const effectiveDeck = deckSet ? savedDeck : roster.slice(0, DECK_SIZE).map((c) => c.slug)

  function toggleCard(slug: string) {
    setErr(null)
    setDeckDraft((d) =>
      d.includes(slug) ? d.filter((s) => s !== slug)
      : d.length >= DECK_SIZE ? d : [...d, slug])
  }

  /**
   * There is no Save button: a team saves itself the moment it is a team.
   *
   * set_deck takes exactly a full team, so a short draft is not something the
   * server can hold -- which turns out to be the right behaviour rather than a
   * limitation. Taking a card out leaves the LAST saved team in place, so
   * wandering off mid-swap keeps the team you actually had, and putting the
   * missing one back is what commits the change. A swap is one write.
   *
   * A write is a single-row update on your own profile row. Supabase meters
   * storage and egress, not statements, so this costs nothing that a button
   * would have saved.
   */
  const sent = useRef('')
  useEffect(() => {
    if (deck.length !== DECK_SIZE) return
    const key = deck.join()
    if (key === savedDeck.join() || key === sent.current) return
    sent.current = key
    setSaving(true); setErr(null)
    setDeck_(deck)
      .then((d) => setSavedDeck(d))
      .catch((e) => { setErr((e as Error).message); sent.current = '' })
      .finally(() => setSaving(false))
  }, [deck, savedDeck])

  const tile = TILES.find((t) => t.id === page)
  const title = (id: PageId) =>
    id === 'ranked' ? 'Ranked' : id === 'bot' ? 'Practice' : id === 'friends' ? 'Vs Friends'
    : id === 'team' ? 'My Kingdom' : id === 'comics' ? 'Comics'
    : id === 'spectate' ? 'Live matches' : 'Ladder'

  return (
    <div className="menu">
      <header className="menu-head">
        <div className="brand">
          <Logo className="logo" title="Crown Nemesis" />
          <h1 className="wordmark small">CROWN NEMESIS</h1>
        </div>
        <div className="menu-who">
          {/* One button, not two: the face and the name are the same thing to
              point at, and splitting them would make the smaller of the two a
              target you have to aim for. */}
          <button className="whoami" onClick={() => setOverlay('profile')}>
            <Avatar slug={profile.avatar} name={profile.username} size={30} />
            <span className="whoami-name">{profile.username}</span>
            {profile.games > 0 && (
              <span className="ownrank">{tierOf(profile.lp)} {profile.lp}</span>
            )}
          </button>
          <button className="iconbtn" onClick={() => setOverlay('settings')} aria-label="Settings">
            <IconGear />
          </button>
        </div>
      </header>

      <nav className="menu-grid">
        {TILES.map((t) => (
          <button
            key={t.id}
            className={`mtile mt-${t.id}`}
            style={{ '--tint': t.tint } as React.CSSProperties}
            disabled={busy}
            onClick={(e) => zoomTo(e.currentTarget, { id: t.id, tint: t.tint })}
          >
            {/* Three layers: the picture, the colour laid over it, and the
                words. The picture is counter-skewed and overscaled so the lean
                never exposes a corner, and it is the only thing that moves on
                hover -- the tile itself holds still and its colour thins out. */}
            <span
              className="mtile-art"
              style={{
                backgroundImage: `url(${import.meta.env.BASE_URL}${t.art})`,
                backgroundPosition: `center ${t.focus}`,
              }}
              aria-hidden="true"
            />
            <span className="mtile-wash" aria-hidden="true" />
            <span className="mtile-inner">
              <span className="mtile-label">{t.label}</span>
              <span className="mtile-note">
                {t.id === 'team' && !deckSet ? 'Not chosen yet'
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

      {overlay === 'profile' && (
        <ProfileCard profile={profile} onClose={() => setOverlay(null)} onChanged={onProfile} />
      )}
      {overlay === 'settings' && <SettingsCard onClose={() => setOverlay(null)} />}

      {page && tile && (
        <Page title={title(tile.id)} tint={tile.tint} onClose={close} wide={page === 'team'}>
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
                  You have not picked a deck, so you will field {effectiveDeck.join(', ') || 'the default five'}.
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
                It brings five random cards and plays by exactly the rules you do. Nothing here
                touches your rating.
              </p>
            </div>
          )}

          {/* Opening a room and joining one used to be two tiles, which made
              the menu ask a question nobody has: whether you are the host. You
              want to play a specific person; one of you sends five letters. */}
          {page === 'friends' && (
            <div className="modelist">
              <button className="modecard" disabled={busy} onClick={() => run(createMatch)}>
                <span className="modecard-name">Open a room</span>
                <span className="modecard-note">
                  You get a five-letter code. Send it to whoever you want to play.
                </span>
              </button>
              <div className="orline"><span>or</span></div>
              <form
                className="joinform"
                onSubmit={(e) => { e.preventDefault(); if (code.trim()) run(() => joinMatch(code)) }}
              >
                <input
                  className="codeinput" value={code} maxLength={5} aria-label="Room code"
                  onChange={(e) => setCode(e.target.value.toUpperCase())} placeholder="CODE"
                />
                <button className="btn primary" disabled={busy || !code.trim()}>Join</button>
              </form>
              <p className="muted tiny queuenote">
                Nothing you play here touches anybody's rating. That is what Ranked is for.
              </p>
            </div>
          )}

          {page === 'comics' && <Comics />}

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

          {/* The roster, edge to edge, art and nothing else -- you pick your
              five by recognising them, the way you pick a fighter. Everything
              a card can do is one hover away, laid over a darkened version of
              the same picture so the words have something to sit on. */}
          {page === 'team' && (
            <div className="teamwrap">
              <div className="roster-grid">
                {roster.map((c) => {
                  const picked = deck.includes(c.slug)
                  const full = deck.length >= DECK_SIZE
                  return (
                    <button
                      key={c.id} type="button" aria-pressed={picked}
                      aria-label={`${c.name}, ${c.role}`}
                      className={`rtile${picked ? ' is-picked' : ''}${!picked && full ? ' is-spare' : ''}`}
                      style={{ '--accent': c.accent } as React.CSSProperties}
                      onClick={() => toggleCard(c.slug)}
                    >
                      <span
                        className="rtile-art"
                        style={{ backgroundImage: `url(${artUrl(c.art_url) ?? ''})` }}
                        aria-hidden="true"
                      />
                      {picked && <span className="rtile-pick">{deck.indexOf(c.slug) + 1}</span>}
                      <span className="rtile-name">{c.name}</span>

                      <span className="rtile-info">
                        <span className="rti-head">
                          <b>{c.name}</b>
                          {c.role && <em>{c.role}</em>}
                        </span>
                        <span className="rti-stats">
                          <span><i>HP</i><b>{c.hp}</b></span>
                          <span><i>{c.heals ? 'PWR' : 'DMG'}</i><b>{c.dmin}–{c.dmax}</b></span>
                          <span><i>MOV</i><b>{c.mov}</b></span>
                          <span><i>RNG</i><b>{reachText(c.rmin, c.rmax)}</b></span>
                          <span><i>CTR</i><b>{reachText(c.crmin, c.crmax)}</b></span>
                        </span>
                        {c.ability && <span className="rti-ability">{c.ability}</span>}
                        <span className="rti-cta">
                          {picked ? 'Remove' : full ? 'Kingdom is full' : 'Add to kingdom'}
                        </span>
                      </span>
                    </button>
                  )
                })}
              </div>

              <div className="deckfoot">
                <span className="muted tiny">
                  {deck.length}/{DECK_SIZE} chosen
                  {deck.length < DECK_SIZE && deckSet &&
                    ` — still fielding ${savedDeck.join(', ')} until the kingdom is full`}
                  {deck.length < DECK_SIZE && !deckSet &&
                    ` — you field ${effectiveDeck.join(', ')} until you pick ${DECK_SIZE}`}
                </span>
                <span className={`savemark${saving ? ' is-busy' : ''}`}>
                  {saving ? 'Saving…'
                   : deck.length === DECK_SIZE && deck.join() === savedDeck.join() ? 'Saved'
                   : ''}
                </span>
              </div>
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
