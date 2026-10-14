'use client'

// Search and filters for a store's catalogue, drawn like the app's Home:
// a pill search field and, beside it, the filter button (with a dot while
// a filter applies) that opens the filter panel - sort, condition, price.
//
// Everything is a URL: the search is a plain GET form and every filter is
// a link, so each filtered view can be shared and works without JavaScript
// (the panel is a <details>). With JavaScript, a tap outside closes it.
import Link from 'next/link'
import { useEffect, useRef } from 'react'

import { CONDITIONS, type CatalogueFilters, PRICE_BANDS, SORTS, filtersQuery, panelActive } from '@/lib/catalogue'

import { Icon } from './Icon'
import styles from './shop.module.css'

export function CatalogueControls({
  basePath,
  storeName,
  filters,
}: {
  basePath: string
  storeName: string
  /** The store page's filters; elsewhere (a product, the cart) only search. */
  filters?: CatalogueFilters
}) {
  return (
    <div className={styles.controls}>
      <form className={styles.searchPill} action={basePath} method="get" role="search">
        {filters?.category && <input type="hidden" name="category" value={filters.category} />}
        {filters && filters.sort !== 'featured' && <input type="hidden" name="sort" value={filters.sort} />}
        {filters?.condition && <input type="hidden" name="condition" value={filters.condition} />}
        {filters?.price && <input type="hidden" name="price" value={filters.price} />}
        <label className={styles.searchLabel}>
          <span className="visually-hidden">Search {storeName}</span>
          <Icon name="search" size={18} className={styles.searchIcon} />
          <input
            key={filters?.q ?? ''}
            type="search"
            name="q"
            defaultValue={filters?.q}
            placeholder={`Search ${storeName}`}
            maxLength={100}
            enterKeyHint="search"
          />
        </label>
        <button type="submit" className={styles.searchGo}>
          Search
        </button>
      </form>
      {filters && <FilterPanel basePath={basePath} filters={filters} />}
    </div>
  )
}

function FilterPanel({ basePath, filters }: { basePath: string; filters: CatalogueFilters }) {
  const ref = useRef<HTMLDetailsElement>(null)
  const active = panelActive(filters)

  useEffect(() => {
    const close = (e: Event) => {
      const el = ref.current
      if (!el?.open) return
      if (e instanceof KeyboardEvent ? e.key === 'Escape' : !el.contains(e.target as Node)) el.open = false
    }
    document.addEventListener('pointerdown', close)
    document.addEventListener('keydown', close)
    return () => {
      document.removeEventListener('pointerdown', close)
      document.removeEventListener('keydown', close)
    }
  }, [])

  const href = (change: Partial<CatalogueFilters>) => `${basePath}${filtersQuery({ ...filters, ...change })}`
  const chip = (label: string, selected: boolean, to: string, key: string) => (
    <Link
      key={key}
      href={to}
      scroll={false}
      className={`${styles.chip} ${selected ? styles.chipOn : ''}`}
      aria-current={selected ? 'true' : undefined}
    >
      {label}
    </Link>
  )

  return (
    <details ref={ref} className={styles.filters}>
      <summary className={`${styles.filterButton} ${active ? styles.filterButtonActive : ''}`} aria-label="Filters">
        <Icon name="tune" size={19} />
        <span className={styles.filterLabel}>Filters</span>
        {active && <span className={styles.filterDot} data-testid="filters-active" />}
      </summary>
      <div className={styles.filterPanel}>
        <p className={styles.filterTitle}>Sort</p>
        <div className={styles.chips}>
          {SORTS.map((s) => chip(s.label, filters.sort === s.key, href({ sort: s.key }), s.key))}
        </div>
        <p className={styles.filterTitle}>Condition</p>
        <div className={styles.chips}>
          {chip('Any', !filters.condition, href({ condition: null }), 'any')}
          {CONDITIONS.map((c) => chip(c.label, filters.condition === c.key, href({ condition: c.key }), c.key))}
        </div>
        <p className={styles.filterTitle}>Price (KES)</p>
        <div className={styles.chips}>
          {chip('Any price', !filters.price, href({ price: null }), 'any-price')}
          {PRICE_BANDS.map((b) => chip(b.label, filters.price === b.key, href({ price: b.key }), b.key))}
        </div>
        {active && (
          <Link href={href({ sort: 'featured', condition: null, price: null })} scroll={false} className={styles.resetFilters}>
            Reset filters
          </Link>
        )}
      </div>
    </details>
  )
}
