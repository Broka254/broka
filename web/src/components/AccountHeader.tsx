// The top of the buyer's own BROKA pages - their orders and their messages,
// from every store. Deliberately not a store's header: a list with three
// shops' orders in it must not look like one shop's page. So BROKA is the
// brand here, the account's two sections are the tabs, and the way back to
// shopping names the store the buyer came from (LastStore.tsx).
import Image from 'next/image'
import Link from 'next/link'

import { accountMessagesPath, asset } from '@/lib/links'
import { ordersPath } from '@/lib/orders'

import { HomeLink } from './HomeLink'
import { Icon } from './Icon'
import { ContinueShopping } from './LastStore'
import styles from './store-nav.module.css'

/** Which account page this is: the list of orders, one order, or the messages. */
export type AccountPage = 'orders' | 'order' | 'messages'

export function AccountHeader({ active }: { active: AccountPage }) {
  const ordersMark = active === 'orders' ? 'page' : active === 'order' ? 'true' : undefined
  return (
    <>
      <a className="skip-link" href="#main-content">
        Skip to content
      </a>
      <header className={styles.accountHeader}>
        <div className={styles.accountBar}>
          {/* The logo is unoptimized: /_next/image on broka.co.ke is the BROKA website's (SiteHeader.tsx). */}
          <HomeLink className={styles.accountBrand} aria-label="BROKA home">
            <Image src={asset('/logo.png')} unoptimized alt="" width={30} height={30} priority />
            <span className={styles.accountWord}>BROKA</span>
          </HomeLink>
          <span className={styles.accountContext}>Your account</span>
          <ContinueShopping className={styles.continue} />
        </div>
        <nav className={styles.accountTabs} aria-label="Your account">
          <Link href={ordersPath} className={styles.accountTab} aria-current={ordersMark}>
            <Icon name="receipt" size={18} /> Orders
          </Link>
          <Link
            href={accountMessagesPath}
            className={styles.accountTab}
            aria-current={active === 'messages' ? 'page' : undefined}
          >
            <Icon name="chat" size={18} /> Messages
          </Link>
        </nav>
      </header>
    </>
  )
}
