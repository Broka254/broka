// The top of every store page, the way a shop's website starts: a thin bar
// with what buying means, then the store's own header - its name as the
// brand, a search pill, and a Home / Shop / About / cart row that stays on
// screen while the catalogue scrolls. BROKA is the "Store on BROKA" line
// under the name, not the brand: a seller sharing "my shop" gets a page
// that's theirs. The bar says how paying works while BROKA holds no
// payments (lib/safety.ts): the rule first, as it's all a phone has room
// for.
import Link from 'next/link'

import type { CatalogueFilters } from '@/lib/catalogue'
import { APP_DOWNLOAD_URL } from '@/lib/config'
import { storeDetailsPath, storeShopPath } from '@/lib/links'
import { PAY_RULE } from '@/lib/safety'
import type { StoreView } from '@/lib/storefront'

import { CartButton } from './CartButton'
import { CatalogueControls } from './CatalogueControls'
import { Icon } from './Icon'
import { ShareIcon } from './ShareButtons'
import styles from './shop.module.css'

export type StoreNavSection = 'home' | 'shop' | 'about' | 'cart' | 'product'

export function StoreHeader({
  view,
  filters,
  active = 'home',
  searchBase,
}: {
  view: StoreView
  /** The store page's filters; elsewhere only the search pill shows. */
  filters?: CatalogueFilters
  /** Which section the visitor is in, for the nav's current-page mark. */
  active?: StoreNavSection
  /** Where the header's search submits; defaults to the section in view. */
  searchBase?: string
}) {
  const { store } = view
  const shopPath = storeShopPath(store.slug)
  const links = [
    { key: 'home', label: 'Home', href: view.path },
    { key: 'shop', label: 'Shop', href: shopPath },
    { key: 'about', label: 'About', href: storeDetailsPath(store.slug) },
  ]
  return (
    <>
      <div className={styles.topbar}>
        <p>
          <Icon name="check" size={15} />
          <strong>{PAY_RULE}</strong>
          <span className={styles.topbarMore}>· Delivery or pickup agreed with the store</span>
        </p>
        <a href={APP_DOWNLOAD_URL} rel="nofollow" className={styles.topbarApp}>
          Get the app
        </a>
      </div>
      <header className={styles.header}>
        <div className={styles.headerInner}>
          <Link href={view.path} className={styles.brand} aria-label={`${store.name} home`}>
            <span className={styles.brandName}>{store.name}</span>
            <span className={styles.brandTag}>Store on BROKA</span>
          </Link>
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
        </div>
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
      </header>
    </>
  )
}
