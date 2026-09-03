import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

export const configured = Boolean(url && key && !url.includes('YOUR-PROJECT-REF'))

if (!configured) {
  // Loud on purpose — this is the single most common reason nothing works.
  console.error(
    'Supabase is not configured. Copy .env.example to .env.local, fill in ' +
      'VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY, then restart `npm run dev`.',
  )
}

export const supabase = createClient(url ?? 'http://localhost', key ?? 'anon', {
  realtime: { params: { eventsPerSecond: 10 } },
})
