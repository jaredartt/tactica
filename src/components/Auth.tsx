import { useState } from 'react'
import { supabase } from '../lib/supabase'

export function Auth() {
  const [mode, setMode] = useState<'in' | 'up'>('in')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [username, setUsername] = useState('')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    setBusy(true)
    setErr(null)
    setMsg(null)
    try {
      if (mode === 'up') {
        const { data, error } = await supabase.auth.signUp({
          email,
          password,
          options: { data: { username: username.trim() } },
        })
        if (error) throw error
        if (!data.session) setMsg('Check your email to confirm, then sign in.')
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email, password })
        if (error) throw error
      }
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="center-stage">
      <div className="panel auth">
        <h1 className="wordmark">TACTICA</h1>
        <p className="muted">A competitive tactics arena.</p>

        <form onSubmit={submit}>
          {mode === 'up' && (
            <label>
              <span>Display name</span>
              <input
                value={username}
                onChange={(e) => setUsername(e.target.value)}
                placeholder="how you appear in the arena"
                minLength={2}
                maxLength={20}
                required
              />
            </label>
          )}
          <label>
            <span>Email</span>
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoComplete="email"
              required
            />
          </label>
          <label>
            <span>Password</span>
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete={mode === 'up' ? 'new-password' : 'current-password'}
              minLength={6}
              required
            />
          </label>

          {err && <p className="error">{err}</p>}
          {msg && <p className="notice">{msg}</p>}

          <button className="btn primary" disabled={busy}>
            {busy ? '…' : mode === 'up' ? 'Create account' : 'Sign in'}
          </button>
        </form>

        <button className="linkbtn" onClick={() => { setMode(mode === 'in' ? 'up' : 'in'); setErr(null); setMsg(null) }}>
          {mode === 'in' ? 'No account yet? Create one' : 'Already have an account? Sign in'}
        </button>
      </div>
    </div>
  )
}
