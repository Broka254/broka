"""User model — re-exported from api.database (the single source of truth).

This file used to redefine the User class wholesale (an incomplete v4.0
refactor that was never finished - the original stayed in database.py too,
meaning Python tried to register the same "users" table on the same
SQLAlchemy MetaData twice, crashing with:
  sqlalchemy.exc.InvalidRequestError: Table 'users' is already defined...

Fix: re-export the real class instead of redefining it. Every existing
`from api.models.user import User` import keeps working unchanged.
"""
from api.database import User  # noqa: F401

