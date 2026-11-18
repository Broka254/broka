import type { ReactNode } from 'react'

import styles from './shop.module.css'

/**
 * Shared, store-agnostic canvas over BROKA's connected constellation
 * background: every store page and the buyer's account pages. `layout="chat"`
 * is the messages page, which on a phone is a chat screen - no store header,
 * footer or bottom bar around the conversation.
 */
export function StorefrontShell({ children, layout }: { children: ReactNode; layout?: 'chat' }) {
  return (
    <div className={styles.storefront} data-storefront-theme="premium" data-layout={layout}>
      {children}
    </div>
  )
}
