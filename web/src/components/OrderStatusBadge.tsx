// An order's status as a badge, in the colour of what it means for the
// buyer (lib/orders.ts orderTone) - the same badge in the list of orders
// and on the order itself.
import type { ReactNode } from 'react'

import type { OrderTone } from '@/lib/orders'

import styles from './ui.module.css'

export function OrderStatusBadge({ tone, children, testId }: { tone: OrderTone; children: ReactNode; testId?: string }) {
  return (
    <span className={styles.status} data-tone={tone} data-testid={testId}>
      {children}
    </span>
  )
}
