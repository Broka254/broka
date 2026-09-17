"""OTP optional at signup

Revision ID: 0016
Revises: 0015
Create Date: 2026-08-07

Registration no longer requires a verified-phone token. A user can now
create an account with a bare phone number and skip the SMS step entirely
(from either Step 1 or Step 2 of the onboarding wizard), verifying later
from Profile if they choose to.

Adds `users.phone_verified` (default False) so the app/backend can still
tell verified accounts apart from ones that skipped - the `phone` column
itself is unaffected (still the required, unique login identifier either
way; only the *proof of ownership* becomes optional).
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0016"
down_revision: Union[str, None] = "0015"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table("users") as batch_op:
        try:
            batch_op.add_column(sa.Column("phone_verified", sa.Boolean(), nullable=False,
                                           server_default=sa.false()))
        except Exception:
            pass


def downgrade() -> None:
    with op.batch_alter_table("users") as batch_op:
        batch_op.drop_column("phone_verified")
