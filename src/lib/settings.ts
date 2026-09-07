/**
 * Sound, music and motion. Three numbers that belong to this browser and
 * nobody else, so they live in localStorage rather than in the database --
 * there is nothing here another device needs to know, and a volume slider
 * that has to wait for a round trip is a volume slider that feels broken.
 *
 * A module-level store rather than context: the settings panel, the sound
 * player and both transitions all read it, and three of those four are not
 * React components.
 */
import { useSyncExternalStore } from 'react'

export interface Settings {
  /** 0..1 */
  sfx: number
  /** 0..1 */
  music: number
  /** Menu transitions only. The board's own animations are how you read a
   *  match, so they are never touched by this. */
  reduceMotion: boolean
}

const KEY = 'cn.settings'
const DEFAULTS: Settings = { sfx: 0.5, music: 0.4, reduceMotion: false }

function read(): Settings {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return DEFAULTS
    const v = JSON.parse(raw) as Partial<Settings>
    return {
      sfx: clamp(v.sfx ?? DEFAULTS.sfx),
      music: clamp(v.music ?? DEFAULTS.music),
      reduceMotion: Boolean(v.reduceMotion),
    }
  } catch {
    // A private window, blocked site data, a browser that throws on read --
    // none of which is a reason to fail to start.
    return DEFAULTS
  }
}
const clamp = (n: number) => Math.max(0, Math.min(1, Number(n) || 0))

let state = read()
const listeners = new Set<() => void>()

function publish() {
  document.documentElement.dataset.reduceMotion = state.reduceMotion ? '1' : ''
  listeners.forEach((l) => l())
}
publish()

export function setSettings(patch: Partial<Settings>) {
  state = { ...state, ...patch }
  try { localStorage.setItem(KEY, JSON.stringify(state)) } catch { /* not fatal */ }
  publish()
}

export const getSettings = () => state

export function useSettings(): Settings {
  return useSyncExternalStore(
    (l) => { listeners.add(l); return () => listeners.delete(l) },
    () => state,
    () => state,
  )
}

/** The setting OR the operating system's. Either one means: not this. */
export function lessMotion(): boolean {
  return (
    state.reduceMotion ||
    (typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion: reduce)').matches)
  )
}
