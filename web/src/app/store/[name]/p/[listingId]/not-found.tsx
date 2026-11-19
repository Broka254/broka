import { HomeLink } from '@/components/HomeLink'
import { Icon } from '@/components/Icon'
import { SiteHeader } from '@/components/SiteHeader'

import styles from '../../../../message.module.css'

export default function ProductNotFound() {
  return (
    <>
      <SiteHeader />
      <main className={`page ${styles.main}`}>
        <span className={styles.mark} aria-hidden="true">
          <Icon name="bag" size={32} />
        </span>
        <h1>Product not found</h1>
        <p className="muted">
          This product isn&apos;t in this store, or the link is incomplete.
        </p>
        <HomeLink className="button">Go to BROKA</HomeLink>
      </main>
    </>
  )
}
