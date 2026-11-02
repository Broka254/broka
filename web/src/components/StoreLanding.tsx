import Link from 'next/link'

import { storeCategoryTiles } from '@/components/CategoryPills'
import { type ProductCardData, filtersQuery } from '@/lib/catalogue'
import { categoryArtPath } from '@/lib/category-art'
import { storeDetailsPath, storeShopPath } from '@/lib/links'
import type { StoreCategory } from '@/lib/types'
import type { StoreView } from '@/lib/storefront'

import { ProductCard } from './ProductCard'
import styles from './store-landing.module.css'

export function StoreLanding({
  view,
  categories,
  products,
  storeId,
}: {
  view: StoreView
  categories: StoreCategory[]
  products: ProductCardData[]
  storeId: string
}) {
  const { store } = view
  const shopPath = storeShopPath(store.slug)
  const [spotlight, ...moreProducts] = products
  const mappedTiles = storeCategoryTiles(categories)
  const tiles = mappedTiles.length ? mappedTiles : view.sellCategories.map((name) => ({
    name,
    parent: name,
    count: 0,
    category: name,
    subcategoryId: null,
    art: categoryArtPath(name),
  }))
  const heroImage = view.cover?.src ?? view.photos[0]?.src ?? null
  const heroHref = shopPath
  const primaryHref = products.length > 0 ? shopPath : tiles.length > 0 ? '#collections-title' : shopPath
  const primaryLabel = products.length > 0 ? 'Shop all products' : tiles.length > 0 ? 'Explore collections' : 'Visit the shop'
  const context = [store.category, view.isVirtual ? view.delivery : view.place].filter(Boolean).join(' · ')
  const storeScore = store.rating != null ? `${store.rating.toFixed(1)}/10 store score` : null
  const description = view.description || (spotlight
    ? `Explore the collection from ${store.name} and see what is available today.`
    : `Browse ${store.name}'s departments and check back as new products are added.`)

  return (
    <div className={styles.landing}>
      <main className={styles.main}>
        <section className={styles.hero} aria-labelledby="landing-title">
          <div className={styles.heroCopy}>
            <p className={styles.eyebrow}>{store.category || 'INDEPENDENT STORE'} <span>·</span> ON BROKA</p>
            <h1 id="landing-title">{store.name}</h1>
            {context && <p className={styles.context}>{context}</p>}
            <p className={styles.description}>{description}</p>
            <div className={styles.proof}>
              {storeScore && <span>{storeScore}</span>}
              {storeScore && store.owner?.verified && <i aria-hidden="true" />}
              {store.owner?.verified && <span>Verified seller</span>}
              {!storeScore && !store.owner?.verified && store.is_active && <span>Shop directly with the store</span>}
            </div>
            <div className={styles.actions}>
              {store.is_active && <Link href={primaryHref} className={styles.primaryAction}>{primaryLabel} <span aria-hidden="true">↗</span></Link>}
            </div>
            {!store.is_active && <p className={styles.paused} role="status">This store is taking a break right now.</p>}
          </div>

          <Link href={heroHref} className={styles.heroVisual} aria-label={`Browse ${store.name} products`}>
            {heroImage ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img
                src={heroImage}
                sizes="(max-width: 700px) 100vw, 48vw"
                alt=""
                fetchPriority="high"
              />
            ) : (
              <span className={styles.visualMonogram} aria-hidden="true">{view.initial}</span>
            )}
            <span className={styles.visualShade} />
            <span className={styles.visualTag}>A look inside this store</span>
            <span className={styles.visualCaption}>
              <span>Explore {store.name}&apos;s shop</span>
              <strong>{store.listing_count > 0 ? `${store.listing_count} products to explore` : 'Discover the collections'}</strong>
              <span className={styles.visualArrow} aria-hidden="true">↗</span>
            </span>
          </Link>
        </section>

        {tiles.length > 0 && (
          <section className={styles.section} aria-labelledby="collections-title">
            <div className={styles.sectionHead}>
              <div>
                <p className={styles.sectionEyebrow}>EXPLORE THE STORE</p>
                <h2 id="collections-title">Shop by collection</h2>
              </div>
              <Link href={shopPath} className={styles.textLink}>View all <span aria-hidden="true">↗</span></Link>
            </div>
            <nav className={styles.collections} aria-label="Shop collections">
              {tiles.slice(0, 6).map((tile) => {
                const href = `${shopPath}${filtersQuery({ category: tile.category, subcategoryId: tile.subcategoryId })}`
                return (
                  <Link key={tile.subcategoryId ?? tile.name} href={href} className={styles.collection}>
                    {tile.art ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img src={tile.art} alt="" loading="lazy" decoding="async" />
                    ) : <span className={styles.collectionMonogram} aria-hidden="true">{tile.parent.slice(0, 1)}</span>}
                    <span className={styles.collectionShade} />
                    <span className={styles.collectionText}>
                      <strong>{tile.name}</strong>
                      {tile.count > 0 && <small>{tile.count} {tile.count === 1 ? 'item' : 'items'}</small>}
                    </span>
                    <span className={styles.collectionArrow} aria-hidden="true">↗</span>
                  </Link>
                )
              })}
            </nav>
          </section>
        )}

        {moreProducts.length > 0 && (
          <section className={styles.section} aria-labelledby="products-title">
            <div className={styles.sectionHead}>
              <div>
                <p className={styles.sectionEyebrow}>SELECTED FROM THE SHOP</p>
                <h2 id="products-title">More to discover</h2>
              </div>
              <Link href={shopPath} className={styles.textLink}>Shop all <span aria-hidden="true">↗</span></Link>
            </div>
              <div className={styles.products} data-count={Math.min(moreProducts.length, 6)}>
                {moreProducts.slice(0, 6).map((product) => (
                <ProductCard key={product.id} product={product} storeId={storeId} compact />
              ))}
            </div>
          </section>
        )}

        {products.length === 0 && store.is_active && (
          <section className={styles.newStore} aria-label="New store">
            <span className={styles.newStoreMark} aria-hidden="true">{view.initial}</span>
            <div>
              <p className={styles.sectionEyebrow}>THE SHOP IS JUST GETTING STARTED</p>
              <h2>New things are on the way.</h2>
              <p>{store.name} hasn&apos;t added products yet. Browse the collections above or check back soon.</p>
            </div>
          </section>
        )}

        {view.description && (
          <section className={styles.about} aria-labelledby="about-store-title">
            <div>
              <p className={styles.sectionEyebrow}>A NOTE FROM THE SHOP</p>
              <h2 id="about-store-title">About {store.name}</h2>
              <p>{view.description}</p>
            </div>
            <Link href={storeDetailsPath(store.slug)} className={styles.textLink}>Read the store story <span aria-hidden="true">↗</span></Link>
          </section>
        )}
      </main>
    </div>
  )
}
