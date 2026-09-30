// The foot of a store's pages, as a shop's website ends: the store, its
// departments, help with buying, and how paying works - then "powered by
// BROKA".
import Link from 'next/link'

import { filtersQuery } from '@/lib/catalogue'
import { placeLine } from '@/lib/format'
import { storeCartPath, storeDetailsPath } from '@/lib/links'
import type { StoreView } from '@/lib/storefront'
import type { StoreCategory } from '@/lib/types'

import { HomeLink } from './HomeLink'
import { Icon } from './Icon'
import styles from './shop.module.css'

export function StoreFooter({ view, categories = [] }: { view: StoreView; categories?: StoreCategory[] }) {
  const { store } = view
  const where = placeLine(store.subcounty, store.county)
  return (
    <footer className={styles.footer}>
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
              <Link href={view.path}>All products</Link>
            </li>
            {categories.slice(0, 5).map((c) => (
              <li key={c.name}>
                <Link href={`${view.path}${filtersQuery({ category: c.name })}`}>{c.name}</Link>
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
            <li>
              <Link href={storeCartPath(store.slug)}>Your cart</Link>
            </li>
            <li>
              <HomeLink>About BROKA</HomeLink>
            </li>
          </ul>
        </nav>
        <div>
          <p className={styles.footerTitle}>Paying</p>
          <p className={styles.footerPay}>
            <span className={styles.mpesa}>M-PESA</span>
            <span className={styles.escrowTag}>
              <Icon name="shield" size={14} /> Escrow
            </span>
          </p>
          <p className={styles.footerMuted}>
            Your money is held by BROKA until you confirm you received what you paid for.
          </p>
        </div>
      </div>
      <p className={styles.footerBase}>
        © {store.name} · Powered by <HomeLink>BROKA</HomeLink>, Kenya&apos;s AI-brokered marketplace
      </p>
    </footer>
  )
}
