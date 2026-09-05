import { useCallback, useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from './supabase'
import type { Profile } from './types'

/** Every column the current client needs that a older schema would not have.
 *  Checked by presence rather than by asking for it, so a database that is a
 *  migration behind gives us a clear answer instead of a failed query. */
const REQUIRED_COLUMNS = ['deck'] as const

const BEHIND =
  'This build needs a database migration that has not been run yet. ' +
  'Open the Supabase SQL editor and run supabase/migrations/0005_roster_terrain_deploy.sql.'

export function useAuth() {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)
  const [profileError, setProfileError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)

  const retryProfile = useCallback(() => {
    setProfileError(null)
    setAttempt((n) => n + 1)
  }, [])

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      setLoading(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => sub.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    if (!session) {
      setProfile(null)
      setProfileError(null)
      return
    }
    let cancelled = false
    // The profile row is created by a trigger, which can land a beat after the
    // session does. Retry a few times before giving up.
    ;(async () => {
      let last: string | null = null
      for (let i = 0; i < 6 && !cancelled; i++) {
        // select('*') on purpose. Naming the columns means the whole sign-in
        // fails the moment the app expects one the database has not got yet --
        // and since the site deploys instantly while a migration is run by
        // hand, that window is real. A star cannot go stale.
        const { data, error } = await supabase
          .from('profiles')
          .select('*')
          .eq('id', session.user.id)
          .maybeSingle()

        if (data) {
          if (cancelled) return
          const missing = REQUIRED_COLUMNS.filter((c) => !(c in data))
          if (missing.length) setProfileError(BEHIND)
          else setProfile(data as Profile)
          return
        }
        if (error) last = error.message
        await new Promise((r) => setTimeout(r, 400))
      }
      // Six tries and still nothing. Say so: an unexplained spinner is the
      // worst way to report a problem, because it looks like it is working.
      if (!cancelled) {
        setProfileError(last ?? 'Your profile could not be loaded. It may not have been created.')
      }
    })()
    return () => {
      cancelled = true
    }
  }, [session, attempt])

  return { session, profile, loading, profileError, retryProfile, userId: session?.user.id ?? null }
}
