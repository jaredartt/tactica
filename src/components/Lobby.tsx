import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { createMatch, joinMatch } from '../lib/api'
import type { MatchRow, Profile } from '../lib/types'

interface Card {
  id: string
  name: string
  hp: number
  attack: number
  move: number
  range: number
  ability: string
  accent: string
  art_url: string | null
}

type Panel = 'none' | 'join' | 'spectate' | 'roster'

interface Props {
  profile: Profile
  onEnter: (matchId: string) => void
}

export function Lobby({ profile, onEnter }: Props) {
  const [panel, setPanel] = useState<Panel>('none')
  const [rooms, setRooms] = useState<MatchRow[]>([])
  const [roster, setRoster] = useState<Card[]>([])
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  async function loadRooms() {
    const { data } = await supabase
      .from('matches')
      .select('*')
      .in('status', ['waiting', 'active'])
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
    if (panel !== 'roster' || roster.length) return
    supabase
      .from('cards')
      .select('*')
      .eq('is_active', true)
      .order('name')
      .then(({ data }) => data && setRoster(data as Card[]))
  }, [panel, roster.length])

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

  return (
    <div className="menu">
      <div className="menu-bg" aria-hidden="true" />

      <header className="menu-head">
        <h1 className="wordmark small">CROWN NEMESIS</h1>
        <div className="menu-who">
          <span className="muted">{profile.username}</span>
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
          className="mt-roster"
          label="Roster"
          note="Every card in the game"
          active={panel === 'roster'}
          onClick={() => setPanel(panel === 'roster' ? 'none' : 'roster')}
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
                    <div><dt>ATK</dt><dd>{c.attack}</dd></div>
                    <div><dt>MOV</dt><dd>{c.move}</dd></div>
                    <div><dt>RNG</dt><dd>{c.range}</dd></div>
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
