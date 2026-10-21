# Legal acceptance at sign-up

A new BROKA account is created only when the person has explicitly confirmed
three things, and the backend has recorded evidence of each in the same
transaction as the account itself.

This document covers what is enforced, where the documents live, how to
change them, and what is still missing before release.

## What must be declared

On the final sign-up step, all three start unchecked:

1. **Age eligibility** — "I confirm that I am at least 18 years old and
   eligible to use BROKA under its Terms of Use and Service."
2. **Terms** — "I agree to BROKA's Terms of Use and Service." The linked
   phrase opens the Terms screen.
3. **Privacy Policy acknowledgement** — "I acknowledge that I have read
   BROKA's Privacy Policy." The linked phrase opens the Privacy Policy
   screen.

Opening either document does not tick a box. The button is disabled until
all three are ticked; a tap on it explains what is missing. The app sends the
three booleans and the exact document versions it displayed, and the server
decides independently whether to accept them.

The age row records a **declaration of eligibility**. It is not, and is not
presented as, verified proof of the user's age, and no extra personal data is
collected to make it look like one.

## Where the documents live

| | Terms of Use and Service | Privacy Policy |
|---|---|---|
| Bundled text | `flutter_app/assets/legal/terms.md` | `flutter_app/assets/legal/privacy.md` |
| Version | `2026-10-12` | `unpublished` |
| App constant | `flutter_app/lib/core/legal/legal_documents.dart` | same |
| Backend registry | `backend/api/core/legal_documents.py` | same |
| Published URL | none claimed | none claimed |
| Status | agreed, dated 12 October 2026 | **not supplied** |

`TERMS.md` points at the Terms asset. The website's
`https://www.broka.co.ke/terms` and `/privacy` pages are **the website's**
documents: they say so themselves, and the website Terms say app use is
covered by the terms accepted at sign-up. They must not be reused as the
app's documents or cited in acceptance records.

Publishing the app documents at stable public URLs requires the website
repository, which is not this one (`web/` only serves `/store/*`). Required
there: a page containing the same text as `terms.md` and one containing the
approved app Privacy Policy, after which `public_url` can be set in the
backend registry. Until that exists, the app documents are bundled and
available offline, and no URL is claimed.

## Changing a document

The version is the document's own last-updated date. A change to the text is
a new revision, even a typo fix, because acceptance records point at the text
that was shown.

1. Edit the Markdown asset and its `_Last updated: DD Month YYYY_` line.
2. Update `version` and `digest` (SHA-256 of the file's bytes) in
   `backend/api/core/legal_documents.py`.
3. Update `version` in `flutter_app/lib/core/legal/legal_documents.dart`.
4. Run the backend suite. `tests/test_legal_documents.py` fails until all
   three agree, and it also checks the declaration wording and the
   `published` flag.

It is deliberately not possible to change the text while leaving the version
alone: the old acceptance would name a revision whose contents no longer
exist. When a version changes, the backend accepts only the new one; older
app builds that submit the old version are refused with a message asking them
to re-read the document.

## What is recorded

`legal_acceptances` (`backend/api/models/legal.py`), one row per document per
account:

| column | value |
|---|---|
| `user_id` | the account created in the same transaction |
| `acceptance_type` | `age_confirmed`, `terms_accepted` or `privacy_acknowledged` |
| `document_id` | `age_eligibility`, `terms_of_use_and_service` or `privacy_policy` |
| `document_version` | the revision accepted (`1` for the age wording) |
| `document_digest` | SHA-256 of the text shown; NULL for the age declaration |
| `accepted_at` | server clock, naive UTC, one instant for all three |

Not recorded, on purpose: IP address, device identifiers, user agent, and any
timestamp the client sent. The request model rejects extra fields inside the
legal block, and the server never reads a client timestamp.

`(user_id, acceptance_type, document_version)` is unique, so duplicate
submissions cannot append inconsistent evidence, while a future revision gets
its own row instead of overwriting history.

## Transaction and refusal behaviour

- User insert, acceptance rows and the account's transaction are one commit.
  The user is flushed first only so the foreign key exists.
- Any failure rolls the whole attempt back: an account never exists without
  its complete evidence.
- A concurrent duplicate that wins the phone/email unique constraint returns
  409; nothing from the losing attempt survives.
- Missing declarations, `false`, non-boolean values, missing/stale versions
  and a client timestamp inside the legal block are all 422 with a short
  message written for the app, not a field dump.
- Registration rate limiting is unchanged and applies before validation.

## Existing users and later revisions

Accounts that predate this feature have no rows, and nothing backfills them:
a fabricated acceptance is worse than an honest gap.

The evidence model is append-only and versioned, so a future material change
can require re-acceptance by comparing each user's latest accepted version
with the current one. That re-acceptance flow is not built here; when it is,
it must skip unchanged documents (the version comparison does that) and it
must not treat an old acceptance as accepting a new document.

## Rollout and compatibility

The backend enforces the declarations from the moment it is deployed. An app
build that does not send `legal_acceptance` gets a 422 and cannot create an
account; this is intentional and must not be relaxed for compatibility.

Recommended order:

1. Deploy the backend (`python -m api.migrate` first — schema version 8
   creates `legal_acceptances`).
2. Publish the app build immediately. Until the update reaches a user's
   phone, that user cannot register, though login, verification and password
   recovery are unaffected.
3. A staged app rollout should be completed promptly rather than left open:
   every not-yet-updated device is a blocked sign-up.

If a document version changes later, the same coupling applies to the two
stores: either finish the app rollout before bumping the accepted version, or
accept that older builds are refused until they update.

## Privacy content blocker

**The Privacy Policy has not been supplied.** `assets/legal/privacy.md` is a
placeholder that says so, and both the app screen and the backend registry
mark it `published: false` / version `unpublished`. The mechanism is
complete and tested, but a release that ships the placeholder would ask
people to acknowledge a policy that does not exist, so **the release is
blocked until approved text is inserted**, the document is dated, and the
version/digest are updated as above.

The approved text must describe BROKA's actual processing. Do not derive it
from this document or from the website's website-scoped policy. Points that
need checking against the implementation before drafting include: account
fields collected at sign-up; chat and listing content; photos and selfies;
location and its visibility setting; device permissions actually requested
by the app; the AI providers configured for Zeno (what content is sent to
them and where); push notification tokens; payment and M-Pesa records; and
retention. Consent, where used, must be specific and separate from account
creation — the mandatory declarations here are not marketing consent, and no
marketing checkbox is added.
