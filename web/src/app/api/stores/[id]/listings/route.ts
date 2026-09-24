// More catalogue products for the store page's "Show more" button, as
// product-card data (never the raw API rows).
import { NextResponse } from 'next/server'

import { getStoreListings } from '@/lib/api'
import { readFilters, toProductCard } from '@/lib/catalogue'
import { PAGE_SIZE } from '@/lib/config'
import { API_URL } from '@/lib/server-config'

const ID = /^[A-Za-z0-9-]{1,64}$/
const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const url = new URL(req.url)
  const slug = url.searchParams.get('slug') ?? ''
  const offset = Number(url.searchParams.get('offset') ?? '0')
  if (!ID.test(id) || !SLUG.test(slug) || !Number.isInteger(offset) || offset < 0 || offset > 5000) {
    return NextResponse.json({ detail: 'Bad request' }, { status: 400 })
  }
  const filters = readFilters(Object.fromEntries(url.searchParams))
  try {
    const listings = await getStoreListings(id, {
      q: filters.q,
      category: filters.category ?? undefined,
      sort: filters.sort,
      offset,
      limit: PAGE_SIZE,
    })
    return NextResponse.json(
      listings.map((l) => toProductCard(l, slug, API_URL)),
      { headers: { 'Cache-Control': 'public, s-maxage=60, stale-while-revalidate=300' } },
    )
  } catch {
    return NextResponse.json({ detail: 'Try again' }, { status: 503 })
  }
}
