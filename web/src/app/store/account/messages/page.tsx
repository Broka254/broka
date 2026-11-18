// A buyer's conversations with every store, on the web:
// https://broka.co.ke/store/account/messages - their BROKA account, beside
// their orders, so it wears the account's header and not one store's.
// "account" is a reserved store link name (backend stores/naming.py), so no
// store can own this address. The list is the buyer's own and is read in
// the browser (InboxView): personal, so never indexed and never cached.
import type { Metadata } from 'next'

import { AccountHeader } from '@/components/AccountHeader'
import { InboxView } from '@/components/InboxView'
import { SiteFooter } from '@/components/SiteFooter'
import account from '@/components/account.module.css'

export const metadata: Metadata = {
  title: 'Your messages',
  robots: { index: false, follow: false },
}

export const dynamic = 'force-dynamic'

export default function AccountMessagesPage() {
  return (
    <>
      <AccountHeader active="messages" />
      <main id="main-content" className={`page ${account.accountPage}`}>
        <InboxView />
      </main>
      <SiteFooter />
    </>
  )
}
