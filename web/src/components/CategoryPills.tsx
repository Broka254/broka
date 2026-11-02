import Link from 'next/link'

import { type CatalogueFilters, filtersQuery } from '@/lib/catalogue'
import { categoryArtPath } from '@/lib/category-art'
import type { StoreCategory } from '@/lib/types'

import styles from './store.module.css'

type CategoryTile = {
  name: string
  parent: string
  count: number
  category: string | null
  subcategoryId: string | null
  art: string | null
}

/** The same shelves as the app: actual subcategories when present, otherwise their parent category. */
export function storeCategoryTiles(categories: StoreCategory[]): CategoryTile[] {
  return categories
    .flatMap<CategoryTile>((category) => {
      if (category.subcategories?.length) {
        return category.subcategories.map((subcategory) => ({
          name: subcategory.name,
          parent: category.name,
          count: subcategory.count,
          category: null,
          subcategoryId: subcategory.id,
          art: categoryArtPath(category.name, subcategory.name),
        }))
      }
      return [{
        name: category.name,
        parent: category.name,
        count: category.count,
        category: category.name,
        subcategoryId: null,
        art: categoryArtPath(category.name),
      }]
    })
}

export function hasStoreCategoryTiles(categories: StoreCategory[]): boolean {
  return storeCategoryTiles(categories).length > 1
}

export function CategoryPills({
  basePath,
  categories,
  filters,
  showCounts = true,
  ariaLabel = 'Shop by category',
}: {
  basePath: string
  categories: StoreCategory[]
  filters: CatalogueFilters
  showCounts?: boolean
  ariaLabel?: string
}) {
  const tiles = storeCategoryTiles(categories)
  if (tiles.length < 2) return null

  return (
    <nav className={styles.categoryRail} aria-label={ariaLabel}>
      {tiles.map((tile) => {
        const selected = tile.subcategoryId
          ? tile.subcategoryId === filters.subcategoryId
          : tile.category === filters.category
        const href = filtersQuery({
          ...filters,
          category: tile.category,
          subcategoryId: tile.subcategoryId,
        })
        return (
          <Link
            key={tile.subcategoryId ?? tile.name}
            href={`${basePath}${href}`}
            className={`${styles.categoryTile} ${selected ? styles.categoryTileSelected : ''}`}
            aria-current={selected ? 'page' : undefined}
            aria-label={showCounts ? `${tile.name}, ${tile.count} product${tile.count === 1 ? '' : 's'}` : tile.name}
            scroll={false}
          >
            {tile.art ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img className={styles.categoryTileImage} src={tile.art} alt="" loading="lazy" decoding="async" />
            ) : (
              <span className={styles.categoryTileFallback} aria-hidden="true">{tile.parent.slice(0, 1)}</span>
            )}
            <span className={styles.categoryTileScrim} />
            <span className={styles.categoryTileCopy}>
              <strong>{tile.name}</strong>
            {showCounts && <small>{tile.count} {tile.count === 1 ? 'item' : 'items'}</small>}
            </span>
          </Link>
        )
      })}
    </nav>
  )
}
