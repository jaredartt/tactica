import { supabase } from '../lib/supabase'
import { setSettings, useSettings, type Theme } from '../lib/settings'
import { playHit } from '../lib/sfx'
import { IconMotion, IconMusic, IconSignOut, IconSound, IconTheme } from './Icons'
import { Modal } from './Modal'

/** A row: an icon, a label, and the one control that changes it. */
function Row({
  icon, label, note, children,
}: {
  icon: React.ReactNode
  label: string
  note?: string
  children: React.ReactNode
}) {
  return (
    <div className="set-row">
      <span className="set-icon">{icon}</span>
      <span className="set-label">
        {label}
        {note && <em>{note}</em>}
      </span>
      <span className="set-control">{children}</span>
    </div>
  )
}

export function SettingsCard({ onClose }: { onClose: () => void }) {
  const s = useSettings()

  return (
    <Modal title="Settings" onClose={onClose}>
      <div className="settings">
        <Row icon={<IconSound />} label="Sound effects" note={`${Math.round(s.sfx * 100)}%`}>
          <input
            type="range" min={0} max={100} value={Math.round(s.sfx * 100)}
            aria-label="Sound effects volume"
            onChange={(e) => setSettings({ sfx: Number(e.target.value) / 100 })}
            // A volume slider you cannot hear is a guess, so every notch
            // plays -- and it plays a blow rather than a button, because the
            // loudest thing this number controls is the fighting. Previewing
            // with the quietest sound in the set is how you set it too high.
            onMouseUp={() => playHit(0.6)}
            onKeyUp={() => playHit(0.6)}
          />
        </Row>

        <Row icon={<IconMusic />} label="Music" note="Nothing to play yet">
          <input
            type="range" min={0} max={100} value={Math.round(s.music * 100)}
            aria-label="Music volume"
            onChange={(e) => setSettings({ music: Number(e.target.value) / 100 })}
          />
        </Row>

        {/* Three states and not a switch. "Follow the system" is a real
            answer and the one most people want, and a two-position toggle
            cannot hold it -- it would have to be a switch plus a second
            control to say whether the switch counts. */}
        <Row icon={<IconTheme />} label="Theme" note="Light, dark, or whatever your device says">
          <div className="seg" role="radiogroup" aria-label="Theme">
            {([['system', 'Auto'], ['light', 'Light'], ['dark', 'Dark']] as [Theme, string][])
              .map(([v, label]) => (
                <button
                  key={v}
                  role="radio"
                  aria-checked={s.theme === v}
                  className={s.theme === v ? 'is-on' : ''}
                  onClick={() => setSettings({ theme: v })}
                >
                  {label}
                </button>
              ))}
          </div>
        </Row>

        <Row
          icon={<IconMotion />}
          label="Reduce motion"
          note="Menu transitions only — the board still animates"
        >
          <button
            className={`toggle${s.reduceMotion ? ' is-on' : ''}`}
            role="switch" aria-checked={s.reduceMotion}
            aria-label="Reduce motion"
            onClick={() => setSettings({ reduceMotion: !s.reduceMotion })}
          >
            <i />
          </button>
        </Row>

        <div className="set-sep" />

        <button className="set-row is-action" onClick={() => supabase.auth.signOut()}>
          <span className="set-icon"><IconSignOut /></span>
          <span className="set-label">Sign out</span>
        </button>
      </div>
    </Modal>
  )
}
