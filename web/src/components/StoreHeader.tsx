// The top of every store page, the way a shop's website starts: a thin bar
// with what buying here means, then the store's own header - its name as
// the brand, the search pill and filter button (as on the app's Home), More
// (the store's details), share, and the cart. It stays on screen while the
// catalogue scrolls. BROKA is the "Protected by BROKA" line, not the brand:
// a seller sharing "my shop" gets a page that's theirs (STORES_UI_REVIEW.md H2).
import Link from 'next/link'

import type { CatalogueFilters } from '@/lib/catalogue'
import { APP_DOWNLOAD_URL } from '@/lib/config'
import { storeDetailsPath } from '@/lib/links'
import type { StoreView } from '@/lib/storefront'

import { CartButton } from './CartButton'
import { CatalogueControls } from './CatalogueControls'
import { Icon } from './Icon'
import { ShareIcon } from './ShareButtons'
import styles from './shop.module.css'

export function StoreHeader({ view, filters }: { view: StoreView; filters?: CatalogueFilters }) {
  const { store } = view
  return (
    <>
      <div className={styles.topbar}>
        <p>
          <Icon name="shield" size={15} />
          <span>
            Protected by <strong>BROKA</strong> escrow
          </span>
          <span className={styles.topbarMore}>· Pay by M-Pesa · Delivery or pickup agreed with the store</span>
        </p>
        <a href={APP_DOWNLOAD_URL} rel="nofollow" className={styles.topbarApp}>
          Get the app
        </a>
      </div>
      <header className={styles.header}>
        <div className={styles.headerInner}>
          <Link href={view.path} className={styles.brand} aria-label={`${store.name} home`}>
            <span className={styles.brandName}>{store.name}</span>
            <span className={styles.brandTag}>Store on BROKA · protected</span>
          </Link>
          <div className={styles.headerSearch}>
            <CatalogueControls basePath={view.path} storeName={store.name} filters={store.is_active ? filters : undefined} />
          </div>
          <nav className={styles.headerActions} aria-label="Store">
            <Link href={storeDetailsPath(store.slug)} className={styles.iconButton} aria-label="More about this store">
              <Icon name="info" />
            </Link>
            <ShareIcon storeId={store.id} url={view.url} title={store.name} />
            {store.is_active && <CartButton storeId={store.id} />}
          </nav>
        </div>
      </header>
    </>
  )
}
