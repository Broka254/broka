import Link from 'next/link'

import { type CatalogueFilters, filtersQuery } from '@/lib/catalogue'
import { categoryVisual, gradientCss } from '@/lib/categories'
import type { StoreCategory } from '@/lib/types'

import styles from './store.module.css'

/**
 * The store's categories, drawn like the app's home category rail: a
 * gradient ring around the category's emoji, its name underneath, and here
 * how many products it has. Plain links, so they work without JavaScript.
 */
const ONLINE_STORE_EXCLUDED = new Set([
  'Property',
  'Automobiles',
  'Land',
  'Services',
  'Other',
])

export function CategoryPills({
  basePath,
  categories,
  total,
  filters,
}: {
  basePath: string
  categories: StoreCategory[]
  total: number
  filters: CatalogueFilters
}) {
  // Online stores never browse by Property, Automobiles, Land, Services or
  // Other - same rule as the app and the backend goods rail.
  const visible = categories.filter((c) => !ONLINE_STORE_EXCLUDED.has(c.name))
  const items = [
    { value: null as string | null, label: 'All', emoji: '✨', gradient: categoryVisual('Other').gradient, count: total },
    ...visible.map((c) => {
      const v = categoryVisual(c.name)
      return { value: c.name, label: c.name, emoji: v.emoji, gradient: v.gradient, count: c.count }
    }),
  ]
  return (
    <nav className={styles.pills} aria-label="Categories">
      {items.map((item) => {
        const selected = item.value === filters.category
        return (
          <Link
            key={item.label}
            href={`${basePath}${filtersQuery({ ...filters, category: item.value })}`}
            className={`${styles.pill} ${selected ? styles.pillSelected : ''}`}
            aria-current={selected ? 'page' : undefined}
            scroll={false}
          >
            <span className={styles.ring} style={{ background: gradientCss(item.gradient) }}>
              <span className={styles.ringInner} aria-hidden="true">
                {item.emoji}
              </span>
              <span className={styles.count}>{item.count}</span>
            </span>
            <span className={styles.pillLabel}>{item.label}</span>
          </Link>
        )
      })}
    </nav>
  )
}
