import { useEffect, useRef } from 'react'
import type { LogEntry } from '../lib/types'

export function BattleLog({ log, open }: { log: LogEntry[]; open: boolean }) {
  const endRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' })
  }, [log.length])

  return (
    <aside className={`side side-right${open ? ' is-open' : ''}`}>
      <h2 className="side-title">Battle log</h2>
      <div className="side-body">
        {log.map((e) => (
          <div key={e.n} className="logline">
            <span className="log-turn">{e.turn > 0 ? `T${e.turn}` : '—'}</span>
            <span>{e.text}</span>
          </div>
        ))}
        <div ref={endRef} />
      </div>
    </aside>
  )
}
