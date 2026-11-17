// The documents a new BROKA account accepts, as the web storefront shows
// them, and the revisions it sends with the acceptance. The backend holds
// the same ids and versions (api/core/legal_documents.py) and refuses a
// signup that names another revision; lib/legal.test.ts keeps these in step
// with it and with the app's text.
export { PRIVACY_MARKDOWN, TERMS_MARKDOWN } from './legal-text'

/** The Terms' own "last updated" date (backend TERMS.version). */
export const TERMS_VERSION = '2026-10-12'

/** No Privacy Policy is approved yet; the placeholder says so, and this is
 *  what the app sends too (backend PRIVACY.version). */
export const PRIVACY_VERSION = 'unpublished'

export const termsPath = '/store/legal/terms'
export const privacyPath = '/store/legal/privacy'
