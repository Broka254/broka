'use client'

// When the BROKA API doesn't answer (it sleeps when idle on the free
// hosting plan and takes a moment to wake), offer a retry instead of a
// dead end.
import { useEffect } from 'react'

import styles from './message.module.css'

export default function ErrorPage({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    console.error(error)
  }, [error])

  return (
    <main className={`page ${styles.main}`}>
      <p className={styles.emoji} aria-hidden="true">
        ⏳
      </p>
      <h1>BROKA is waking up</h1>
      <p className="muted">That took longer than it should. Give it a moment and try again.</p>
      <button type="button" className="button" onClick={() => reset()}>
        Try again
      </button>
    </main>
  )
}
