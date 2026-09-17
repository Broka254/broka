"""Auth Repository — all User DB queries live here."""
from __future__ import annotations

from datetime import datetime
from typing import Optional
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from api.database import User, PhoneOtp, OtpPurpose


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

    async def increment_otp_attempts(self, otp: PhoneOtp) -> None:
        otp.attempts += 1
        await self.db.commit()

    async def consume_otp(self, otp: PhoneOtp) -> None:
        otp.consumed = True
        await self.db.commit()

    async def search(self, q: str, limit: int = 20) -> list[User]:
        pattern = f"%{q}%"
        r = await self.db.execute(
            select(User).where(
                (User.name.ilike(pattern)) | (User.email.ilike(pattern))
            ).limit(limit)
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
