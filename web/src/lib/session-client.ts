'use client'

// Whether this browser is signed in to BROKA, for the pages that need it
// (checkout, orders, messages). One read per page load, shared by every
// component on the page; the session itself is in httpOnly cookies the
// page's scripts cannot read (lib/session.ts).
import { useEffect, useSyncExternalStore } from 'react'

import { webFetch } from './web-api'

export interface SessionUser {
  id: string | null
  name: string | null
  phone: string | null
}

export type SessionState =
  | { status: 'loading' }
  | { status: 'signed_out'; error?: string }
  | { status: 'signed_in'; user: SessionUser }

const LOADING: SessionState = { status: 'loading' }
let state: SessionState = LOADING
let loading: Promise<void> | null = null
const listeners = new Set<() => void>()

function set(next: SessionState) {
  state = next
  for (const l of listeners) l()
}

export async function refreshSession(): Promise<void> {
  const r = await webFetch<{ signed_in: boolean; user?: SessionUser }>('/api/stores/session')
  if (r.ok && r.data.signed_in && r.data.user) set({ status: 'signed_in', user: r.data.user })
  else set({ status: 'signed_out', error: r.ok ? undefined : r.error.message })
}

function load() {
  if (!loading) loading = refreshSession()
  return loading
}

export function setSignedIn(user: SessionUser) {
  set({ status: 'signed_in', user })
}

export async function signOut(): Promise<void> {
  await webFetch('/api/stores/session', { method: 'DELETE' })
  set({ status: 'signed_out' })
}

/** Tests: forget what this page knows. */
export function resetSession() {
  state = LOADING
  loading = null
}

function subscribe(l: () => void) {
  listeners.add(l)
  return () => {
    listeners.delete(l)
  }
}

export function useSession(): SessionState {
  const current = useSyncExternalStore(subscribe, () => state, () => LOADING)
  useEffect(() => {
    void load()
  }, [])
  return current
}
