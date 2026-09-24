'use client'

// "Open in the BROKA app" for Android visitors. The intent: link opens this
// same page in the app when it's installed (even before App Links are
// verified), and the APK download when it isn't.
import { useState } from 'react'

import { useIsAndroid, usePageUrl, useSessionFlag } from '@/lib/browser'
import { androidAppLink } from '@/lib/links'

import styles from './OpenInApp.module.css'

const DISMISSED = 'broka_open_in_app_dismissed'

export function OpenInApp() {
  const android = useIsAndroid()
  const pageUrl = usePageUrl()
  const dismissedBefore = useSessionFlag(DISMISSED)
  const [dismissed, setDismissed] = useState(false)

  if (!android || !pageUrl || dismissedBefore || dismissed) return null
  return (
    <div className={styles.banner} role="region" aria-label="Open in the BROKA app">
      <span className={styles.text}>Shop faster in the BROKA app</span>
      <a className={styles.open} href={androidAppLink(pageUrl)}>
        Open
      </a>
      <button
        type="button"
        className={styles.close}
        aria-label="Dismiss"
        onClick={() => {
          try {
            sessionStorage.setItem(DISMISSED, '1')
          } catch {
            // Ignore: it just shows again next time.
          }
          setDismissed(true)
        }}
      >
        ×
      </button>
    </div>
  )
}
