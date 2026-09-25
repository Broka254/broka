"""Auth Repository — all User DB queries live here."""
from __future__ import annotations

from datetime import datetime
from typing import Optional
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from api.core.text_search import matches_all_terms, search_terms
from api.database import User, PhoneOtp, EmailOtp, OtpPurpose


class UserRepository:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def get_by_id(self, user_id: str) -> Optional[User]:
        r = await self.db.execute(select(User).where(User.id == user_id))
        return r.scalar_one_or_none()

    async def get_by_email(self, email: str) -> Optional[User]:
        r = await self.db.execute(select(User).where(User.email == email.lower().strip()))
        return r.scalar_one_or_none()

    async def get_by_phone(self, phone: str) -> Optional[User]:
        r = await self.db.execute(select(User).where(User.phone == phone.strip()))
        return r.scalar_one_or_none()

    # ── Phone OTP ─────────────────────────────────────────────────────────────

    async def create_otp(
        self, phone: str, code_hash: str, expires_at: datetime,
        purpose: OtpPurpose = OtpPurpose.registration,
    ) -> PhoneOtp:
        otp = PhoneOtp(phone=phone.strip(), code_hash=code_hash,
                        purpose=purpose, expires_at=expires_at)
        self.db.add(otp)
        await self.db.commit()
        await self.db.refresh(otp)
        return otp

    async def get_latest_otp(self, phone: str, purpose: OtpPurpose) -> Optional[PhoneOtp]:
        r = await self.db.execute(
            select(PhoneOtp)
            .where(PhoneOtp.phone == phone.strip(), PhoneOtp.purpose == purpose,
                   PhoneOtp.consumed.is_(False))
            .order_by(PhoneOtp.created_at.desc())
            .limit(1)
        )
        return r.scalar_one_or_none()

    # ── Email OTP ────────────────────────────────────────────────────────
    # Separate methods rather than a generic one taking a table: the two
    # share a shape but not a key, and the callers always know which they
    # want. increment/consume below are shared, since they only touch
    # columns both rows have.

    async def create_email_otp(
        self, email: str, code_hash: str, expires_at,
        purpose: OtpPurpose = OtpPurpose.registration,
    ) -> EmailOtp:
        otp = EmailOtp(email=email.strip().lower(), code_hash=code_hash,
                       expires_at=expires_at, purpose=purpose)
        self.db.add(otp)
        await self.db.commit()
        await self.db.refresh(otp)
        return otp

    async def get_latest_email_otp(self, email: str, purpose: OtpPurpose):
        result = await self.db.execute(
            select(EmailOtp)
            .where(EmailOtp.email == email.strip().lower(),
                   EmailOtp.purpose == purpose,
                   EmailOtp.consumed.is_(False))
            .order_by(EmailOtp.created_at.desc())
            .limit(1)
        )
        return result.scalar_one_or_none()

    async def increment_otp_attempts(self, otp: PhoneOtp) -> None:
        otp.attempts += 1
        await self.db.commit()

    async def consume_otp(self, otp: PhoneOtp) -> None:
        otp.consumed = True
        await self.db.commit()

    async def search(
        self, q: str, limit: int = 20, exclude_id: Optional[str] = None,
    ) -> list[User]:
        """Users whose name, preferred name or business name has every word
        of [q]. Never matched on email: searching "@gmail" and reading back
        who matched was a way to learn which addresses have accounts."""
        terms = search_terms(q)
        if not terms:
            return []
        query = select(User).where(
            matches_all_terms(terms, (User.name, User.nickname, User.business_name))
        )
        if exclude_id:
            query = query.where(User.id != exclude_id)
        r = await self.db.execute(
            query.order_by(User.completed_deals.desc(), User.name).limit(limit)
        )
        return r.scalars().all()

    async def create(self, **kwargs) -> User:
        user = User(**kwargs)
        self.db.add(user)
        await self.db.commit()
        await self.db.refresh(user)
        return user

    async def update(self, user: User, **kwargs) -> User:
        for k, v in kwargs.items():
            setattr(user, k, v)
        await self.db.commit()
        await self.db.refresh(user)
        return user

    async def count(self) -> int:
        r = await self.db.execute(select(func.count(User.id)))
        return r.scalar() or 0
