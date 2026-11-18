// The top of a conversation with a store: who it is with - the store's sign
// and name, a link to its shop - and, for a question about one product,
// that product, its price and the way back to it. On a phone it is the
// chat screen's header: the way back first, then the store, then every
// other conversation.
import Link from 'next/link'

import { accountMessagesPath } from '@/lib/links'

import { Icon } from './Icon'
import styles from './messaging.module.css'
import { StoreAvatar } from './StoreAvatar'

export interface ChatStore {
  id: string
  slug: string
  name: string
  logo: string | null
  /** The store's home on the website. */
  href: string
  /** Its catalogue: where "Continue shopping" goes. */
  shopHref: string
}

export interface ChatProduct {
  id: string
  name: string
  image: string | null
  emoji: string
  /** "KES 15,000", or null when the listing gave none. */
  priceLabel: string | null
  href: string
}

export function ConversationHeader({
  store,
  product,
  back,
}: {
  store: ChatStore
  product: ChatProduct | null
  back: { href: string; label: string }
}) {
  return (
    <div className={styles.chatTop}>
      <header className={styles.chatHead}>
        <Link href={back.href} className={styles.backButton} aria-label={back.label}>
          <Icon name="back" size={20} />
        </Link>
        <Link href={store.href} className={styles.identity}>
          <StoreAvatar name={store.name} logo={store.logo} size={40} />
          <span className={styles.identityText}>
            <strong>{store.name}</strong>
            <small>Store on BROKA</small>
          </span>
        </Link>
        <div className={styles.headActions}>
          <Link href={store.shopHref} className={styles.headLink} aria-label={`Continue shopping at ${store.name}`}>
            <Icon name="bag" size={17} />
            <span className={styles.headLinkText} aria-hidden="true">
              Continue shopping
            </span>
          </Link>
          <Link href={accountMessagesPath} className={`${styles.headLink} ${styles.phoneOnly}`} aria-label="All conversations">
            <Icon name="chat" size={17} />
          </Link>
        </div>
      </header>
      {product && (
        <Link href={product.href} className={styles.productContext} data-testid="chat-product">
          <span className={styles.productThumb} aria-hidden="true">
            {product.image ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={product.image} alt="" loading="lazy" decoding="async" />
            ) : (
              product.emoji
            )}
          </span>
          <span className={styles.productText}>
            <small>About this product</small>
            <strong>{product.name}</strong>
            {product.priceLabel && <span>{product.priceLabel}</span>}
          </span>
          <span className={styles.productGo}>
            View <Icon name="chevron" size={15} />
          </span>
        </Link>
      )}
    </div>
  )
}
