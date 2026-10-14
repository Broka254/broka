'use client'

// A button into the BROKA app for this page: on Android it opens the app
// (or the APK download when the app isn't installed); elsewhere it's the
// download link.
import { useIsAndroid, usePageUrl } from '@/lib/browser'
import { APP_DOWNLOAD_URL } from '@/lib/config'
import { androidAppLink } from '@/lib/links'

export function AppButton({
  label,
  className = 'button',
  chat = false,
}: {
  label: string
  className?: string
  /** On a product page: open the chat with its seller in the app, as a
   *  listing outside a store does (deep_link_service.dart reads ?chat=1). */
  chat?: boolean
}) {
  const android = useIsAndroid()
  const pageUrl = usePageUrl()
  const href = android && pageUrl ? androidAppLink(chat ? withChat(pageUrl) : pageUrl) : APP_DOWNLOAD_URL
  return (
    <a className={className} href={href} rel="nofollow">
      {label}
    </a>
  )
}

/** [url] with ?chat=1, so the app opens the conversation with the seller. */
export function withChat(url: string): string {
  const u = new URL(url)
  u.searchParams.set('chat', '1')
  return u.toString()
}
