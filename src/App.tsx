import { useEffect, useState } from 'react'
import { Auth } from './components/Auth'
import { Lobby } from './components/Lobby'
import { Match } from './components/Match'
import { Logo } from './components/Logo'
import { useAuth } from './lib/useAuth'
import { configured, supabase } from './lib/supabase'

export default function App() {
  const { session, profile, loading, profileError, retryProfile } = useAuth()
  const [matchId, setMatchId] = useState<string | null>(
    () => new URLSearchParams(location.search).get('m'),
  )

  // Keep the URL in step, so a match is a link you can paste to a spectator.
  useEffect(() => {
    const url = new URL(location.href)
    if (matchId) url.searchParams.set('m', matchId)
    else url.searchParams.delete('m')
    history.replaceState(null, '', url)
  }, [matchId])

  if (!configured) {
    return (
      <div className="center-stage">
        <div className="panel">
          <h1 className="wordmark small">Almost there</h1>
          <p className="muted">
            Copy <code>.env.example</code> to <code>.env.local</code>, paste in your Supabase
            project URL and anon key, then restart <code>npm run dev</code>.
          </p>
        </div>
      </div>
    )
  }

  if (loading)
    return (
      <div className="center-stage">
        <Logo className="logo logo-hero is-waiting" title="Crown Nemesis" />
      </div>
    )
  if (!session) return <Auth />
  if (!profile)
    return (
      <div className="center-stage">
        <div className="panel">
          <h1 className="wordmark small">{profileError ? 'Not quite ready' : 'One moment'}</h1>
          <p className="muted">{profileError ?? 'Setting up your profile…'}</p>
          {profileError && (
            <div className="actionbar" style={{ marginTop: 18, justifyContent: 'flex-start' }}>
              <button className="btn" onClick={retryProfile}>Try again</button>
              <button className="btn ghost" onClick={() => supabase.auth.signOut()}>Sign out</button>
            </div>
          )}
        </div>
      </div>
    )
  if (matchId)
    return (
      <Match
        matchId={matchId}
        profile={profile}
        onLeave={() => setMatchId(null)}
        onGoTo={setMatchId}
      />
    )
  return <Lobby profile={profile} onEnter={setMatchId} />
}
