"""Deal and MpesaTransaction models — re-exported from api.database.

This file used to redefine these classes wholesale, frozen at an earlier
snapshot that predates the dispute-resolution work (timer_type,
dispute_branch, seller_has_explained, expected_delivery_date, and the
DealStatus sub-states like awaiting_resolution/awaiting_replacement all
only exist in api.database's version). Redefining the same "deals" /
"mpesa_transactions" tables on the same SQLAlchemy MetaData also crashed
with InvalidRequestError. Re-export instead, so every existing import path
keeps working and there's a single, current source of truth.
"""
from api.database import Deal, MpesaTransaction, DealStatus, MpesaStatus  # noqa: F401

