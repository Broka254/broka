import { HomeLink } from '@/components/HomeLink'
import { SiteHeader } from '@/components/SiteHeader'

import styles from './message.module.css'

export default function NotFound() {
  return (
    <>
      <SiteHeader />
      <main className={`page ${styles.main}`}>
        <p className={styles.emoji} aria-hidden="true">
          🔭
        </p>
        <h1>Nothing here</h1>
        <p className="muted">This page doesn&apos;t exist, or it has moved.</p>
        <HomeLink className="button">Go to BROKA</HomeLink>
      </main>
    </>
  )
}
