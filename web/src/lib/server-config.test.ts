// The storefront's API address is server-only and read once at import, so
// each case sets the environment and re-imports the module. The default is
// what the Vercel deployment uses when BROKA_API_URL is unset; if it drifts
// back to a retired host, store pages silently stop loading.
import { afterEach, describe, expect, it, vi } from 'vitest'

const PRODUCTION_API = 'https://broka-a6vh.onrender.com'

describe('API_URL', () => {
  afterEach(() => {
    delete process.env.BROKA_API_URL
    vi.resetModules()
  })

  it('defaults to the production backend on Render', async () => {
    delete process.env.BROKA_API_URL
    vi.resetModules()
    const { API_URL } = await import('./server-config')
    expect(API_URL).toBe(PRODUCTION_API)
  })

  it('honours BROKA_API_URL and strips a trailing slash', async () => {
    process.env.BROKA_API_URL = 'http://127.0.0.1:8000/'
    vi.resetModules()
    const { API_URL } = await import('./server-config')
    expect(API_URL).toBe('http://127.0.0.1:8000')
  })
})
