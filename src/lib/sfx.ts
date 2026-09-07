/**
 * The interface noise, synthesised rather than shipped.
 *
 * Two sounds, a click and a hover, made out of an oscillator and an envelope.
 * No files: nothing to download, nothing to license, and "make them vary" is
 * a random number rather than a folder of near-identical wavs. Each play
 * detunes a little and shortens or lengthens a little, so a row of buttons
 * does not sound like a machine.
 *
 * The context is created on the first real gesture, because a browser will
 * not let it start before one, and a suspended context that nobody resumes is
 * how you end up with silence you cannot debug.
 */
import { getSettings } from './settings'

let ctx: AudioContext | null = null
let bus: GainNode | null = null

function audio(): AudioContext | null {
  if (typeof window === 'undefined') return null
  if (!ctx) {
    const AC = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext
    if (!AC) return null
    ctx = new AC()
    bus = ctx.createGain()
    bus.connect(ctx.destination)
  }
  if (ctx.state === 'suspended') void ctx.resume()
  return ctx
}

/** A note: one oscillator, one envelope, gone in under a fifth of a second. */
function blip(freq: number, ms: number, peak: number, type: OscillatorType) {
  const level = getSettings().sfx
  if (level <= 0) return
  const c = audio()
  if (!c || !bus) return

  const t = c.currentTime
  const osc = c.createOscillator()
  const env = c.createGain()
  osc.type = type
  osc.frequency.setValueAtTime(freq, t)
  // A touch of downward drift. Flat pitch reads as a beep; a falling one
  // reads as something being pressed.
  osc.frequency.exponentialRampToValueAtTime(freq * 0.82, t + ms / 1000)

  env.gain.setValueAtTime(0.0001, t)
  env.gain.exponentialRampToValueAtTime(peak * level, t + 0.006)
  env.gain.exponentialRampToValueAtTime(0.0001, t + ms / 1000)

  osc.connect(env); env.connect(bus)
  osc.start(t)
  osc.stop(t + ms / 1000 + 0.02)
}

const vary = (n: number, spread: number) => n * (1 + (Math.random() * 2 - 1) * spread)

export function playClick() {
  blip(vary(660, 0.06), vary(120, 0.15), 0.16, 'triangle')
}

export function playHover() {
  blip(vary(1180, 0.08), vary(58, 0.2), 0.05, 'sine')
}

/**
 * One pair of listeners for the whole app, delegated from the document.
 *
 * Wiring a sound into every button is a change to every button and a thing to
 * forget on the next one. This asks the event where it came from instead.
 */
export function attachUiSounds() {
  const HIT = 'button, [role="button"], a[href], .mtile, .rtile, .chapter, .modecard'
  let last: Element | null = null

  const over = (e: PointerEvent) => {
    const el = (e.target as Element | null)?.closest?.(HIT) ?? null
    if (!el || el === last) return
    last = el
    if (!(el as HTMLButtonElement).disabled) playHover()
  }
  const out = (e: PointerEvent) => {
    if (!(e.relatedTarget as Element | null)?.closest?.(HIT)) last = null
  }
  const down = (e: PointerEvent) => {
    const el = (e.target as Element | null)?.closest?.(HIT)
    if (el && !(el as HTMLButtonElement).disabled) playClick()
  }

  document.addEventListener('pointerover', over)
  document.addEventListener('pointerout', out)
  document.addEventListener('pointerdown', down)
  return () => {
    document.removeEventListener('pointerover', over)
    document.removeEventListener('pointerout', out)
    document.removeEventListener('pointerdown', down)
  }
}
