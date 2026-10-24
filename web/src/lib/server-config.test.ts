import { beforeEach, describe, expect, it, vi } from 'vitest'

// The storefront's API address is read once, when the server module loads.
const RENDER_API = 'https://broka-a6vh.onrender.com'

describe('server config', () => {
  beforeEach(() => {
    vi.resetModules()
    vi.unstubAllEnvs()
  })

  it('points the production storefront at the Render API by default', async () => {
    vi.stubEnv('BROKA_API_URL', '')
    const { API_URL } = await import('./server-config')
    expect(API_URL).toBe(RENDER_API)
  })

  it('honours BROKA_API_URL, without a trailing slash', async () => {
    vi.stubEnv('BROKA_API_URL', 'https://api.example.com/')
    const { API_URL } = await import('./server-config')
    expect(API_URL).toBe('https://api.example.com')
  })
})
