import { afterEach, describe, expect, it, vi } from 'vitest'

import { GET as assetLinks } from './.well-known/assetlinks.json/route'
import { GET as appleAssociation } from './.well-known/apple-app-site-association/route'
import { POST as visit } from './api/stores/[id]/visit/route'
import { GET as preview } from './og/[file]/route'
import { visitorAddress } from '@/lib/forward'

const params = <T,>(p: T) => ({ params: Promise.resolve(p) })
const FINGERPRINT = Array.from({ length: 32 }, () => 'ab').join(':')

afterEach(() => vi.unstubAllGlobals())

describe('app link files', () => {
  it('assetlinks.json lists valid fingerprints for the BROKA app', async () => {
    vi.stubEnv('ANDROID_CERT_SHA256', `${FINGERPRINT}, not-a-fingerprint`)
    const body = await assetLinks().json()
    expect(body).toEqual([
      {
        relation: ['delegate_permission/common.handle_all_urls'],
        target: { namespace: 'android_app', package_name: 'com.broka.app', sha256_cert_fingerprints: [FINGERPRINT.toUpperCase()] },
      },
    ])
  })
  it('assetlinks.json is empty until a fingerprint is set', async () => {
    vi.stubEnv('ANDROID_CERT_SHA256', '')
    expect(await assetLinks().json()).toEqual([])
  })
  it('apple-app-site-association exists only with an app id', async () => {
    vi.stubEnv('APPLE_APP_IDS', '')
    expect(appleAssociation().status).toBe(404)
    vi.stubEnv('APPLE_APP_IDS', 'ABCDE12345.com.broka.app')
    const body = await appleAssociation().json()
    expect(body.applinks.details[0].appIDs).toEqual(['ABCDE12345.com.broka.app'])
  })
})

describe('storefront API routes', () => {
  it('passes a visit on with the browser user agent and only known fields', async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 202 }))
    vi.stubGlobal('fetch', fetchMock)
    const req = new Request('https://broka.co.ke/api/stores/s1/visit', {
      method: 'POST',
      headers: { 'user-agent': 'Mozilla/5.0 Android', 'content-type': 'application/json' },
      body: JSON.stringify({ via: 'whatsapp', visitor: 'abcdefgh1234', referrer: 'https://x', admin: true }),
    })
    const res = await visit(req, params({ id: 's1' }))
    expect(res.status).toBe(204)
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    expect(url).toMatch(/\/stores\/s1\/visit$/)
    expect((init.headers as Record<string, string>)['User-Agent']).toBe('Mozilla/5.0 Android')
    expect(JSON.parse(String(init.body))).toEqual({
      surface: 'web',
      via: 'whatsapp',
      referrer: 'https://x',
      visitor: 'abcdefgh1234',
    })
  })
  it("sends the visitor's address with the storefront key, and nothing without the key", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 202 }))
    vi.stubGlobal('fetch', fetchMock)
    const req = () =>
      new Request('https://broka.co.ke/api/stores/s1/visit', {
        method: 'POST',
        headers: { 'x-real-ip': '41.90.1.2', 'x-forwarded-for': '41.90.1.2, 76.76.21.9' },
        body: '{}',
      })
    const sent = () => {
      const [, init] = fetchMock.mock.calls.at(-1) as unknown as [string, RequestInit]
      return init.headers as Record<string, string>
    }

    vi.stubEnv('STOREFRONT_API_KEY', '')
    await visit(req(), params({ id: 's1' }))
    expect(sent()['X-Broka-Client-IP']).toBeUndefined()
    expect(sent()['X-Broka-Storefront-Key']).toBeUndefined()

    vi.stubEnv('STOREFRONT_API_KEY', 'k'.repeat(40))
    await visit(req(), params({ id: 's1' }))
    expect(sent()['X-Broka-Client-IP']).toBe('41.90.1.2')
    expect(sent()['X-Broka-Storefront-Key']).toBe('k'.repeat(40))
  })
  it('reads the visitor address from the platform headers, and drops junk', () => {
    const at = (headers: Record<string, string>) =>
      visitorAddress(new Request('https://x', { headers }))
    expect(at({ 'x-real-ip': '41.90.1.2' })).toBe('41.90.1.2')
    expect(at({ 'x-forwarded-for': '2c0f:fe38::1, 76.76.21.9' })).toBe('2c0f:fe38::1')
    expect(at({ 'x-real-ip': 'evil<script>', 'x-forwarded-for': 'also bad' })).toBeNull()
    expect(at({})).toBeNull()
  })
  it("takes the website's word for the visitor only with the shared key", () => {
    const at = (headers: Record<string, string>) =>
      visitorAddress(new Request('https://x', { headers }))
    // Passed on by broka.co.ke: the platform's headers name the website.
    const passedOn = { 'x-real-ip': '76.76.21.9', 'x-broka-visitor-ip': '41.90.1.2' }
    const key = 'p'.repeat(40)
    // Not configured here: anyone can send the header, so it means nothing.
    expect(at({ ...passedOn, 'x-broka-proxy-key': key })).toBe('76.76.21.9')
    vi.stubEnv('STOREFRONT_PROXY_KEY', key)
    expect(at({ ...passedOn, 'x-broka-proxy-key': key })).toBe('41.90.1.2')
    expect(at({ ...passedOn, 'x-broka-proxy-key': 'q'.repeat(40) })).toBe('76.76.21.9')
    expect(at({ ...passedOn, 'x-broka-proxy-key': 'short' })).toBe('76.76.21.9')
    expect(at(passedOn)).toBe('76.76.21.9')
    expect(at({ ...passedOn, 'x-broka-proxy-key': key, 'x-broka-visitor-ip': 'junk' })).toBeNull()
  })
  it('refuses bad ids, junk and oversized bodies without calling the API', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    const post = (id: string, body: string) =>
      visit(new Request('https://broka.co.ke/x', { method: 'POST', body }), params({ id }))
    expect((await post('../admin', '{}')).status).toBe(400)
    expect((await post('s1', 'not json')).status).toBe(400)
    expect((await post('s1', 'x'.repeat(5000))).status).toBe(413)
    expect(fetchMock).not.toHaveBeenCalled()
  })
  it('link previews: only image ids, API 404s passed through, long caching', async () => {
    const id = '12345678-1234-1234-1234-123456789abc'
    vi.stubGlobal('fetch', vi.fn(async () => new Response(new Uint8Array([0xff, 0xd8]), { status: 200 })))
    expect((await preview(new Request('https://x'), params({ file: 'evil.jpg' }))).status).toBe(404)
    const ok = await preview(new Request('https://x'), params({ file: `${id}.jpg` }))
    expect(ok.status).toBe(200)
    expect(ok.headers.get('content-type')).toBe('image/jpeg')
    expect(ok.headers.get('cache-control')).toContain('immutable')
    vi.stubGlobal('fetch', vi.fn(async () => new Response('', { status: 404 })))
    expect((await preview(new Request('https://x'), params({ file: `${id}.jpg` }))).status).toBe(404)
  })
})
