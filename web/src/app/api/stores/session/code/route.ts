// Send a sign-in code to a phone number (POST {phone}).
import type { NextRequest } from 'next/server'

import { callApi, crossSite, readJson, respond } from '@/lib/session'

export async function POST(req: NextRequest) {
  const refused = crossSite(req)
  if (refused) return refused
  const body = await readJson(req)
  const phone = typeof body?.phone === 'string' ? body.phone.trim().slice(0, 32) : ''
  if (!phone) {
    return respond({ status: 400, data: { detail: { code: 'PHONE_REQUIRED', message: 'Enter your phone number.' } }, cookies: [] })
  }
  const result = await callApi(req, '/auth/otp/sign-in/request', { method: 'POST', body: { phone }, auth: false })
  return respond(result, (data) => {
    const d = (data ?? {}) as Record<string, unknown>
    return {
      phone: d.phone,
      account_exists: d.account_exists === true,
      expires_in_seconds: d.expires_in_seconds,
      // Only a test environment's API sends this (never production, where
      // the code arrives by SMS): it lets the full journey be tried there.
      ...(typeof d.debug_code === 'string' ? { debug_code: d.debug_code } : {}),
    }
  })
}
