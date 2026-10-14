"""Add call_type to negotiation_messages

Revision ID: 0009
Revises: 0008
Create Date: 2026-07-11

Supports video calling: records whether a logged call ("call" msg_type row)
was "audio" or "video" so both call history cards and call-back can respect
the original call's type. Nullable/backfilled so existing call rows (all
audio-only, pre-video-calling) just read as NULL -> treated as "audio" by
the application layer.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0009"
down_revision: Union[str, None] = "0008"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table("negotiation_messages") as batch_op:
        batch_op.add_column(sa.Column("call_type", sa.String(), nullable=True))
    # Backfill existing call-log rows as "audio" - every call placed before
    # this migration was audio-only (video calling didn't exist yet).
    op.execute(
        "UPDATE negotiation_messages SET call_type = 'audio' "
        "WHERE msg_type = 'call' AND call_type IS NULL"
    )


def downgrade() -> None:
    with op.batch_alter_table("negotiation_messages") as batch_op:
        batch_op.drop_column("call_type")
