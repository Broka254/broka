// A buyer's orders on the web: https://broka.co.ke/store/orders. "orders" is
// a reserved store link name (backend stores/naming.py), so no store can
// own this address. Personal, so never indexed and never cached. Orders
// from every store are here, so the page wears BROKA's account header, not
// a store's (AccountHeader.tsx).
import type { Metadata } from 'next'

import { AccountHeader } from '@/components/AccountHeader'
import { OrdersList } from '@/components/OrdersList'
import { SiteFooter } from '@/components/SiteFooter'
import account from '@/components/account.module.css'

export const metadata: Metadata = {
  title: 'Your orders',
  robots: { index: false, follow: false },
}

export const dynamic = 'force-dynamic'

export default function OrdersPage() {
  return (
    <>
      <AccountHeader active="orders" />
      <main id="main-content" className={`page ${account.accountPage}`}>
        <OrdersList />
      </main>
      <SiteFooter />
    </>
  )
}
