import { HomeLink } from '@/components/HomeLink'
import { SiteHeader } from '@/components/SiteHeader'

import styles from '../../../../message.module.css'

export default function ProductNotFound() {
  return (
    <>
      <SiteHeader />
      <main className={`page ${styles.main}`}>
        <p className={styles.emoji} aria-hidden="true">
          🔎
        </p>
        <h1>Product not found</h1>
        <p className="muted">
          This product isn&apos;t in this store, or the link is incomplete.
        </p>
        <HomeLink className="button">Go to BROKA</HomeLink>
      </main>
    </>
  )
}
