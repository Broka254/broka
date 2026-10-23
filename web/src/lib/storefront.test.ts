import { describe, expect, it } from 'vitest'

import { SITE_URL } from './config'
import { API_URL } from './server-config'
import { campaignToken } from './links'
import {
  jsonLdScript,
  productJsonLd,
  productPreviewImage,
  productView,
  storeDescription,
  storeJsonLd,
  storePreviewImage,
  storeView,
} from './storefront'
import type { ImageSizes, Listing, Store } from './types'

const sizes = (id: string): ImageSizes => ({
  id,
  thumb: `/media/img/${id}/thumb.webp`,
  medium: `/media/img/${id}/medium.webp`,
  large: `https://media.broka.co.ke/img/${id}/large.webp`,
})

const store = (over: Partial<Store> = {}): Store => ({
  id: 's1',
  name: 'clanix',
  slug: 'clanix',
  url: 'https://broka.co.ke/store/clanix',
  category: 'Electronics',
  description: null,
  country: 'Kenya',
  county: 'Nairobi',
  subcounty: 'Starehe',
  location_description: null,
  business_email: null,
  business_email_verified: false,
  logo: null,
  cover: null,
  photo_images: [],
  logo_url: null,
  photos: [],
  owner: null,
  is_active: true,
  listing_count: 3,
  ...over,
})

const listing = (over: Partial<Listing> = {}): Listing => ({
  id: 'l1',
  name: 'Samsung A15',
  category: 'Electronics',
  price: 18000.4,
  status: 'active',
  listing_type: 'direct',
  condition: 'new',
  description: null,
  location_name: 'Town',
  location_county: null,
  location_subcounty: null,
  photos: [],
  cover: null,
  verified_photos: null,
  showcase_image_url: null,
  seller_name: 'Clanix',
  seller_verified: true,
  seller_rating: null,
  seller_completed_deals: 0,
  store_id: 's1',
  store_slug: 'clanix',
  store_name: 'Clanix',
  ...over,
})

describe('store view', () => {
  it('prefers the cover, then a shop photo, and resolves paths on the API', () => {
    const view = storeView(store({ cover: sizes('c1'), photo_images: [sizes('p1')], logo: sizes('g1') }))
    expect(view.cover?.src).toBe('https://media.broka.co.ke/img/c1/large.webp')
    expect(view.cover?.srcSet).toContain(`${API_URL}/media/img/c1/thumb.webp 480w`)
    expect(view.logo).toBe(`${API_URL}/media/img/g1/medium.webp`)
    expect(view.url).toBe(`${SITE_URL}/store/clanix`)
    expect(view.initial).toBe('C')
    expect(storeView(store({ photo_images: [sizes('p1')] })).cover?.src).toContain('/p1/')
  })

  it('lists every shop photo for Store details, cover first', () => {
    const view = storeView(store({ cover: sizes('c1'), photo_images: [sizes('p1'), sizes('p2')] }))
    expect(view.photos.map((p) => p.src)).toEqual([
      'https://media.broka.co.ke/img/c1/large.webp',
      'https://media.broka.co.ke/img/p1/large.webp',
      'https://media.broka.co.ke/img/p2/large.webp',
    ])
    expect(view.photos[0]?.thumb).toBe(`${API_URL}/media/img/c1/medium.webp`)
    // A row the media backfill hasn't converted: its plain photo strings.
    expect(storeView(store({ photos: ['https://media.broka.co.ke/old.webp'] })).photos).toEqual([
      { src: 'https://media.broka.co.ke/old.webp', thumb: 'https://media.broka.co.ke/old.webp' },
    ])
    expect(storeView(store()).photos).toEqual([])
  })

  it('has no cover or logo to show when the store has none', () => {
    const view = storeView(store())
    expect(view.cover).toBeNull()
    expect(view.logo).toBeNull()
    expect(view.place).toBe('Starehe, Nairobi')
  })

  it('previews with a JPEG of the cover, a shop photo or the logo, else the default card', () => {
    expect(storePreviewImage(store({ cover: sizes('c1'), logo: sizes('g1') })).url).toBe(`${SITE_URL}/og/c1.jpg`)
    expect(storePreviewImage(store({ photo_images: [sizes('p1')], logo: sizes('g1') })).url).toBe(
      `${SITE_URL}/og/p1.jpg`,
    )
    expect(storePreviewImage(store({ logo: sizes('g1') })).url).toBe(`${SITE_URL}/og/g1.jpg`)
    expect(storePreviewImage(store())).toEqual({
      url: '/store-assets/og-default.jpg',
      width: 1200,
      height: 630,
      type: 'image/jpeg',
    })
  })

  it('describes itself from the owner text, or from what it sells and where', () => {
    expect(storeDescription(store({ description: '  Phones   and accessories ' }))).toBe('Phones and accessories')
    expect(storeDescription(store())).toBe(
      'Electronics store in Starehe, Nairobi · 3 products on BROKA. See it, then pay the store.',
    )
    expect(storeDescription(store({ category: null, county: null, subcounty: null, listing_count: 1 }))).toBe(
      'Store · 1 product on BROKA. See it, then pay the store.',
    )
    // Link previews no longer promise a protected purchase: BROKA holds no
    // payments while they're paused.
    expect(storeDescription(store())).not.toMatch(/protected/i)
  })

  it('gives search engines absolute image URLs only', () => {
    const ld = storeJsonLd(storeView(store({ cover: sizes('c1'), logo: sizes('g1') })))
    expect(ld['@type']).toBe('Store')
    expect(ld.image).toBe('https://media.broka.co.ke/img/c1/large.webp')
    expect(ld.logo).toBe(`${API_URL}/media/img/g1/medium.webp`)
    expect(ld.address).toMatchObject({ addressCountry: 'KE', addressRegion: 'Nairobi' })
    const legacy = storeJsonLd(storeView(store({ photos: ['iVBORw0KGgo' + 'A'.repeat(40)] })))
    expect(legacy.image).toBeUndefined()
  })
})

describe('product view', () => {
  it('shows every stored photo, and only an active listing is available', () => {
    const view = productView(listing({ photos: [sizes('a'), sizes('b')], status: 'sold' }), 'clanix')
    expect(view.images).toHaveLength(2)
    expect(view.images[0]?.thumb).toBe(`${API_URL}/media/img/a/thumb.webp`)
    expect(view.available).toBe(false)
    expect(view.path).toBe('/store/clanix/p/l1')
    // Still active, but every unit sold or in a deal.
    expect(productView(listing({ available: false }), 'clanix').available).toBe(false)
    expect(productView(listing(), 'clanix').available).toBe(true)
    expect(view.place).toBe('Town')
  })

  it('falls back to base64 photos, then the cover', () => {
    const b64 = 'iVBORw0KGgo' + 'A'.repeat(40)
    expect(productView(listing({ verified_photos: `${b64},${b64}` }), 'clanix').images).toHaveLength(2)
    const withCover = productView(listing({ cover: sizes('c1') }), 'clanix')
    expect(withCover.images.map((i) => i.src)).toEqual(['https://media.broka.co.ke/img/c1/large.webp'])
    expect(productView(listing(), 'clanix').images).toEqual([])
  })

  it('previews with the cover or first photo', () => {
    expect(productPreviewImage(listing({ cover: sizes('c1'), photos: [sizes('a')] })).url).toBe(`${SITE_URL}/og/c1.jpg`)
    expect(productPreviewImage(listing({ photos: [sizes('a')] })).url).toBe(`${SITE_URL}/og/a.jpg`)
    expect(productPreviewImage(listing()).url).toBe('/store-assets/og-default.jpg')
  })

  it('offers in whole shillings with the right availability', () => {
    const ld = productJsonLd(productView(listing({ photos: [sizes('a')] }), 'clanix'), 'Clanix')
    expect(ld.offers).toMatchObject({
      priceCurrency: 'KES',
      price: 18000,
      availability: 'https://schema.org/InStock',
      seller: { name: 'Clanix' },
    })
    expect(ld.image).toEqual(['https://media.broka.co.ke/img/a/large.webp'])
    const sold = productJsonLd(productView(listing({ status: 'pending' }), 'clanix'), 'Clanix')
    expect(sold.offers.availability).toBe('https://schema.org/SoldOut')
  })
})

describe('structured data in the page', () => {
  it('cannot close its script tag', () => {
    const out = jsonLdScript({ name: '</script><script>alert(1)</script>' })
    expect(out).not.toContain('<')
    expect(JSON.parse(out)).toEqual({ name: '</script><script>alert(1)</script>' })
  })
})


describe('store types on the storefront', () => {
  it('describes a physical store by where it is and its hours', () => {
    const view = storeView(store({
      store_type: 'physical',
      opening_hours_available: true,
      opening_hours_week: [
        { day: 'mon', label: 'Monday', short: 'Mon', hours: '08:00 – 18:00', closed: false, all_day: false },
      ],
      open_status: { state: 'open', label: 'Open now · closes 18:00', opens_at: null, closes_at: '18:00', next_day: null },
      service_areas: ['Kisumu'],
    }))
    expect(view.isVirtual).toBe(false)
    expect(view.place).toContain('Nairobi')
    expect(view.hours).toHaveLength(1)
    expect(view.openLabel).toBe('Open now · closes 18:00')
    expect(view.openNow).toBe(true)
  })

  it('gives a virtual store delivery coverage and no address in its structured data', () => {
    const data = storeJsonLd(storeView(store({
      store_type: 'virtual',
      county: null,
      subcounty: null,
      service_areas: ['Siaya'],
      delivery_note: 'Same-day in Bondo.',
    })))
    expect(data.address).toBeUndefined()
    expect(JSON.stringify(data)).not.toContain('Siaya')
  })

  it('reads nationwide coverage in words, and nothing when it is unset', () => {
    expect(storeView(store({ service_areas: ['Nationwide'] })).delivery).toBe('Delivers nationwide')
    expect(storeView(store({ service_areas: ['Nairobi', 'Kisumu'] })).delivery).toBe(
      'Delivers to Nairobi, Kisumu',
    )
    expect(storeView(store({ service_areas: [] })).delivery).toBeNull()
    expect(storeView(store({})).openLabel).toBe('Opening hours unavailable')
  })

  it('keeps only a well-formed campaign token from a link', () => {
    expect(campaignToken('kAbC123_-xyz')).toBe('kAbC123_-xyz')
    expect(campaignToken('short')).toBeUndefined()
    expect(campaignToken('has space')).toBeUndefined()
    expect(campaignToken(undefined)).toBeUndefined()
  })
})
