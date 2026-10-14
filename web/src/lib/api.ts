// Reading from the BROKA API, on the server. Store data is cached for
// REVALIDATE_SECONDS, so a store shared into a busy WhatsApp group costs
// the API one request a minute, not one per visitor.
import 'server-only'

import { PAGE_SIZE, REVALIDATE_SECONDS } from './config'
import { API_URL } from './server-config'
import { PRICE_BANDS } from './catalogue'
import type { ConditionKey, Listing, PriceBandKey, SortKey, Store, StoreCategory } from './types'

/** The API answered with an error, or didn't answer. */
export class ApiUnavailableError extends Error {
  constructor(readonly status: number | null, message: string) {
    super(message)
    this.name = 'ApiUnavailableError'
  }
}

// Render's free plan sleeps; the first request after a nap can take a while.
const TIMEOUT_MS = 25_000

async function apiGet<T>(path: string, tags: string[] = [], revalidate = REVALIDATE_SECONDS): Promise<T | null> {
  let res: Response
  try {
    res = await fetch(`${API_URL}${path}`, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(TIMEOUT_MS),
      next: { revalidate, tags },
    })
  } catch (err) {
    throw new ApiUnavailableError(null, `BROKA API unreachable: ${(err as Error).message}`)
  }
  if (res.status === 404) return null
  if (!res.ok) throw new ApiUnavailableError(res.status, `BROKA API ${res.status} for ${path}`)
  return (await res.json()) as T
}

const LINK_NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/

/** The store with this link name, or null when there's no such store. */
export async function getStore(name: string): Promise<Store | null> {
  const slug = name.toLowerCase()
  if (!LINK_NAME.test(slug) || slug.length > 64) return null
  return apiGet<Store>(`/stores/slug/${slug}`, [`store:${slug}`])
}

export async function getStoreCategories(storeId: string): Promise<StoreCategory[]> {
  return (await apiGet<StoreCategory[]>(`/stores/${storeId}/categories`, [`store-id:${storeId}`])) ?? []
}

export interface CatalogueQuery {
  q?: string
  category?: string
  sort?: SortKey
  condition?: ConditionKey | null
  price?: PriceBandKey | null
  offset?: number
  limit?: number
}

export async function getStoreListings(storeId: string, query: CatalogueQuery = {}): Promise<Listing[]> {
  const params = new URLSearchParams({
    limit: String(query.limit ?? PAGE_SIZE),
    offset: String(query.offset ?? 0),
  })
  if (query.q) params.set('search', query.q)
  if (query.category) params.set('category', query.category)
  if (query.sort && query.sort !== 'featured') params.set('sort', query.sort)
  if (query.condition) params.set('condition', query.condition)
  const band = PRICE_BANDS.find((b) => b.key === query.price)
  if (band?.min != null) params.set('min_price', String(band.min))
  if (band?.max != null) params.set('max_price', String(band.max))
  return (await apiGet<Listing[]>(`/stores/${storeId}/listings?${params}`, [`store-id:${storeId}`])) ?? []
}

const LISTING_ID = /^[A-Za-z0-9-]{1,64}$/

export async function getListing(listingId: string): Promise<Listing | null> {
  if (!LISTING_ID.test(listingId)) return null
  return apiGet<Listing>(`/listings/${listingId}`, [`listing:${listingId}`])
}
