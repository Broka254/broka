// Public deployment settings, read from the environment (see .env.example).
// Safe to use in browser code; the API address is in server-config.ts.

const trim = (value: string | undefined, fallback: string) =>
  (value && value.trim() ? value.trim() : fallback).replace(/\/+$/, '')

/** This site, for canonical links and link previews. */
export const SITE_URL = trim(process.env.NEXT_PUBLIC_SITE_URL, 'https://broka.co.ke')

export const APP_DOWNLOAD_URL = trim(
  process.env.NEXT_PUBLIC_APP_DOWNLOAD_URL,
  'https://github.com/Xxavier-ml/broka/releases/latest/download/broka-release.apk',
)

export const ANDROID_PACKAGE = 'com.broka.app'

/** How long store data is cached before it's fetched again, in seconds. */
export const REVALIDATE_SECONDS = 60

export const PAGE_SIZE = 24
