// Settings only the server may read.
import 'server-only'

/** The BROKA API (the Render service). */
export const API_URL = (process.env.BROKA_API_URL?.trim() || 'https://broka-dbjd.onrender.com').replace(/\/+$/, '')
