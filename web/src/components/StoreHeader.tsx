// The top of every store page, the way a shop's website starts: a thin bar
// with what buying means, then the store's own header - its name as the
// brand, a search pill, and a Home / Shop / About / cart row that stays on
// screen while the catalogue scrolls. BROKA is the "Store on BROKA" line
// under the name, not the brand: a seller sharing "my shop" gets a page
// that's theirs. The bar says how paying works while BROKA holds no
// payments (lib/safety.ts): the rule first, as it's all a phone has room
// for.
import Link from 'next/link'

import { type CatalogueFilters, filtersQuery } from '@/lib/catalogue'
import { asset, storeDetailsPath, storeShopPath } from '@/lib/links'
import type { StoreView } from '@/lib/storefront'

import { CartButton } from './CartButton'
import { CatalogueControls } from './CatalogueControls'
import { ShareIcon } from './ShareButtons'
import styles from './shop.module.css'

export type StoreNavSection = 'home' | 'shop' | 'about' | 'cart' | 'product'

export function StoreHeader({
  view,
  filters,
  active = 'home',
  searchBase,
  showSectionNav = true,
}: {
  view: StoreView
  /** The store page's filters; elsewhere only the search pill shows. */
  filters?: CatalogueFilters
  /** Which section the visitor is in, for the nav's current-page mark. */
  active?: StoreNavSection
  /** Where the header's search submits; defaults to the section in view. */
  searchBase?: string
  /** Hide the Home/Shop/category/About row on pages that should match a cleaner reference. */
  showSectionNav?: boolean
}) {
  const { store } = view
  const shopPath = storeShopPath(store.slug)
  const links = active === 'home'
    ? []
    : [
        { key: 'home', label: 'Home', href: view.path },
        { key: 'shop', label: 'Shop', href: shopPath },
        ...view.sellCategories.slice(0, 4).map((c) => ({
          key: `cat-${c}`,
          label: c,
          href: `${shopPath}${filtersQuery({ category: c })}`,
        })),
        { key: 'about', label: 'About', href: storeDetailsPath(store.slug) },
      ]
  return (
      <header className={styles.header}>
        <div className={`${styles.headerInner} ${active === 'home' ? styles.homeHeaderInner : ''}`}>
          <Link href={view.path} className={styles.brand} aria-label={`${store.name} home`}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={view.logo ?? asset('/logo.png')} alt="" className={styles.brandLogo} />
            <span className={styles.brandText}>
              <span className={`${styles.brandName} ${active === 'home' ? styles.homeBrandName : ''}`}>{store.name}</span>
              <span className={styles.brandTag}>Store on BROKA</span>
            </span>
          </Link>
          {active === 'home' && (
            <Link href={storeDetailsPath(store.slug)} className={styles.homeAboutButton}>
              About
            </Link>
          )}
          {active !== 'home' && (
            <>
              <div className={styles.headerSearch}>
                <CatalogueControls
                  basePath={searchBase ?? (active === 'shop' ? shopPath : view.path)}
                  storeName={store.name}
                  filters={store.is_active ? filters : undefined}
                />
              </div>
              <nav className={styles.headerActions} aria-label="Store">
                <ShareIcon storeId={store.id} url={view.url} title={store.name} />
                {store.is_active && <CartButton storeId={store.id} />}
              </nav>
            </>
          )}
        </div>
        {active !== 'home' && showSectionNav && (
          <nav className={styles.storeNav} aria-label="Store sections">
            <div className={styles.storeNavInner}>
              {links.map((l) => (
                <Link
                  key={l.key}
                  href={l.href}
                  aria-current={active === l.key ? 'page' : undefined}
                  className={active === l.key ? styles.storeNavActive : undefined}
                >
                  {l.label}
                </Link>
              ))}
            </div>
          </nav>
        )}
      </header>
  )
}
