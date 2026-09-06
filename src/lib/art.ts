/**
 * Card art lives in the repository under public/cards/, and the database
 * stores the path relative to the site root ('cards/dereo.webp'). The site is
 * not served from the root -- GitHub Pages puts it under /tactica/ -- so the
 * base has to go on at the last moment, in the browser, where Vite knows it.
 *
 * Anything already absolute (a full URL, or a path that starts with a slash)
 * is left exactly as it is, so moving the art to a CDN later needs no code
 * change: just write the URL into cards.art_url.
 */
export function artUrl(path: string | null | undefined): string | null {
  if (!path) return null
  if (/^(https?:)?\/\//.test(path) || path.startsWith('/') || path.startsWith('data:')) return path
  return import.meta.env.BASE_URL + path.replace(/^\.?\//, '')
}

/**
 * The board shows a zoomed crop of the illustration, so a 50px card on a
 * phone is a recognisable face and not a whole scene shrunk to nothing. The
 * crop lives beside the full picture under the same name: 'cards/dereo.webp'
 * has 'cards/dereo-face.webp' next to it.
 *
 * By convention rather than by column, because a second URL in the database
 * is a second thing to keep in step for no gain -- and if the crop is ever
 * missing the <img> onError falls back to the full picture, which is only
 * ugly, not broken.
 */
export function faceUrl(path: string | null | undefined): string | null {
  const full = artUrl(path)
  if (!full) return null
  return full.replace(/(\.[a-z0-9]+)(\?.*)?$/i, '-face$1$2')
}
