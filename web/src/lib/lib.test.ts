import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

import { filtersQuery, readFilters, toProductCard } from './catalogue'
import { CATEGORIES, canonicalCategory, categoryVisual } from './categories'
import { buildConstellation, MESH_COUNT, STAR_COUNT, seededRandom } from './constellation'
import { clip, conditionLabel, formatPrice, formatUnitPrice, placeLine, plural, yearOf } from './format'
import { resolveImage, resolveSizes, srcSet } from './images'
import { androidAppLink, previewImageUrl, productPath, storePath, viaTag } from './links'
import type { Listing } from './types'

const API = 'https://api.example.com'
// Tests run from web/; the backend and app sources are next to it.
const repo = (path: string) => resolve(process.cwd(), '..', path)

describe('format', () => {
  it('formats prices in shillings', () => {
    expect(formatPrice(18000)).toBe('KES 18,000')
    expect(formatPrice(1234567.6)).toBe('KES 1,234,568')
    expect(formatUnitPrice(3500, 'bag')).toBe('KES 3,500 / bag')
    expect(formatUnitPrice(3500, null)).toBe('KES 3,500')
  })
  it('joins places without blanks or repeats', () => {
    expect(placeLine('Starehe', null, 'Nairobi')).toBe('Starehe, Nairobi')
    expect(placeLine('Nairobi', 'nairobi')).toBe('Nairobi')
    expect(placeLine(null, '  ')).toBeNull()
  })
  it('clips on word boundaries', () => {
    expect(clip('short')).toBe('short')
    const long = 'word '.repeat(60)
    const out = clip(long, 50)
    expect(out.length).toBeLessThanOrEqual(50)
    expect(out.endsWith('word…')).toBe(true)
  })
  it('small helpers', () => {
    expect(plural(1, 'product')).toBe('1 product')
    expect(plural(3, 'product')).toBe('3 products')
    expect(yearOf('2025-01-10T00:00:00')).toBe(2025)
    expect(yearOf('nonsense')).toBeNull()
    expect(conditionLabel('refurbished')).toBe('Refurbished')
    expect(conditionLabel(null)).toBeNull()
  })
})

describe('categories', () => {
  it('match the backend taxonomy exactly, in order', () => {
    const seed = readFileSync(repo('backend/api/domains/categories/seed.py'), 'utf8')
    const block = /CANONICAL_CATEGORIES = \[([\s\S]*?)\]/.exec(seed)![1]!
    const backend = [...block.matchAll(/"([^"]+)"/g)].map((m) => m[1])
    expect(CATEGORIES.map((c) => c.name)).toEqual(backend)
  })
  it('use the same emoji as the app', () => {
    const dart = readFileSync(repo('flutter_app/lib/features/categories/domain/category_visual.dart'), 'utf8')
    for (const c of CATEGORIES) {
      const entry = new RegExp(`categoryName: '${c.name.replace(/[&]/g, '&')}',\\s*emoji: '([^']+)'`).exec(dart)
      expect(entry?.[1], c.name).toBe(c.emoji)
    }
  })
  it('resolve names case-insensitively, falling back to Other', () => {
    expect(canonicalCategory('electronics')).toBe('Electronics')
    expect(canonicalCategory('Gadgets')).toBeNull()
    expect(categoryVisual('GAMING').emoji).toBe('🎮')
    expect(categoryVisual('unknown').name).toBe('Other')
  })
  it('read the old name "Vehicles" as Automobiles', () => {
    expect(canonicalCategory('Vehicles')).toBe('Automobiles')
    expect(categoryVisual('vehicles').emoji).toBe('🚗')
  })
})

describe('catalogue filters', () => {
  it('read and validate the URL', () => {
    expect(readFilters({ q: '  samsung   phone ', category: 'electronics', sort: 'price_low' })).toEqual({
      q: 'samsung phone',
      category: 'Electronics',
      sort: 'price_low',
    })
    expect(readFilters({ category: 'Gadgets', sort: 'cheapest', q: 'x'.repeat(300) })).toEqual({
      q: 'x'.repeat(100),
      category: null,
      sort: 'featured',
    })
    expect(readFilters({ q: ['a', 'b'] }).q).toBe('a')
  })
  it('write only what differs from the defaults', () => {
    expect(filtersQuery({ q: '', category: null, sort: 'featured' })).toBe('')
    expect(filtersQuery({ q: 'tv', category: 'Home & Furniture', sort: 'newest' })).toBe(
      '?q=tv&category=Home+%26+Furniture&sort=newest',
    )
  })
})

const listing = (over: Partial<Listing> = {}): Listing => ({
  id: 'l1',
  name: 'Samsung A15',
  category: 'Electronics',
  price: 18000,
  status: 'active',
  listing_type: 'direct',
  condition: 'new',
  description: null,
  location_name: null,
  location_county: 'Nairobi',
  location_subcounty: 'Starehe',
  photos: [],
  cover: null,
  verified_photos: null,
  showcase_image_url: null,
  seller_name: 'Clanix',
  seller_verified: true,
  seller_rating: 4.8,
  seller_completed_deals: 3,
  store_id: 's1',
  store_slug: 'clanix',
  store_name: 'Clanix',
  ...over,
})

describe('product cards', () => {
  it('use the stored cover in every size', () => {
    const card = toProductCard(
      listing({ cover: { id: 'c1', thumb: '/media/i/t.webp', medium: '/media/i/m.webp', large: 'https://cdn/l.webp' } }),
      'clanix',
      API,
    )
    expect(card.image).toBe(`${API}/media/i/m.webp`)
    expect(card.imageSrcSet).toBe(`${API}/media/i/t.webp 480w, ${API}/media/i/m.webp 960w, https://cdn/l.webp 1600w`)
    expect(card.href).toBe('/store/clanix/p/l1')
    expect(card.priceLabel).toBe('KES 18,000')
    expect(card.place).toBe('Starehe, Nairobi')
  })
  it('fall back to an unconverted base64 photo, then the category emoji', () => {
    const b64 = 'iVBORw0KGgo' + 'A'.repeat(40)
    expect(toProductCard(listing({ verified_photos: `${b64},other` }), 'clanix', API).image).toBe(
      `data:image/png;base64,${b64}`,
    )
    const bare = toProductCard(listing(), 'clanix', API)
    expect(bare.image).toBeNull()
    expect(bare.emoji).toBe('📱')
  })
})

describe('images', () => {
  it('resolve every shape the API sends', () => {
    expect(resolveImage('https://cdn/x.webp', API)).toBe('https://cdn/x.webp')
    expect(resolveImage('/media/i/x.webp', API)).toBe(`${API}/media/i/x.webp`)
    expect(resolveImage('data:image/png;base64,AAAA', API)).toBe('data:image/png;base64,AAAA')
    expect(resolveImage('/9j/' + 'A'.repeat(40), API)).toBe(`${API}/9j/${'A'.repeat(40)}`)
    expect(resolveImage('A'.repeat(40), API)).toBe(`data:image/jpeg;base64,${'A'.repeat(40)}`)
    expect(resolveImage('javascript:alert(1)', API)).toBeNull()
    expect(resolveImage('', API)).toBeNull()
    expect(resolveSizes(null, API)).toBeNull()
    const s = resolveSizes({ id: 'a', thumb: '/t', medium: '/m', large: '/l' }, API)!
    expect(srcSet(s)).toContain('480w')
  })
})

describe('links', () => {
  it('build paths and preview URLs', () => {
    expect(storePath('clanix')).toBe('/store/clanix')
    expect(productPath('clanix', 'abc')).toBe('/store/clanix/p/abc')
    expect(previewImageUrl('abc')).toBe('https://broka.co.ke/og/abc.jpg')
  })
  it('open this page in the Android app, or download it', () => {
    const link = androidAppLink('https://broka.co.ke/store/clanix?via=whatsapp', 'https://dl/app.apk')
    expect(link).toBe(
      'intent://broka.co.ke/store/clanix?via=whatsapp#Intent;scheme=https;package=com.broka.app;' +
        'S.browser_fallback_url=https%3A%2F%2Fdl%2Fapp.apk;end',
    )
  })
  it('accept only plain source tags', () => {
    expect(viaTag('WhatsApp')).toBe('whatsapp')
    expect(viaTag(['tiktok', 'x'])).toBe('tiktok')
    expect(viaTag('<script>')).toBeUndefined()
    expect(viaTag(undefined)).toBeUndefined()
  })
})

describe('constellation', () => {
  it('is the same sky every time', () => {
    const a = buildConstellation(1.8)
    const b = buildConstellation(1.8)
    expect(a).toEqual(b)
    expect(a.nodes).toHaveLength(MESH_COUNT + STAR_COUNT)
    expect(a.nodes.every((n) => n.x >= 0 && n.x <= 1 && n.y >= 0 && n.y <= 1)).toBe(true)
  })
  it('connects only mesh nodes, each pair once', () => {
    const { edges } = buildConstellation(0.6)
    expect(edges.length).toBeGreaterThan(10)
    const keys = new Set(edges.map(([i, j]) => `${i}:${j}`))
    expect(keys.size).toBe(edges.length)
    expect(edges.every(([i, j]) => i < j && j < MESH_COUNT)).toBe(true)
  })
  it('seeded random is deterministic and in range', () => {
    const r1 = seededRandom(1)
    const r2 = seededRandom(1)
    const xs = Array.from({ length: 50 }, () => r1())
    expect(xs).toEqual(Array.from({ length: 50 }, () => r2()))
    expect(xs.every((x) => x >= 0 && x < 1)).toBe(true)
  })
})
