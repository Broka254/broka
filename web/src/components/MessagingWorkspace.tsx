'use client'

// The messages page of a store's website. On a wide screen, two panels: the
// buyer's conversations with this store down the side (ConversationList),
// the open one beside it - who it is with, the product it is about, the
// messages and the box to write in. On a phone, a chat screen: the open
// conversation alone, with the way back to the product or the store, and
// every conversation one tap away on the account's Messages page.
import { useState, useSyncExternalStore } from 'react'

import { type Conversation, conversationKey } from '@/lib/conversations'
import { storeMessagesPath } from '@/lib/links'
import { useSession } from '@/lib/session-client'

import { type ChatProduct, type ChatStore, ConversationHeader } from './ConversationHeader'
import { ConversationList } from './ConversationList'
import { EnquiryThread } from './EnquiryThread'
import styles from './messaging.module.css'

// Wide enough for the conversations beside the open one (messaging.module.css).
const WIDE = '(min-width: 861px)'

function subscribeWide(onChange: () => void) {
  if (typeof window.matchMedia !== 'function') return () => {}
  const query = window.matchMedia(WIDE)
  query.addEventListener('change', onChange)
  return () => query.removeEventListener('change', onChange)
}

const isWide = () => typeof window.matchMedia === 'function' && window.matchMedia(WIDE).matches

/** Whether the list of conversations has room beside the open one. On a
 *  phone it is not mounted at all, rather than hidden - a hidden list would
 *  still read the inbox on every visit, for nothing anyone sees. */
function useWide(): boolean {
  return useSyncExternalStore(subscribeWide, isWide, () => false)
}

export function MessagingWorkspace({
  store,
  product,
  back,
}: {
  store: ChatStore
  product: ChatProduct | null
  /** Where the conversation was opened from: the product, or the store. */
  back: { href: string; label: string }
}) {
  const session = useSession()
  const wide = useWide()
  // Bumped when the conversation moves, so the list's last lines catch up
  // without a list read every few seconds of its own.
  const [version, setVersion] = useState(0)
  const activeKey = conversationKey(store.id, product?.id)
  const draft: Conversation = {
    key: activeKey,
    store: { id: store.id, slug: store.slug, name: store.name, logo: store.logo },
    product: product ? { id: product.id, name: product.name, image: product.image } : null,
    last: { text: null, from: null, at: null },
    href: storeMessagesPath(store.slug, product?.id),
  }
  const showList = session.status === 'signed_in' && wide

  return (
    <div className={`${styles.workspace} ${showList ? '' : styles.workspaceSolo}`}>
      {showList && (
        <aside className={styles.listPanel} aria-labelledby="conversations-title">
          <div className={styles.listHead}>
            <h2 id="conversations-title">Your conversations</h2>
            <p>With {store.name}</p>
          </div>
          <div className={styles.listScroll}>
            <ConversationList
              variant="store"
              store={{ id: store.id, name: store.name }}
              activeKey={activeKey}
              draft={draft}
              version={version}
            />
          </div>
        </aside>
      )}
      <div className={styles.chatPanel}>
        <EnquiryThread
          // A different conversation is a different thread: nothing of the
          // last one's messages, draft or scroll position carries over.
          key={activeKey}
          storeId={store.id}
          storeName={store.name}
          storeLogo={store.logo}
          listingId={product?.id}
          productName={product?.name}
          header={<ConversationHeader store={store} product={product} back={back} />}
          onActivity={() => setVersion((v) => v + 1)}
        />
      </div>
    </div>
  )
}
