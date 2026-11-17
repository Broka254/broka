import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

import { PRIVACY_MARKDOWN, PRIVACY_VERSION, TERMS_MARKDOWN, TERMS_VERSION } from './legal'

// The tests run from web/; the app and the API are beside it in the repo.
const repoFile = (...parts: string[]) => readFileSync(resolve(process.cwd(), '..', ...parts), 'utf8')

describe('legal documents on the web', () => {
  it("are the app's own text, character for character", () => {
    expect(TERMS_MARKDOWN).toBe(repoFile('flutter_app', 'assets', 'legal', 'terms.md'))
    expect(PRIVACY_MARKDOWN).toBe(repoFile('flutter_app', 'assets', 'legal', 'privacy.md'))
  })

  it('are sent with the revisions the API requires - it refuses any other', () => {
    const py = repoFile('backend', 'api', 'core', 'legal_documents.py')
    expect(py.match(/key="terms"[\s\S]*?version="([^"]+)"/)?.[1]).toBe(TERMS_VERSION)
    expect(py.match(/key="privacy"[\s\S]*?version="([^"]+)"/)?.[1]).toBe(PRIVACY_VERSION)
  })

  it("name the Terms' own date, so a changed document is noticed", () => {
    // "_Last updated: 12 October 2026_" is where the revision comes from.
    expect(TERMS_MARKDOWN).toContain('_Last updated: 12 October 2026_')
    expect(TERMS_VERSION).toBe('2026-10-12')
  })
})
