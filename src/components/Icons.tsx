/** The settings icons. Line drawings at 24 units, one stroke weight, so they
 *  sit together as a set rather than as four borrowed glyphs. */
const box = { viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.7,
              strokeLinecap: 'round' as const, strokeLinejoin: 'round' as const }

export const IconGear = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <circle cx="12" cy="12" r="3.2" />
    <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.87l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.7 1.7 0 0 0-1.87-.34 1.7 1.7 0 0 0-1 1.56V21a2 2 0 0 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.55 1.7 1.7 0 0 0-1.88.34l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.7 1.7 0 0 0 .34-1.87 1.7 1.7 0 0 0-1.55-1.04H3a2 2 0 0 1 0-4h.1a1.7 1.7 0 0 0 1.55-1.1 1.7 1.7 0 0 0-.34-1.88l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.7 1.7 0 0 0 1.87.34H9a1.7 1.7 0 0 0 1-1.55V3a2 2 0 0 1 4 0v.1a1.7 1.7 0 0 0 1.04 1.55 1.7 1.7 0 0 0 1.87-.34l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.7 1.7 0 0 0-.34 1.87V9a1.7 1.7 0 0 0 1.55 1H21a2 2 0 0 1 0 4h-.1a1.7 1.7 0 0 0-1.55 1Z" />
  </svg>
)

export const IconSound = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M11 5 6.5 8.5H3v7h3.5L11 19Z" />
    <path d="M15.5 8.8a4.5 4.5 0 0 1 0 6.4" />
    <path d="M18.4 6a8.5 8.5 0 0 1 0 12" />
  </svg>
)

export const IconMusic = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M9 18V6l11-2v12" />
    <circle cx="6.5" cy="18" r="2.5" />
    <circle cx="17.5" cy="16" r="2.5" />
  </svg>
)

export const IconMotion = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M3 12h5l2.5-6 3 12 2.5-6h5" />
  </svg>
)

/** A disc half filled: the one glyph that means "light or dark" without
 *  committing to either, which is what a three-way control needs. */
export const IconTheme = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <circle cx="12" cy="12" r="9" />
    <path d="M12 3a9 9 0 0 0 0 18z" fill="currentColor" stroke="none" />
  </svg>
)

export const IconSignOut = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3" />
    <path d="M10 16l-4-4 4-4" />
    <path d="M6 12h10" />
  </svg>
)

export const IconClose = (p: { className?: string }) => (
  <svg {...box} {...p} aria-hidden="true">
    <path d="M6 6l12 12M18 6 6 18" />
  </svg>
)
