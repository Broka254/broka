'use client'

// Search and sort for a store's catalogue. A plain GET form underneath, so
// it works before (or without) JavaScript; with it, sorting applies as soon
// as it's chosen.
import { useRouter } from 'next/navigation'
import { useTransition } from 'react'

import { type CatalogueFilters, SORTS, filtersQuery } from '@/lib/catalogue'
import type { SortKey } from '@/lib/types'

import styles from './store.module.css'

export function CatalogueControls({ basePath, filters }: { basePath: string; filters: CatalogueFilters }) {
  const router = useRouter()
  const [pending, startTransition] = useTransition()

  return (
    <form className={styles.controls} action={basePath} method="get" role="search" aria-busy={pending}>
      {filters.category && <input type="hidden" name="category" value={filters.category} />}
      <label className={styles.search}>
        <span className="visually-hidden">Search this store</span>
        <span aria-hidden="true" className={styles.searchIcon}>
          ⌕
        </span>
        <input
          type="search"
          name="q"
          defaultValue={filters.q}
          placeholder="Search this store"
          maxLength={100}
          enterKeyHint="search"
        />
      </label>
      <label className={styles.sort}>
        <span className="visually-hidden">Sort products</span>
        <select
          name="sort"
          defaultValue={filters.sort}
          onChange={(e) => {
            const sort = e.target.value as SortKey
            startTransition(() => router.push(`${basePath}${filtersQuery({ ...filters, sort })}`, { scroll: false }))
          }}
        >
          {SORTS.map((s) => (
            <option key={s.key} value={s.key}>
              {s.label}
            </option>
          ))}
        </select>
      </label>
      <noscript>
        <button type="submit" className="button">
          Go
        </button>
      </noscript>
    </form>
  )
}
