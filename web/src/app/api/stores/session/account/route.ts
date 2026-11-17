// Create a buyer account for the phone just verified (POST {name, age_confirmed,
// terms_accepted, privacy_acknowledged}). The documents' versions are the
// ones this site showed (lib/legal.ts); the API refuses any other.
import { type NextRequest, NextResponse } from 'next/server'

import { PRIVACY_VERSION, TERMS_VERSION } from '@/lib/legal'
import { PHONE_COOKIE, callApi, crossSite, errorBody, readJson, signedIn, withCookies } from '@/lib/session'

export async function POST(req: NextRequest) {
  const refused = crossSite(req)
  if (refused) return refused
  const token = req.cookies.get(PHONE_COOKIE)?.value
  if (!token) {
    return NextResponse.json(
      { error: { code: 'PHONE_NOT_VERIFIED', message: 'Verify your phone number again to continue.' } },
      { status: 400 },
    )
  }
  const body = await readJson(req)
  const name = typeof body?.name === 'string' ? body.name.trim().slice(0, 80) : ''
  const result = await callApi(req, '/auth/otp/sign-in/register', {
    method: 'POST',
    auth: false,
    body: {
      phone_verify_token: token,
      name,
      legal_acceptance: {
        // Exactly what the person ticked: a missing tick is false, never a default.
        age_confirmed: body?.age_confirmed === true,
        terms_accepted: body?.terms_accepted === true,
        privacy_acknowledged: body?.privacy_acknowledged === true,
        terms_version: TERMS_VERSION,
        privacy_version: PRIVACY_VERSION,
      },
    },
  })
  if (result.status !== 201 && result.status !== 200) {
    return NextResponse.json(errorBody(result.status, result.data), { status: result.status })
  }
  const d = (result.data ?? {}) as Record<string, unknown>
  return withCookies(
    NextResponse.json({ signed_in: true, user: { id: d.user_id ?? null, name: d.name ?? null, phone: d.phone ?? null } }),
    signedIn(d),
  )
}
