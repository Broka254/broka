// Check a sign-in code (POST {phone, code}). An existing account is signed
// in; a new number gets a short-lived proof of the phone, kept server-side,
// for the "create your account" step.
import { type NextRequest, NextResponse } from 'next/server'

import { callApi, crossSite, errorBody, phoneVerified, readJson, signedIn, withCookies } from '@/lib/session'

export async function POST(req: NextRequest) {
  const refused = crossSite(req)
  if (refused) return refused
  const body = await readJson(req)
  const phone = typeof body?.phone === 'string' ? body.phone.trim().slice(0, 32) : ''
  const code = typeof body?.code === 'string' ? body.code.replace(/\s+/g, '').slice(0, 12) : ''
  if (!phone || !code) {
    return NextResponse.json({ error: { code: 'CODE_REQUIRED', message: 'Enter the code we sent you.' } }, { status: 400 })
  }
  const result = await callApi(req, '/auth/otp/sign-in/verify', { method: 'POST', body: { phone, code }, auth: false })
  if (result.status !== 200) return withCookies(NextResponse.json(errorBody(result.status, result.data), { status: result.status }), [])
  const d = (result.data ?? {}) as Record<string, unknown>
  if (d.account_exists === true) {
    return withCookies(
      NextResponse.json({ signed_in: true, user: { id: d.user_id ?? null, name: d.name ?? null, phone: d.phone ?? null } }),
      signedIn(d),
    )
  }
  if (typeof d.phone_verify_token === 'string') {
    return withCookies(NextResponse.json({ signed_in: false, needs_account: true }), phoneVerified(d.phone_verify_token))
  }
  return NextResponse.json({ error: { code: 'SIGN_IN_FAILED', message: 'That didn’t work. Request a new code.' } }, { status: 502 })
}
