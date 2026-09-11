import { supabase } from '../lib/supabase'
import { setSettings, useSettings, type Lang, type Theme } from '../lib/settings'
import { loadLang, useT } from '../lib/i18n'
import { playHit } from '../lib/sfx'
import { IconLang, IconMotion, IconMusic, IconSignOut, IconSound, IconTheme } from './Icons'
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
  const t = useT()

  return (
    <Modal title={t('settings.title')} onClose={onClose}>
      <div className="settings">
        <Row icon={<IconSound />} label={t('settings.sfx')} note={`${Math.round(s.sfx * 100)}%`}>
          <input
            type="range" min={0} max={100} value={Math.round(s.sfx * 100)}
            aria-label={t('settings.sfxVolume')}
            onChange={(e) => setSettings({ sfx: Number(e.target.value) / 100 })}
            // A volume slider you cannot hear is a guess, so every notch
            // plays -- and it plays a blow rather than a button, because the
            // loudest thing this number controls is the fighting. Previewing
            // with the quietest sound in the set is how you set it too high.
            onMouseUp={() => playHit(0.6)}
            onKeyUp={() => playHit(0.6)}
          />
        </Row>

        <Row icon={<IconMusic />} label={t('settings.music')} note={t('settings.musicNote')}>
          <input
            type="range" min={0} max={100} value={Math.round(s.music * 100)}
            aria-label={t('settings.musicVolume')}
            onChange={(e) => setSettings({ music: Number(e.target.value) / 100 })}
          />
        </Row>

        {/* Three states and not a switch. "Follow the system" is a real
            answer and the one most people want, and a two-position toggle
            cannot hold it -- it would have to be a switch plus a second
            control to say whether the switch counts. */}
        <Row icon={<IconTheme />} label={t('settings.theme')} note={t('settings.themeNote')}>
          <div className="seg" role="radiogroup" aria-label={t('settings.theme')}>
            {/* The key is written out rather than built from the value.
                Building it produced `settings.themeSystem` for a value of
                'system' while the dictionary says `themeAuto` -- the button
                rendered its own key on screen, and no amount of checking the
                dictionaries against each other could see it, because a
                constructed key is invisible to a search. */}
            {([['system', 'settings.themeAuto'],
               ['light', 'settings.themeLight'],
               ['dark', 'settings.themeDark']] as [Theme, string][]).map(([v, key]) => (
              <button
                key={v}
                role="radio"
                aria-checked={s.theme === v}
                className={s.theme === v ? 'is-on' : ''}
                onClick={() => setSettings({ theme: v })}
              >
                {t(key)}
              </button>
            ))}
          </div>
        </Row>

        {/* The languages name themselves. A Spanish reader looking for Spanish
            is looking for the word "Español", not for whatever the interface
            they cannot read calls it -- so these two are the one pair of words
            in the app that do NOT get translated. */}
        <Row icon={<IconLang />} label={t('settings.language')} note={t('settings.languageNote')}>
          <div className="seg" role="radiogroup" aria-label={t('settings.language')}>
            {([['en', 'English'], ['es', 'Español']] as [Lang, string][]).map(([v, label]) => (
              <button
                key={v}
                role="radio"
                aria-checked={s.lang === v}
                className={s.lang === v ? 'is-on' : ''}
                onClick={() => { void loadLang(v); setSettings({ lang: v }) }}
              >
                {label}
              </button>
            ))}
          </div>
        </Row>

        <Row
          icon={<IconMotion />}
          label={t('settings.reduceMotion')}
          note={t('settings.reduceMotionNote')}
        >
          <button
            className={`toggle${s.reduceMotion ? ' is-on' : ''}`}
            role="switch" aria-checked={s.reduceMotion}
            aria-label={t('settings.reduceMotion')}
            onClick={() => setSettings({ reduceMotion: !s.reduceMotion })}
          >
            <i />
          </button>
        </Row>

        <div className="set-sep" />

        <button className="set-row is-action" onClick={() => supabase.auth.signOut()}>
          <span className="set-icon"><IconSignOut /></span>
          <span className="set-label">{t('common.signOut')}</span>
        </button>
      </div>
    </Modal>
  )
}
