import type { ReactNode } from 'react'

import styles from './shop.module.css'

/** Shared, store-agnostic canvas over BROKA's connected constellation background. */
export function StorefrontShell({ children }: { children: ReactNode }) {
  return (
    <div className={styles.storefront} data-storefront-theme="premium">
      {children}
    </div>
  )
}
