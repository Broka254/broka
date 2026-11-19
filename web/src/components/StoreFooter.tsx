// The foot of a store's pages, as a shop's website ends: the store, its
// departments, help with buying, and how paying works (the store directly,
// while BROKA holds no payments: lib/safety.ts) - then "powered by BROKA".
import Link from 'next/link'
import type { CSSProperties } from 'react'

import { filtersQuery } from '@/lib/catalogue'
import { placeLine } from '@/lib/format'
import { storeDetailsPath, storeShopPath } from '@/lib/links'
import { NO_DEPOSIT, PAY_LINE, PERK_SEE_FIRST } from '@/lib/safety'
import { storePaths } from '@/lib/store-nav'
import type { StoreView } from '@/lib/storefront'
import type { StoreCategory } from '@/lib/types'

import { HomeLink } from './HomeLink'
import { Icon } from './Icon'
import styles from './shop.module.css'

export function StoreFooter({ view, categories = [] }: { view: StoreView; categories?: StoreCategory[] }) {
  const { store } = view
  const shopPath = storeShopPath(store.slug)
  const paths = storePaths(store)
  const where = placeLine(store.subcounty, store.county)
  return (
    // data-store-footer: the product page's buy bar keeps off the footer (ProductStickyBar).
    <footer className={styles.footer} data-store-footer>
      <div className={styles.footerGrid}>
        <div>
          <p className={styles.footerBrand}>{store.name}</p>
          {store.category && <p className={styles.footerMuted}>{store.category}</p>}
          {where && (
            <p className={styles.footerMuted}>
              <Icon name="pin" size={14} /> {where}
            </p>
          )}
        </div>
        <nav aria-label="Shop">
          <p className={styles.footerTitle}>Shop</p>
          <ul>
            <li>
              <Link href={shopPath}>All products</Link>
            </li>
            {categories.slice(0, 5).map((c) => (
              <li key={c.name}>
                <Link href={`${shopPath}${filtersQuery({ category: c.name })}`}>{c.name}</Link>
              </li>
            ))}
          </ul>
        </nav>
        <nav aria-label="Help">
          <p className={styles.footerTitle}>Help</p>
          <ul>
            <li>
              <Link href={storeDetailsPath(store.slug)}>Store details</Link>
            </li>
            {paths.messages && (
              <li>
                <Link href={paths.messages}>Message the store</Link>
              </li>
            )}
            {paths.cart && (
              <li>
                <Link href={paths.cart}>Your cart</Link>
              </li>
            )}
            {paths.orders && (
              <li>
                <Link href={paths.orders}>Your orders</Link>
              </li>
            )}
            <li>
              <HomeLink>About BROKA</HomeLink>
            </li>
            <li>
              <Link href="/download">Get the BROKA app</Link>
            </li>
          </ul>
        </nav>
        <div>
          <p className={styles.footerTitle}>Paying</p>
          <p className={styles.footerPay}>
            <span className={styles.mpesa}>M-PESA</span>
            <span className={styles.payTag}>
              <Icon name="check" size={14} /> {PERK_SEE_FIRST.title}
            </span>
          </p>
          <p className={styles.footerMuted}>
            {PAY_LINE} {NO_DEPOSIT}
          </p>
        </div>
      </div>
      <p className={styles.footerBase}>
        © {store.name} · Powered by <HomeLink>BROKA</HomeLink>, Kenya&apos;s AI-brokered marketplace
      </p>
      {/* The store's name across the foot, as a sign: decoration, sized
          from its length (shop.module.css .footerMark). */}
      <p className={styles.footerMark} aria-hidden="true" style={{ '--len': Array.from(store.name).length } as CSSProperties}>
        {store.name}
      </p>
    </footer>
  )
}
