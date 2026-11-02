import type { ReactNode } from 'react'

import styles from './shop.module.css'

/** Shared, store-agnostic retail canvas for every public storefront route. */
export function StorefrontShell({ children }: { children: ReactNode }) {
  return (
    <div className={styles.storefront} data-storefront-theme="light">
      {children}
    </div>
  )
}
