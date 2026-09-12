import { useCallback, useEffect, useState } from 'react'
import { Auth } from './components/Auth'
import { Lobby } from './components/Lobby'
import { Match } from './components/Match'
import { Boundary } from './components/Boundary'
import { Logo } from './components/Logo'
import { useWipe } from './components/Wipe'
import { attachUiSounds } from './lib/sfx'
import { primeLang, useT } from './lib/i18n'
import { useAuth } from './lib/useAuth'
import { configured, supabase } from './lib/supabase'

export default function App() {
  const t = useT()
  const { session, profile, loading, profileError, retryProfile, patchProfile } = useAuth()
  const [matchId, setMatchId] = useState<string | null>(
    () => new URLSearchParams(location.search).get('m'),
  )
  // Every crossing between the menu and a match goes through this, in both
  // directions: leaving one for the other used to happen in a single frame.
  const { cross, wipe } = useWipe()

  // Stable identities. These are effect dependencies down in Match, and a
  // fresh arrow on every render makes those effects re-run on every render --
  // which is how a rematch used to leave the wipe covering the screen.
  const goTo = useCallback((id: string) => cross(() => setMatchId(id)), [cross])
  const leave = useCallback(() => cross(() => setMatchId(null)), [cross])

  // One pair of listeners for every button in the app, rather than a sound
  // wired into each one and forgotten on the next.
  useEffect(attachUiSounds, [])

  // Fetch the dictionary for whatever language the cache already says, before
  // anything asks for a word. Without it the first paint is English and the
  // second is Spanish, which is a flicker in front of the one person who
  // notices it most.
  useEffect(primeLang, [])

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
          <h1 className="wordmark small">{t('app.almostThere')}</h1>
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
          <h1 className="wordmark small">
            {t(profileError ? 'app.notReady' : 'app.loading')}
          </h1>
          <p className="muted">{profileError ?? t('app.gettingReady')}</p>
          {profileError && (
            <div className="actionbar" style={{ marginTop: 18, justifyContent: 'flex-start' }}>
              <button className="btn" onClick={retryProfile}>{t('app.tryAgain')}</button>
              <button className="btn ghost" onClick={() => supabase.auth.signOut()}>
                {t('common.signOut')}
              </button>
            </div>
          )}
        </div>
      </div>
    )
  if (matchId)
    return (
      <>
        {/* The match is the part with the most moving pieces and the only part
            where a crash strands you mid-turn, so it gets its own boundary
            with a way OUT of it -- the lobby is still standing behind this. */}
        <Boundary where="match" onOut={leave}>
          <Match
            matchId={matchId} profile={profile} onProfile={patchProfile}
            onLeave={leave} onGoTo={goTo}
          />
        </Boundary>
        {wipe}
      </>
    )
  return (
    <>
      <Lobby
        profile={profile}
        onEnter={goTo}
        onProfile={patchProfile}
      />
      {wipe}
    </>
  )
}
