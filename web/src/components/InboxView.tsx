'use client'

// The buyer's conversations with every store on BROKA: their account's
// Messages page. Signing in is the same SMS code as everywhere on the
// website. Each conversation opens on its own store's messages page, inside
// that store's website, where the store's cart and catalogue are a tap away.
import { signOut, useSession } from '@/lib/session-client'

import account from './account.module.css'
import { ConversationList } from './ConversationList'
import orders from './orders.module.css'
import { SignInPanel } from './SignInPanel'

export function InboxView() {
  const session = useSession()
  if (session.status === 'loading') return <p className={orders.muted}>Loading…</p>
  if (session.status === 'signed_out') {
    return (
      <SignInPanel
        title="Sign in to see your messages"
        lead="Use the phone number you message stores with. We'll text you a code."
      />
    )
  }
  return (
    <section aria-labelledby="inbox-title">
      <header className={account.pageHead}>
        <div>
          <h1 id="inbox-title">Messages</h1>
          <p>Your conversations with stores on BROKA.</p>
        </div>
        <p className={orders.muted}>
          Signed in as {session.user.name ?? session.user.phone}.{' '}
          <button type="button" className={orders.linkish} onClick={() => void signOut()}>
            Sign out
          </button>
        </p>
      </header>
      <ConversationList variant="inbox" />
      <p className={account.appNote}>
        Chats about listings outside stores, and Zeno&apos;s messages, are in the BROKA app.
      </p>
    </section>
  )
}
