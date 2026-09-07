import { useEffect, useState } from 'react'

/**
 * The comics, read the way a webcomic is read: pick a chapter, then scroll.
 *
 * The pages are static files in the repository, served by the same host as the
 * app, and public/comics/index.json says what exists. Adding a chapter is
 * dropping images in a folder and adding a few lines to that file -- no
 * migration, no table, no deploy of anything but the pictures themselves.
 */
interface Chapter {
  id: string
  title: string
  /** A line under the title in the chapter list. Optional. */
  note?: string
  /** Paths relative to the site root, in reading order. */
  pages: string[]
}

export function Comics() {
  const [chapters, setChapters] = useState<Chapter[] | null>(null)
  const [open, setOpen] = useState<Chapter | null>(null)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    let alive = true
    fetch(`${import.meta.env.BASE_URL}comics/index.json`, { cache: 'no-cache' })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
      .then((d) => alive && setChapters(Array.isArray(d?.chapters) ? d.chapters : []))
      .catch(() => alive && setFailed(true))
    return () => { alive = false }
  }, [])

  if (failed) return <p className="muted">The comics could not be loaded right now.</p>
  if (!chapters) return <p className="muted">Loading…</p>

  if (open) {
    return (
      <div className="comic">
        <button className="linkbtn comic-back" onClick={() => setOpen(null)}>
          ← All chapters
        </button>
        <h3 className="comic-title">{open.title}</h3>
        {open.note && <p className="muted comic-note">{open.note}</p>}
        <div className="comic-pages">
          {open.pages.map((src, i) => (
            <img
              key={src}
              src={`${import.meta.env.BASE_URL}${src}`}
              alt={`${open.title}, page ${i + 1}`}
              loading={i < 2 ? 'eager' : 'lazy'}
            />
          ))}
        </div>
        <button className="btn ghost comic-foot" onClick={() => setOpen(null)}>
          Back to the chapters
        </button>
      </div>
    )
  }

  if (chapters.length === 0) {
    return (
      <p className="muted">
        Nothing here yet. The first chapter goes up when it is drawn.
      </p>
    )
  }

  return (
    <ul className="chapters">
      {chapters.map((c) => (
        <li key={c.id}>
          <button className="chapter" onClick={() => setOpen(c)}>
            {c.pages[0] && (
              <span
                className="chapter-cover"
                style={{ backgroundImage: `url(${import.meta.env.BASE_URL}${c.pages[0]})` }}
                aria-hidden="true"
              />
            )}
            <span className="chapter-body">
              <b>{c.title}</b>
              {c.note && <em>{c.note}</em>}
              <i>{c.pages.length} {c.pages.length === 1 ? 'page' : 'pages'}</i>
            </span>
          </button>
        </li>
      ))}
    </ul>
  )
}
