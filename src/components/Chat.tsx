import { useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { Message, Profile } from '../lib/types'

interface Props {
  matchId: string
  profile: Profile
  messages: Message[]
  role: 'player' | 'spectator'
}

export function Chat({ matchId, profile, messages, role }: Props) {
  const [body, setBody] = useState('')
  const [sending, setSending] = useState(false)
  const endRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' })
  }, [messages.length])

  async function send(e: React.FormEvent) {
    e.preventDefault()
    const text = body.trim()
    if (!text || sending) return
    setSending(true)
    setBody('')
    const { error } = await supabase.from('match_messages').insert({
      match_id: matchId,
      user_id: profile.id,
      username: profile.username,
      body: text.slice(0, 500),
    })
    if (error) setBody(text) // put it back so nothing is lost
    setSending(false)
  }

  return (
    <aside className="side side-left">
      <h2 className="side-title">Chat</h2>
      <div className="side-body">
        {messages.length === 0 && <p className="muted tiny">Spectators can talk here too.</p>}
        {messages.map((m) => (
          <div key={m.id} className={`msg ${m.user_id === profile.id ? 'msg-own' : ''}`}>
            <span className="msg-who">{m.username}</span>
            <span className="msg-body">{m.body}</span>
          </div>
        ))}
        <div ref={endRef} />
      </div>
      <form className="side-foot" onSubmit={send}>
        <input
          value={body}
          onChange={(e) => setBody(e.target.value)}
          placeholder={role === 'spectator' ? 'Comment as a spectator…' : 'Say something…'}
          maxLength={500}
        />
        <button className="btn small" disabled={!body.trim()}>
          Send
        </button>
      </form>
    </aside>
  )
}
