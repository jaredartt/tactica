import { faceUrl } from '../lib/art'

/**
 * A face in a circle. The token the board uses, cropped to a round window --
 * which is why there is nothing to upload: every picture a player can choose
 * is already in the repository and already sized for a small square.
 *
 * `slug` rather than a URL, so the column stays a foreign key in spirit and a
 * character whose art is redrawn is redrawn everywhere at once.
 */
export function Avatar({
  slug, name, size = 32, className = '',
}: {
  slug: string | null | undefined
  name: string
  size?: number
  className?: string
}) {
  const src = slug ? faceUrl(`cards/${slug}.webp`) : null
  return (
    <span
      className={`avatar ${className}`.trim()}
      style={{ width: size, height: size }}
      aria-hidden="true"
    >
      {src ? <img src={src} alt="" /> : <i>{name.slice(0, 1).toUpperCase()}</i>}
    </span>
  )
}
