from pydantic import BaseModel, EmailStr, Field
from typing import Optional


class RegisterRequest(BaseModel):
    name: str = Field(min_length=2, max_length=80)
    nickname: Optional[str] = Field(default=None, max_length=40)
    email: EmailStr
    phone: Optional[str] = Field(default=None, max_length=20)
    password: str = Field(min_length=6, max_length=128)
    lat: Optional[float] = None
    lng: Optional[float] = None
    profile_photo: Optional[str] = None   # base64 selfie


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class UpdateProfileRequest(BaseModel):
    nickname: Optional[str] = Field(default=None, max_length=40)
    profile_photo: Optional[str] = None   # base64 selfie


class ListingCreate(BaseModel):
    name: str = Field(min_length=3, max_length=120)
    description: Optional[str] = Field(default=None, max_length=2000)
    category: str = Field(min_length=2, max_length=60)
    price: float = Field(gt=0)
    lat: float
    lng: float
    location_name: Optional[str] = Field(default=None, max_length=100)
    listing_type: str = Field(default="direct", pattern="^(direct|auction)$")
    target_bidders: Optional[int] = Field(default=None, ge=2, le=500)
    reserve_price: Optional[float] = Field(default=None, gt=0)
    verified_photos: Optional[str] = None
    verified_video: Optional[str] = None
    advert_video: Optional[str] = None


class InterestCreate(BaseModel):
    offer_price: Optional[float] = Field(default=None, gt=0)
