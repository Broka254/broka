'use client'

// Signing in on the website with an SMS code - no app, no password. An
// existing BROKA account is signed in once the code checks out; a new
// number gives a name and accepts the Terms (the same declarations the
// app's sign-up records). The session is kept by this site's server in
// httpOnly cookies (lib/session.ts); this component never sees a token.
import Link from 'next/link'
import { type FormEvent, useState } from 'react'

import { privacyPath, termsPath } from '@/lib/legal'
import { setSignedIn, type SessionUser } from '@/lib/session-client'
import { webFetch } from '@/lib/web-api'

import styles from './orders.module.css'

type Step = 'phone' | 'code' | 'account'

export function SignInPanel({
  title = 'Sign in to continue',
  lead = "We'll text you a code. No app or password needed.",
  onSignedIn,
}: {
  title?: string
  lead?: string
  onSignedIn?: (user: SessionUser) => void
}) {
  const [step, setStep] = useState<Step>('phone')
  const [phone, setPhone] = useState('')
  const [code, setCode] = useState('')
  const [name, setName] = useState('')
  const [adult, setAdult] = useState(false)
  const [terms, setTerms] = useState(false)
  const [privacy, setPrivacy] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [devCode, setDevCode] = useState<string | null>(null)
  const [isNew, setIsNew] = useState(false)

  const done = (user: SessionUser) => {
    setSignedIn(user)
    onSignedIn?.(user)
  }

  const sendCode = async (e?: FormEvent) => {
    e?.preventDefault()
    if (busy) return
    setBusy(true)
    setError(null)
    const r = await webFetch<{ account_exists: boolean; debug_code?: string }>('/api/stores/session/code', {
      method: 'POST',
      body: { phone },
    })
    setBusy(false)
    if (!r.ok) return setError(r.error.message)
    setIsNew(!r.data.account_exists)
    setDevCode(r.data.debug_code ?? null)
    setCode('')
    setStep('code')
  }

  const verify = async (e: FormEvent) => {
    e.preventDefault()
    if (busy) return
    setBusy(true)
    setError(null)
    const r = await webFetch<{ signed_in: boolean; needs_account?: boolean; user?: SessionUser }>(
      '/api/stores/session/verify',
      { method: 'POST', body: { phone, code } },
    )
    setBusy(false)
    if (!r.ok) return setError(r.error.message)
    if (r.data.signed_in && r.data.user) return done(r.data.user)
    if (r.data.needs_account) setStep('account')
  }

  const createAccount = async (e: FormEvent) => {
    e.preventDefault()
    if (busy) return
    if (!adult || !terms || !privacy) return setError('Tick all three boxes to create your account.')
    setBusy(true)
    setError(null)
    const r = await webFetch<{ signed_in: boolean; user?: SessionUser }>('/api/stores/session/account', {
      method: 'POST',
      body: { name, age_confirmed: adult, terms_accepted: terms, privacy_acknowledged: privacy },
    })
    setBusy(false)
    if (!r.ok) {
      if (r.error.code === 'PHONE_NOT_VERIFIED') setStep('phone')
      return setError(r.error.message)
    }
    if (r.data.user) done(r.data.user)
  }

  return (
    <section className={styles.panel} aria-labelledby="sign-in-title" data-testid="sign-in">
      <h2 id="sign-in-title" className={styles.panelTitle}>
        {step === 'account' ? 'Create your BROKA account' : title}
      </h2>
      {step === 'phone' && (
        <form onSubmit={sendCode} className={styles.field} noValidate>
          <p className={styles.muted}>{lead}</p>
          <label htmlFor="sign-in-phone">Phone number</label>
          <input
            id="sign-in-phone"
            className={styles.input}
            type="tel"
            inputMode="tel"
            autoComplete="tel"
            placeholder="0712 345 678"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            required
          />
          <button type="submit" className={styles.primary} disabled={busy || phone.trim().length < 9}>
            {busy ? 'Sending…' : 'Send me a code'}
          </button>
        </form>
      )}
      {step === 'code' && (
        <form onSubmit={verify} className={styles.field} noValidate>
          <p className={styles.muted}>
            We sent a code to <strong>{phone}</strong>. {isNew ? "It's your first time on BROKA - welcome." : ''}
          </p>
          {devCode && (
            <p className={styles.devCode} data-testid="dev-code">
              Test environment - your code is {devCode}
            </p>
          )}
          <label htmlFor="sign-in-code">Code</label>
          <input
            id="sign-in-code"
            className={styles.input}
            inputMode="numeric"
            autoComplete="one-time-code"
            maxLength={8}
            value={code}
            onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))}
            required
          />
          <button type="submit" className={styles.primary} disabled={busy || code.length < 4}>
            {busy ? 'Checking…' : 'Continue'}
          </button>
          <p className={styles.hint}>
            Wrong number or no code?{' '}
            <button type="button" className={styles.linkish} onClick={() => setStep('phone')}>
              Change number
            </button>{' '}
            or{' '}
            <button type="button" className={styles.linkish} onClick={() => void sendCode()} disabled={busy}>
              send it again
            </button>
            .
          </p>
        </form>
      )}
      {step === 'account' && (
        <form onSubmit={createAccount} className={styles.field} noValidate>
          <p className={styles.muted}>Your number is verified. What should stores call you?</p>
          <label htmlFor="sign-in-name">Your name</label>
          <input
            id="sign-in-name"
            className={styles.input}
            autoComplete="name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            maxLength={80}
            required
          />
          <label className={styles.check}>
            <input type="checkbox" checked={adult} onChange={(e) => setAdult(e.target.checked)} />
            <span>I am at least 18 years old.</span>
          </label>
          <label className={styles.check}>
            <input type="checkbox" checked={terms} onChange={(e) => setTerms(e.target.checked)} />
            <span>
              I agree to BROKA&apos;s{' '}
              <Link href={termsPath} target="_blank">
                Terms of Use and Service
              </Link>
              .
            </span>
          </label>
          <label className={styles.check}>
            <input type="checkbox" checked={privacy} onChange={(e) => setPrivacy(e.target.checked)} />
            <span>
              I have read BROKA&apos;s{' '}
              <Link href={privacyPath} target="_blank">
                Privacy Policy
              </Link>
              .
            </span>
          </label>
          <button type="submit" className={styles.primary} disabled={busy || name.trim().length < 2}>
            {busy ? 'Creating…' : 'Create account and continue'}
          </button>
        </form>
      )}
      {error && (
        <p className={styles.error} role="alert">
          {error}
        </p>
      )}
    </section>
  )
}
