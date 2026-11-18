// One order: https://broka.co.ke/store/orders/<id>. The page is a frame -
// the order itself is read in the browser, with the buyer's own session,
// so nothing about it is rendered or cached on the server, and a link to it
// shows nothing to anyone but the buyer (the API answers 404 otherwise).
// The escrow directory is fetched here, as on the cart page, for choosing
// how to pay. The order's own store - its page, its messages - is linked
// from the order (OrderView.tsx); the header is the buyer's account.
import type { Metadata } from 'next'

import { AccountHeader } from '@/components/AccountHeader'
import { OrderView } from '@/components/OrderView'
import { SiteFooter } from '@/components/SiteFooter'
import account from '@/components/account.module.css'
import { getEscrowDirectory } from '@/lib/api'

export const metadata: Metadata = {
  title: 'Your order',
  robots: { index: false, follow: false },
}

export const dynamic = 'force-dynamic'

type Props = { params: Promise<{ orderId: string }> }

export default async function OrderPage({ params }: Props) {
  const { orderId } = await params
  const escrow = await getEscrowDirectory()
  return (
    <>
      <AccountHeader active="order" />
      <main id="main-content" className={`page ${account.accountPage}`}>
        <OrderView orderId={orderId} escrow={escrow} />
      </main>
      <SiteFooter />
    </>
  )
}
