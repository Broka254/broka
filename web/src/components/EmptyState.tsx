// What a page shows when there is nothing to list - no products match, no
// orders yet, no conversations: what is missing, why it may be, and the
// next useful step. One look for all of them.
import type { ReactNode } from 'react'

import { Icon, type IconName } from './Icon'
import styles from './ui.module.css'

export function EmptyState({
  icon,
  title,
  children,
  actions,
  heading: Heading = 'h2',
  testId,
}: {
  icon: IconName
  title: string
  children?: ReactNode
  actions?: ReactNode
  /** The title's level, to fit the page's outline. */
  heading?: 'h1' | 'h2' | 'h3'
  testId?: string
}) {
  return (
    <div className={styles.empty} data-testid={testId}>
      <span className={styles.emptyIcon} aria-hidden="true">
        <Icon name={icon} size={30} />
      </span>
      <Heading className={styles.emptyTitle}>{title}</Heading>
      {children && <div className={styles.emptyText}>{children}</div>}
      {actions && <div className={styles.emptyActions}>{actions}</div>}
    </div>
  )
}
