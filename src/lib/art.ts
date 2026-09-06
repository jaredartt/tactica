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
