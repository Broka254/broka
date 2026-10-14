# ==========================================================================
# DEAD CODE - NOT MOUNTED, NOT IMPORTED.
#
# Verified 2026-09-14 by reading main.py directly rather than trusting
# comments: this module's name does not appear in main.py's
# `from api.routers import (...)` tuple, and no `app.include_router(...)`
# call references it. Nothing in the backend imports it either. None of
# its routes are reachable at runtime.
#
# Canonical replacement: api/domains/auth/router.py      (mounted at /auth)
#
# QUARANTINED, NOT DELETED (spec section 21). Deleting it is a separate,
# reversible commit that should be made once someone has confirmed no
# out-of-tree consumer (a script, a notebook, an ops runbook) imports it.
# Leaving it importable but clearly marked costs nothing; deleting it
# blind is the failure mode that section warns about.
#
# Do not add routes here. Do not mount this module.
# ==========================================================================
"""
⚠️  NOT MOUNTED — LEGACY / DEAD CODE (verified during Store hardening
pass, 2026-09: never imported in main.py). Canonical implementation is
api/domains/auth/router.py. Left in place rather than deleted; do not
edit this file expecting it to affect the running app. ⚠️

BROKA - Auth Router: register, login, user search, profile & photo upload.
"""

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, or_
import math

from api.database import get_db, User
from api.schemas import RegisterRequest, LoginRequest, UpdateProfileRequest
from api.security import hash_password, verify_password, create_access_token, get_current_user
from datetime import datetime as _dt

router = APIRouter()


def _haversine_km(lat1, lng1, lat2, lng2):
    R = 6371
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlng/2)**2
    return R * 2 * math.asin(math.sqrt(a))


@router.post("/register", status_code=status.HTTP_201_CREATED)
async def register(payload: RegisterRequest, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.email == payload.email))
    if result.scalar_one_or_none():
        raise HTTPException(status_code=400, detail="Email already registered")

    user = User(
        name=payload.name,
        nickname=payload.nickname,
        email=payload.email,
        phone=payload.phone,
        password_hash=hash_password(payload.password),
        lat=payload.lat,
        lng=payload.lng,
        profile_photo=payload.profile_photo,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)

    token = create_access_token({"sub": user.id})
    return {
        "access_token": token,
        "token_type": "bearer",
        "user_id": user.id,
        "name": user.name,
        "nickname": user.nickname,
        "email": user.email,
        "profile_photo": user.profile_photo,
    }


@router.post("/login")
async def login(payload: LoginRequest, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.email == payload.email))
    user = result.scalar_one_or_none()

    if not user or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    token = create_access_token({"sub": user.id})
    return {
        "access_token": token,
        "token_type": "bearer",
        "user_id": user.id,
        "name": user.name,
        "nickname": user.nickname,
        "email": user.email,
        "lat": user.lat,
        "lng": user.lng,
        "profile_photo": user.profile_photo,
    }


@router.get("/me")
async def get_me(current_user=Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    from api.database import Listing, Deal, ListingStatus
    from sqlalchemy import func

    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    listing_count_result = await db.execute(
        select(func.count(Listing.id)).where(
            Listing.seller_id == user.id,
            Listing.status == ListingStatus.active,
        )
    )
    listing_count = listing_count_result.scalar() or 0

    volume_result = await db.execute(
        select(func.sum(Deal.agreed_price)).where(Deal.seller_id == user.id)
    )
    volume = volume_result.scalar() or 0.0

    return {
        "id": user.id,
        "name": user.name,
        "nickname": user.nickname,
        "email": user.email,
        "phone": user.phone,
        "lat": user.lat,
        "lng": user.lng,
        "rating": user.rating,
        "completed_deals": user.completed_deals,
        "listing_count": listing_count,
        "volume_traded": volume,
        "is_verified": user.is_verified,
        "profile_photo": user.profile_photo,
        "created_at": user.created_at.isoformat(),
    }


@router.patch("/profile")
async def update_profile(
    payload: UpdateProfileRequest,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Update nickname and/or profile selfie."""
    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if payload.nickname is not None:
        user.nickname = payload.nickname
    if payload.profile_photo is not None:
        user.profile_photo = payload.profile_photo
    await db.commit()
    return {"status": "ok", "nickname": user.nickname}


@router.get("/search")
async def search_users(
    q: str = Query(min_length=1, max_length=80),
    lat: float = Query(default=None),
    lng: float = Query(default=None),
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(User).where(
            User.id != current_user["id"],
            or_(
                User.name.ilike(f"%{q}%"),
                User.email.ilike(f"%{q}%"),
                User.nickname.ilike(f"%{q}%"),
            )
        ).limit(20)
    )
    users = result.scalars().all()

    def _dist(u):
        if lat and lng and u.lat and u.lng:
            return round(_haversine_km(lat, lng, u.lat, u.lng), 1)
        return None

    return [
        {
            "id": u.id,
            "name": u.name,
            "nickname": u.nickname,
            "rating": u.rating,
            "completed_deals": u.completed_deals,
            "is_verified": u.is_verified,
            # Only expose location if the user opted in
            "distance_km": _dist(u) if getattr(u, "location_visible", True) else None,
            "location_name": _approx_location(u.lat, u.lng) if getattr(u, "location_visible", True) else None,
            "profile_photo": u.profile_photo,
            "member_since": u.created_at.strftime("%b %Y") if u.created_at else None,
        }
        for u in users
    ]


@router.get("/user/{user_id}")
async def get_user_profile(
    user_id: str,
    lat: float = Query(default=None),
    lng: float = Query(default=None),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    distance_km = None
    if lat and lng and user.lat and user.lng:
        distance_km = round(_haversine_km(lat, lng, user.lat, user.lng), 1)

    loc_visible = getattr(user, "location_visible", True)

    # Online status: last_seen within 5 minutes = online
    is_online = False
    last_seen_str = "Recently active"
    if user.last_seen:
        delta = _dt.utcnow() - user.last_seen
        secs = int(delta.total_seconds())
        is_online = secs < 300
        if is_online:
            last_seen_str = "Active now"
        elif secs < 3600:  last_seen_str = f"Last seen {secs//60}m ago"
        elif secs < 86400: last_seen_str = f"Last seen {secs//3600}h ago"
        else:              last_seen_str = f"Last seen {secs//86400}d ago"

    return {
        "id": user.id,
        "name": user.name,
        "nickname": user.nickname,
        "rating": user.rating,
        "completed_deals": user.completed_deals,
        "is_verified": user.is_verified,
        "location_name": _approx_location(user.lat, user.lng) if loc_visible else None,
        "distance_km": distance_km if loc_visible else None,
        "location_visible": loc_visible,
        "profile_photo": user.profile_photo,
        "biometric_enrolled": getattr(user, "biometric_enrolled", None),
        "member_since": user.created_at.strftime("%b %Y") if user.created_at else None,
        "is_online": is_online,
        "last_seen": last_seen_str,
        "preferred_language": getattr(user, "preferred_language", None) or "english",
    }


@router.patch("/location")
async def update_location(
    lat: float = Query(...),
    lng: float = Query(...),
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.lat = lat
    user.lng = lng
    await db.commit()
    return {"status": "ok", "lat": lat, "lng": lng}


def _approx_location(lat, lng):
    """
    Map (lat, lng) to the nearest Kenyan / East African town name.
    Covers 60+ cities & towns so rural users see a meaningful location.
    Coordinates are checked most-specific (cities) first, then sub-counties,
    then counties, then country fallback.
    """
    if not lat or not lng:
        return "Kenya"

    # Nairobi metro
    if -1.40 < lat < -1.10 and 36.65 < lng < 37.10: return "Nairobi, Kenya"

    # Coast
    if -4.20 < lat < -3.85 and 39.50 < lng < 40.00: return "Mombasa, Kenya"
    if -4.50 < lat < -4.10 and 39.40 < lng < 39.80: return "Kwale, Kenya"
    if -3.50 < lat < -3.10 and 39.80 < lng < 40.30: return "Kilifi, Kenya"
    if -2.80 < lat < -2.30 and 40.00 < lng < 40.50: return "Malindi, Kenya"
    if -1.80 < lat < -1.40 and 40.00 < lng < 40.50: return "Lamu, Kenya"

    # Western Kenya
    if -0.25 < lat <  0.25 and 34.50 < lng < 35.05: return "Kisumu, Kenya"
    if  0.05 < lat <  0.35 and 34.15 < lng < 34.55: return "Siaya, Kenya"
    if  0.00 < lat <  0.20 and 34.20 < lng < 34.45: return "Ugunja, Siaya"
    if -0.10 < lat <  0.15 and 33.90 < lng < 34.20: return "Bondo, Siaya"
    if -0.10 < lat <  0.20 and 34.55 < lng < 34.90: return "Ahero, Kisumu"
    if  0.25 < lat <  0.65 and 34.00 < lng < 34.40: return "Busia, Kenya"
    if  0.30 < lat <  0.70 and 34.40 < lng < 34.90: return "Kakamega, Kenya"
    if  0.10 < lat <  0.50 and 34.80 < lng < 35.15: return "Vihiga, Kenya"
    if  0.50 < lat <  0.90 and 34.60 < lng < 35.00: return "Mumias, Kakamega"
    if  0.55 < lat <  0.95 and 35.00 < lng < 35.45: return "Butere, Kakamega"
    if  0.40 < lat <  0.80 and 35.15 < lng < 35.55: return "Hamisi, Vihiga"

    # Rift Valley / North Rift
    if  0.40 < lat <  0.80 and 35.15 < lng < 35.65: return "Eldoret, Kenya"
    if  0.80 < lat <  1.20 and 35.00 < lng < 35.50: return "Kitale, Kenya"
    if  0.20 < lat <  0.55 and 35.65 < lng < 36.10: return "Nakuru, Kenya"
    if  0.10 < lat <  0.45 and 35.95 < lng < 36.35: return "Gilgil, Nakuru"
    if -0.20 < lat <  0.20 and 36.00 < lng < 36.40: return "Naivasha, Kenya"
    if  1.50 < lat <  2.00 and 36.90 < lng < 37.40: return "Isiolo, Kenya"
    if  0.90 < lat <  1.40 and 36.80 < lng < 37.30: return "Meru, Kenya"
    if  1.20 < lat <  1.60 and 37.50 < lng < 38.00: return "Maua, Meru"
    if  2.00 < lat <  2.50 and 36.80 < lng < 37.30: return "Marsabit, Kenya"
    if  3.00 < lat <  3.60 and 41.50 < lng < 42.00: return "Mandera, Kenya"
    if  1.70 < lat <  2.20 and 40.70 < lng < 41.20: return "Garissa, Kenya"
    if -0.40 < lat < -0.05 and 37.30 < lng < 37.70: return "Embu, Kenya"
    if -0.80 < lat < -0.35 and 37.00 < lng < 37.40: return "Thika, Kiambu"
    if -1.05 < lat < -0.75 and 36.85 < lng < 37.15: return "Ruiru, Kiambu"
    if -0.70 < lat < -0.35 and 36.60 < lng < 37.00: return "Limuru, Kiambu"
    if -0.40 < lat < -0.10 and 36.60 < lng < 37.00: return "Kiambu, Kenya"

    # South / Kajiado / Machakos
    if -1.90 < lat < -1.45 and 36.60 < lng < 37.10: return "Kajiado, Kenya"
    if -2.50 < lat < -1.90 and 37.10 < lng < 37.60: return "Machakos, Kenya"
    if -2.50 < lat < -2.00 and 37.60 < lng < 38.10: return "Kitui, Kenya"

    # Nyanza / South Nyanza / Kisii
    if -0.80 < lat < -0.40 and 34.55 < lng < 35.00: return "Kisii, Kenya"
    if -0.80 < lat < -0.45 and 34.10 < lng < 34.60: return "Homa Bay, Kenya"
    if -0.50 < lat < -0.10 and 34.20 < lng < 34.65: return "Migori, Kenya"
    if -1.00 < lat < -0.65 and 34.30 < lng < 34.70: return "Nyamira, Kenya"

    # Central Kenya
    if -0.55 < lat < -0.20 and 36.95 < lng < 37.35: return "Murang'a, Kenya"
    if -0.60 < lat < -0.25 and 37.35 < lng < 37.75: return "Kirinyaga, Kenya"
    if -0.45 < lat < -0.10 and 37.00 < lng < 37.40: return "Nyeri, Kenya"
    if -1.00 < lat < -0.55 and 37.00 < lng < 37.50: return "Nyandarua, Kenya"

    # Uganda border towns
    if  0.30 < lat <  0.55 and 30.60 < lng < 31.00: return "Kampala, Uganda"
    if  0.05 < lat <  0.40 and 33.85 < lng < 34.25: return "Tororo, Uganda"

    # Tanzania border
    if -1.40 < lat < -1.00 and 34.10 < lng < 34.50: return "Musoma, Tanzania"

    return "Kenya"


@router.patch("/language")
async def update_language(
    language: str = Query(...),
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    supported = ["english", "swahili", "luo", "kikuyu", "luganda", "sheng"]
    if language.lower() not in supported:
        raise HTTPException(status_code=400,
            detail=f"Unsupported language. Choose from: {', '.join(supported)}")
    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.preferred_language = language.lower()
    await db.commit()
    return {"status": "ok", "language": language.lower()}


@router.patch("/location-visibility")
async def toggle_location_visibility(
    visible: bool = Query(...),
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Toggle whether the user's location appears on their public profile."""
    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.location_visible = visible
    await db.commit()
    return {"status": "ok", "location_visible": visible}


@router.patch("/biometric-enroll")
async def enroll_biometric(
    biometric_type: str = Query(...),  # 'fingerprint' | 'face' | 'none'
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Record that the user has enrolled a specific biometric type for BROKA."""
    allowed = ["fingerprint", "face", "none"]
    if biometric_type not in allowed:
        raise HTTPException(status_code=400,
            detail=f"biometric_type must be one of: {', '.join(allowed)}")
    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.biometric_enrolled = biometric_type if biometric_type != "none" else None
    await db.commit()
    return {"status": "ok", "biometric_enrolled": user.biometric_enrolled}

@router.post("/heartbeat")
async def heartbeat(
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Called every ~60s by the app to update last_seen timestamp."""
    result = await db.execute(select(User).where(User.id == current_user["id"]))
    user   = result.scalar_one_or_none()
    if user:
        user.last_seen = _dt.utcnow()
        await db.commit()
    return {"ok": True}

