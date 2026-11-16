"""Reporting a suspected scam, and what BROKA may do about it.

Built on the existing complaint queue (domains/feedback): a scam report IS a
complaint, so it is triaged, alerted, answered and counted by the tooling
that already exists, and `repeat_reported_users` already sees it. What this
package adds is what a scam report needs and a general complaint does not:
the structured facts (the account or website reported, the transaction
reference, why, how much), private evidence, repeated-report detection that
asks a human to look, and - only a human's decision - a temporary protective
restriction the person can appeal.

THE RULE EVERYTHING HERE FOLLOWS: A REPORT IS NOT A VERDICT. Nothing a
report says, and no number of reports, restricts, flags, bans or lowers the
trust score of anyone. Reports raise an alert for a person to review. A
restriction is applied by an administrator, with a reason, for a limited
time, and can be appealed (policy.py).
"""
