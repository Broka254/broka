// A buyer's orders on the web: https://broka.co.ke/store/orders. "orders" is
// a reserved store link name (backend stores/naming.py), so no store can
// own this address. Personal, so never indexed and never cached.
import type { Metadata } from 'next'

import { OrdersList } from '@/components/OrdersList'
import { SiteFooter } from '@/components/SiteFooter'
import { SiteHeader } from '@/components/SiteHeader'

export const metadata: Metadata = {
  title: 'Your orders',
  robots: { index: false, follow: false },
}

export const dynamic = 'force-dynamic'

export default function OrdersPage() {
  return (
    <>
      <SiteHeader />
      <main className="page">
        <OrdersList />
      </main>
      <SiteFooter />
    </>
  )
}
