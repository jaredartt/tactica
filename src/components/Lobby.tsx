import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { createMatch, joinMatch } from '../lib/api'
import type { MatchRow, Profile } from '../lib/types'

interface Props {
  profile: Profile
  onEnter: (matchId: string) => void
}

export function Lobby({ profile, onEnter }: Props) {
  const [rooms, setRooms] = useState<MatchRow[]>([])
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

  async function host() {
    setBusy(true)
    setErr(null)
    try {
      onEnter((await createMatch()).id)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function join(byCode: string) {
    setBusy(true)
    setErr(null)
    try {
      onEnter((await joinMatch(byCode)).id)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="center-stage">
      <div className="lobby">
        <header className="lobby-head">
          <div>
            <h1 className="wordmark small">TACTICA</h1>
            <p className="muted">Signed in as {profile.username}</p>
          </div>
          <button className="linkbtn" onClick={() => supabase.auth.signOut()}>
            Sign out
          </button>
        </header>

        <div className="lobby-actions">
          <button className="btn primary big" onClick={host} disabled={busy}>
            Host a room
          </button>
          <form
            className="joinform"
            onSubmit={(e) => {
              e.preventDefault()
              if (code.trim()) join(code)
            }}
          >
            <input
              className="codeinput"
              value={code}
              onChange={(e) => setCode(e.target.value.toUpperCase())}
              placeholder="ROOM CODE"
              maxLength={5}
            />
            <button className="btn" disabled={busy || !code.trim()}>
              Join
            </button>
          </form>
        </div>

        {err && <p className="error">{err}</p>}

        <h2 className="section">Live rooms</h2>
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
                <button className="btn small" onClick={() => (open ? join(r.code) : onEnter(r.id))} disabled={busy}>
                  {mine ? 'Return' : open ? 'Join' : 'Spectate'}
                </button>
              </li>
            )
          })}
        </ul>
      </div>
    </div>
  )
}
