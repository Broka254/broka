'use client'

// The catalogue grid: the first page rendered on the server, more pages
// fetched on request through /api/stores/[id]/listings.
import { useState } from 'react'

import type { CatalogueFilters, ProductCardData } from '@/lib/catalogue'

import { ProductCard } from './ProductCard'
import styles from './shop.module.css'

export function ProductGrid({
  storeId,
  slug,
  filters,
  initial,
  pageSize,
}: {
  storeId: string
  slug: string
  filters: CatalogueFilters
  initial: ProductCardData[]
  pageSize: number
}) {
  const [items, setItems] = useState(initial)
  const [hasMore, setHasMore] = useState(initial.length === pageSize)
  const [loading, setLoading] = useState(false)
  const [failed, setFailed] = useState(false)

  const loadMore = async () => {
    setLoading(true)
    setFailed(false)
    const params = new URLSearchParams({ slug, offset: String(items.length) })
    if (filters.q) params.set('q', filters.q)
    if (filters.category) params.set('category', filters.category)
    if (filters.sort !== 'featured') params.set('sort', filters.sort)
    if (filters.condition) params.set('condition', filters.condition)
    if (filters.price) params.set('price', filters.price)
    try {
      const res = await fetch(`/api/stores/${encodeURIComponent(storeId)}/listings?${params}`)
      if (!res.ok) throw new Error(String(res.status))
      const page = (await res.json()) as ProductCardData[]
      setItems((current) => {
        const seen = new Set(current.map((p) => p.id))
        return [...current, ...page.filter((p) => !seen.has(p.id))]
      })
      setHasMore(page.length === pageSize)
    } catch {
      setFailed(true)
    } finally {
      setLoading(false)
    }
  }

  return (
    <>
      <div className={styles.grid}>
        {items.map((p) => (
          <ProductCard key={p.id} product={p} storeId={storeId} />
        ))}
      </div>
      {(hasMore || failed) && (
        <div className={styles.more}>
          {failed && <p className="muted">Couldn&apos;t load more products.</p>}
          <button type="button" className="button button--ghost" onClick={loadMore} disabled={loading}>
            {loading ? 'Loading…' : failed ? 'Try again' : 'Show more products'}
          </button>
        </div>
      )}
    </>
  )
}
