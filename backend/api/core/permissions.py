"""
BROKA - Fine-Grained Permission System
Moves beyond simple buyer/seller/admin roles to granular capability flags.
Permissions are checked via FastAPI dependencies.
"""

from __future__ import annotations

import enum
import logging
from fastapi import Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from api.database import get_db, User
from api.security import get_current_user

logger = logging.getLogger(__name__)


# ── Permission Flags ──────────────────────────────────────────────────────────

class Permission(str, enum.Enum):
    # Listings
    CREATE_LISTING        = "can_create_listing"
    EDIT_OWN_LISTING      = "can_edit_own_listing"
    DELETE_OWN_LISTING    = "can_delete_own_listing"
    BOOST_LISTING         = "can_boost_listing"

    # Deals & Escrow
    FINALIZE_DEAL         = "can_finalize_deal"
    CONFIRM_DELIVERY      = "can_confirm_delivery"
    RELEASE_ESCROW        = "can_release_escrow"

    # Disputes
    OPEN_DISPUTE          = "can_open_dispute"
    RESOLVE_DISPUTE       = "can_resolve_dispute"
    VIEW_DISPUTE          = "can_view_dispute"

    # Reviews
    SUBMIT_REVIEW         = "can_submit_review"

    # Verification
    PURCHASE_VERIFICATION = "can_purchase_verification"

    # Admin
    ADMIN_SUMMARY         = "can_admin_summary"
    MANAGE_USERS          = "can_manage_users"
    VERIFY_USER           = "can_verify_user"
    PROMOTE_ADMIN         = "can_promote_admin"
    VIEW_TRANSACTIONS     = "can_view_transactions"
    VIEW_ALL_DISPUTES     = "can_view_all_disputes"
    OVERRIDE_ESCROW       = "can_override_escrow"

    # AI
    USE_AI_BROKER         = "can_use_ai_broker"
    USE_AI_DISPUTE        = "can_use_ai_dispute"


# ── Role → Permission mapping ─────────────────────────────────────────────────

# Default permissions granted to every authenticated user
_USER_PERMISSIONS: set[Permission] = {
    Permission.CREATE_LISTING,
    Permission.EDIT_OWN_LISTING,
    Permission.DELETE_OWN_LISTING,
    Permission.BOOST_LISTING,
    Permission.FINALIZE_DEAL,
    Permission.CONFIRM_DELIVERY,
    Permission.OPEN_DISPUTE,
    Permission.VIEW_DISPUTE,
    Permission.SUBMIT_REVIEW,
    Permission.PURCHASE_VERIFICATION,
    Permission.USE_AI_BROKER,
    Permission.USE_AI_DISPUTE,
}

# Additional permissions granted to admins
_ADMIN_PERMISSIONS: set[Permission] = _USER_PERMISSIONS | {
    Permission.RELEASE_ESCROW,
    Permission.RESOLVE_DISPUTE,
    Permission.VIEW_ALL_DISPUTES,
    Permission.ADMIN_SUMMARY,
    Permission.MANAGE_USERS,
    Permission.VERIFY_USER,
    Permission.PROMOTE_ADMIN,
    Permission.VIEW_TRANSACTIONS,
    Permission.OVERRIDE_ESCROW,
}

# Permissions blocked for suspended/fraud-flagged users
_SUSPENDED_BLOCKED: set[Permission] = {
    Permission.CREATE_LISTING,
    Permission.FINALIZE_DEAL,
    Permission.BOOST_LISTING,
    Permission.PURCHASE_VERIFICATION,
}


def get_user_permissions(user: User) -> set[Permission]:
    """Return the effective permission set for a user."""
    if user.is_admin:
        perms = _ADMIN_PERMISSIONS.copy()
    else:
        perms = _USER_PERMISSIONS.copy()

    # Suspended users lose transactional permissions
    trust_score = getattr(user, "trust_score", 100)
    if trust_score is not None and trust_score < 20:
        perms -= _SUSPENDED_BLOCKED

    return perms


# ── FastAPI Dependencies ───────────────────────────────────────────────────────

async def _load_user(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> User:
    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found")
    return user


def require_permission(perm: Permission):
    """Dependency factory: raises 403 if user lacks the given permission."""
    async def _check(
        user: User = Depends(_load_user),
    ) -> User:
        effective = get_user_permissions(user)
        if perm not in effective:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Missing permission: {perm.value}",
            )
        return user
    _check.__name__ = f"require_{perm.value}"
    return _check


async def require_admin(
    user: User = Depends(_load_user),
) -> User:
    """Dependency: raises 403 if the caller is not an admin."""
    if not user.is_admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin access required",
        )
    return user
