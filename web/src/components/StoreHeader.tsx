// The top of every store page, the way a shop's website starts: the store's
// own name as the brand ("Store on BROKA" under it - a seller sharing "my
// shop" gets a page that's theirs), a search of its catalogue, the cart,
// and the store's sections - Home, Shop, Messages, About - with the one in
// view marked, on every page (a product is marked as part of the Shop).
// "Your orders" sits apart at the end of that row: it is the buyer's BROKA
// account, with orders from every store, not one of this store's sections.
//
// On a phone the sections move to a bar along the bottom (StoreBottomNav),
// with the cart, and the header keeps the store's name, search, About and
// sharing. The messages page is a chat screen there, with a header of its
// own (ConversationHeader), so it has neither.
import Link from 'next/link'

import type { CatalogueFilters } from '@/lib/catalogue'
import { asset } from '@/lib/links'
import { currentMark, type StorePage, type StoreSection, storePaths } from '@/lib/store-nav'
import type { StoreView } from '@/lib/storefront'

import { CartButton } from './CartButton'
import { CatalogueControls } from './CatalogueControls'
import { Icon } from './Icon'
import { RememberStore } from './LastStore'
import { ShareIcon } from './ShareButtons'
import { StoreBottomNav } from './StoreBottomNav'
import shop from './shop.module.css'
import styles from './store-nav.module.css'

/** Kept for the pages that name it: a page is a section or a product. */
export type StoreNavSection = StorePage

export function StoreHeader({
  view,
  filters,
  active = 'home',
  searchBase,
}: {
  view: StoreView
  /** The catalogue page's filters; elsewhere only the search pill shows. */
  filters?: CatalogueFilters
  /** The page the visitor is on, for the navigation's "you are here". */
  active?: StorePage
  /** Where the header's search submits; the catalogue by default. */
  searchBase?: string
}) {
  const { store } = view
  const paths = storePaths(store)
  const sections: Array<{ key: StoreSection; label: string; href: string }> = [
    { key: 'home', label: 'Home', href: paths.home },
    { key: 'shop', label: 'Shop', href: paths.shop },
    ...(paths.messages ? [{ key: 'messages' as const, label: 'Messages', href: paths.messages }] : []),
    { key: 'about', label: 'About', href: paths.about },
  ]

  return (
    <>
      <a className="skip-link" href="#main-content">
        Skip to content
      </a>
      <header className={styles.header} data-section={active}>
        <div className={styles.bar}>
          <Link href={view.path} className={styles.brand} aria-label={`${store.name} home`}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={view.logo ?? asset('/logo.png')} alt="" className={styles.brandLogo} width={40} height={40} />
            <span className={styles.brandText}>
              <span className={styles.brandName}>{store.name}</span>
              <span className={styles.brandTag}>Store on BROKA</span>
            </span>
          </Link>
          <div className={styles.search}>
            <CatalogueControls
              basePath={searchBase ?? paths.shop}
              storeName={store.name}
              filters={store.is_active ? filters : undefined}
            />
          </div>
          <div className={styles.actions}>
            {/* About, on a phone: the bottom bar has room for five, and these are the five that move a purchase on. */}
            <Link
              href={paths.about}
              className={`${shop.iconButton} ${styles.phoneOnly}`}
              aria-label={`About ${store.name}`}
              aria-current={currentMark('about', active)}
            >
              <Icon name="info" />
            </Link>
            <ShareIcon storeId={store.id} url={view.url} title={store.name} />
            {paths.cart && (
              <span className={styles.wideOnly}>
                <CartButton storeId={store.id} cartPage={active === 'cart' ? paths.cart : undefined} />
              </span>
            )}
          </div>
        </div>
        <nav className={styles.sections} aria-label="Store sections">
          <div className={styles.sectionsInner}>
            <ul className={styles.sectionList}>
              {sections.map((s) => (
                <li key={s.key}>
                  <Link href={s.href} className={styles.sectionLink} aria-current={currentMark(s.key, active)}>
                    {s.label}
                  </Link>
                </li>
              ))}
            </ul>
            {paths.orders && (
              <Link href={paths.orders} className={styles.accountLink}>
                <Icon name="receipt" size={17} /> Your orders
              </Link>
            )}
          </div>
        </nav>
      </header>
      {active !== 'messages' && <StoreBottomNav storeId={store.id} paths={paths} page={active} />}
      <RememberStore slug={store.slug} name={store.name} />
    </>
  )
}
