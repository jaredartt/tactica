import { useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from './supabase'
import type { Profile } from './types'

export function useAuth() {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)

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
      return
    }
    let cancelled = false
    // The profile row is created by a trigger, which can land a beat after the
    // session does. Retry a few times before giving up.
    ;(async () => {
      for (let i = 0; i < 6 && !cancelled; i++) {
        const { data } = await supabase
          .from('profiles')
          .select('id, username, is_admin, lp, wins, losses, games, streak, deck')
          .eq('id', session.user.id)
          .maybeSingle()
        if (data) {
          if (!cancelled) setProfile(data as Profile)
          return
        }
        await new Promise((r) => setTimeout(r, 400))
      }
    })()
    return () => {
      cancelled = true
    }
  }, [session])

  return { session, profile, loading, userId: session?.user.id ?? null }
}
