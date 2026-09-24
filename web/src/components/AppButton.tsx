'use client'

// A button into the BROKA app for this page: on Android it opens the app
// (or the APK download when the app isn't installed); elsewhere it's the
// download link.
import { useIsAndroid, usePageUrl } from '@/lib/browser'
import { APP_DOWNLOAD_URL } from '@/lib/config'
import { androidAppLink } from '@/lib/links'

export function AppButton({ label, className = 'button' }: { label: string; className?: string }) {
  const android = useIsAndroid()
  const pageUrl = usePageUrl()
  const href = android && pageUrl ? androidAppLink(pageUrl) : APP_DOWNLOAD_URL
  return (
    <a className={className} href={href} rel="nofollow">
      {label}
    </a>
  )
}
