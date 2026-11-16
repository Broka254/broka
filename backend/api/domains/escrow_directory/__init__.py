"""The directory of independent escrow providers BROKA points buyers at.

BROKA does not run, hold money for, or release money for any of them. This
package is information only: who each provider is, what it publishes about
its fees, limits and protection process, when BROKA last checked that, and
what BROKA will and will not say about it. ESCROW_PROVIDERS.md explains the
review process and the fee formulas.

Everything here except repository.py and router.py is plain Python with no
framework imports, so the rules (a link must be on the provider's own
domain; a fee is only calculated from a published formula; an unverified or
expired price is never used to rank anyone) can be tested without a database.
"""
