import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { createMatch, joinMatch, setDeck, sweepMatches } from '../lib/api'
import {
  DECK_SIZE, reachText, tierOf,
  type Card, type LadderRow, type MatchRow, type Profile,
} from '../lib/types'
import { Logo } from './Logo'

type Panel = 'none' | 'join' | 'spectate' | 'roster' | 'ladder' | 'deck'

interface Props {
  profile: Profile
  onEnter: (matchId: string) => void
}

export function Lobby({ profile, onEnter }: Props) {
  const [panel, setPanel] = useState<Panel>('none')
  const [rooms, setRooms] = useState<MatchRow[]>([])
  const [roster, setRoster] = useState<Card[]>([])
  const [ladder, setLadder] = useState<LadderRow[]>([])
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  // The deck being edited. Starts from what is saved, or from whatever the
  // server would field on your behalf if you have never chosen.
  const [deck, setDeckDraft] = useState<string[]>(profile.deck ?? [])
  const [savedDeck, setSavedDeck] = useState<string[]>(profile.deck ?? [])

  async function loadRooms() {
    // Clear out rooms nobody is sitting in before showing the list, so the
    // lobby never advertises a room you cannot actually join.
    await sweepMatches()
    const { data } = await supabase
      .from('matches')
      .select('*')
      .in('status', ['waiting', 'deploying', 'active'])
      .order('created_at', { ascending: false })
      .limit(20)
    if (data) setRooms(data as MatchRow[])
  }

  useEffect(() => {
    loadRooms()
    const id = setInterval(loadRooms, 4000)
    return () => clearInterval(id)
  }, [])

  useEffect(() => {
    if ((panel !== 'roster' && panel !== 'deck') || roster.length) return
    supabase
      .from('cards')
      .select('*')
      .eq('is_active', true)
      .order('sort')
      .then(({ data }) => data && setRoster(data as Card[]))
  }, [panel, roster.length])

  useEffect(() => {
    if (panel !== 'ladder') return
    supabase
      .from('leaderboard')
      .select('*')
      .order('lp', { ascending: false })
      .order('wins', { ascending: false })
      .limit(50)
      .then(({ data }) => data && setLadder(data as LadderRow[]))
  }, [panel])

  async function run(fn: () => Promise<{ id: string }>) {
    setBusy(true)
    setErr(null)
    try {
      onEnter((await fn()).id)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const openCount = rooms.filter((r) => r.status === 'waiting' && r.host_id !== profile.id).length
  const deckSet = savedDeck.length === DECK_SIZE
  const effectiveDeck = deckSet ? savedDeck : roster.slice(0, DECK_SIZE).map((c) => c.slug)

  function toggleCard(slug: string) {
    setErr(null)
    setDeckDraft((d) =>
      d.includes(slug) ? d.filter((s2) => s2 !== slug)
      : d.length >= DECK_SIZE ? d
      : [...d, slug])
  }

  async function saveDeck() {
    setBusy(true); setErr(null)
    try {
      const saved = await setDeck(deck)
      setSavedDeck(saved)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="menu">
      <div className="menu-bg" aria-hidden="true" />

      <header className="menu-head">
        <div className="brand">
          <Logo className="logo" title="Crown Nemesis" />
          <h1 className="wordmark small">CROWN NEMESIS</h1>
        </div>
        <div className="menu-who">
          <span className="muted">
            {profile.username}
            {profile.games > 0 && (
              <>
                {' · '}
                <b className="ownrank">{tierOf(profile.lp)} {profile.lp}</b>
              </>
            )}
          </span>
          <button className="linkbtn" onClick={() => supabase.auth.signOut()}>Sign out</button>
        </div>
      </header>

      <nav className="menu-grid">
        <MenuTile
          className="mt-host"
          label="Host a room"
          note="Open an arena and send the code"
          disabled={busy}
          onClick={() => run(createMatch)}
        />
        <MenuTile
          className="mt-join"
          label="Join by code"
          note="Five letters from your opponent"
          active={panel === 'join'}
          onClick={() => setPanel(panel === 'join' ? 'none' : 'join')}
        />
        <MenuTile
          className="mt-spectate"
          label="Spectate"
          note={openCount > 0 ? `${rooms.length} live` : `${rooms.length} live`}
          active={panel === 'spectate'}
          onClick={() => setPanel(panel === 'spectate' ? 'none' : 'spectate')}
        />
        <MenuTile
          className="mt-deck"
          label="Deck"
          note={deckSet ? `${DECK_SIZE} chosen` : 'Not chosen yet'}
          active={panel === 'deck'}
          onClick={() => setPanel(panel === 'deck' ? 'none' : 'deck')}
        />
        <MenuTile
          className="mt-roster"
          label="Roster"
          note="Every card in the game"
          active={panel === 'roster'}
          onClick={() => setPanel(panel === 'roster' ? 'none' : 'roster')}
        />
        <MenuTile
          className="mt-ladder"
          label="Ladder"
          note={profile.games > 0 ? `You are ${tierOf(profile.lp)} on ${profile.lp} LP` : 'Play a match to be ranked'}
          active={panel === 'ladder'}
          onClick={() => setPanel(panel === 'ladder' ? 'none' : 'ladder')}
        />
      </nav>

      {err && <p className="error menu-err">{err}</p>}

      {panel === 'join' && (
        <section className="menu-panel">
          <form
            className="joinform"
            onSubmit={(e) => {
              e.preventDefault()
              if (code.trim()) run(() => joinMatch(code))
            }}
          >
            <input
              className="codeinput"
              value={code}
              onChange={(e) => setCode(e.target.value.toUpperCase())}
              placeholder="CODE"
              maxLength={5}
              autoFocus
              aria-label="Room code"
            />
            <button className="btn primary" disabled={busy || !code.trim()}>Join</button>
          </form>
        </section>
      )}

      {panel === 'spectate' && (
        <section className="menu-panel">
          {rooms.length === 0 && <p className="muted">Nothing running. Host a room and send the code to a friend.</p>}
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
                    className="btn small"
                    onClick={() => (open ? run(() => joinMatch(r.code)) : onEnter(r.id))}
                    disabled={busy}
                  >
                    {mine ? 'Return' : open ? 'Join' : 'Watch'}
                  </button>
                </li>
              )
            })}
          </ul>
        </section>
      )}

      {panel === 'ladder' && (
        <section className="menu-panel">
          {ladder.length === 0 && <p className="muted">Nobody has finished a match yet.</p>}
          {ladder.length > 0 && (
            <table className="ladder">
              <thead>
                <tr>
                  <th className="num">#</th>
                  <th>Player</th>
                  <th>Tier</th>
                  <th className="num">LP</th>
                  <th className="num">W</th>
                  <th className="num">L</th>
                  <th className="num">Streak</th>
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
            Points scale with who you beat: taking down someone far above you is worth
            about 40, beating a beginner about 4, and losing to one costs the same 40.
            Once you reach a tier you cannot fall out of it this season.
          </p>
        </section>
      )}

      {panel === 'deck' && (
        <section className="menu-panel">
          <p className="muted deckintro">
            Four of the six, no repeats. Both armies are on the board before the
            first turn, and you arrange yours then.
          </p>
          <div className="deckgrid">
            {roster.map((c) => {
              const picked = deck.includes(c.slug)
              const n = deck.indexOf(c.slug) + 1
              return (
                <button
                  key={c.id}
                  type="button"
                  className={`dcard${picked ? ' is-picked' : ''}`}
                  style={{ '--accent': c.accent } as React.CSSProperties}
                  aria-pressed={picked}
                  onClick={() => toggleCard(c.slug)}
                >
                  <span className="dcard-pick">{picked ? n : ''}</span>
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
        </section>
      )}

      {panel === 'roster' && (
        <section className="menu-panel">
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
        </section>
      )}
    </div>
  )
}

function MenuTile({
  className, label, note, onClick, active, disabled,
}: {
  className: string
  label: string
  note: string
  onClick: () => void
  active?: boolean
  disabled?: boolean
}) {
  return (
    <button
      className={`mtile ${className} ${active ? 'is-active' : ''}`}
      onClick={onClick}
      disabled={disabled}
    >
      <span className="mtile-inner">
        <span className="mtile-label">{label}</span>
        <span className="mtile-note">{note}</span>
      </span>
    </button>
  )
}
