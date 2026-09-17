"""Canonical Broka category taxonomy + idempotent seeding.

This is reference/application data (the fixed set of categories every
Broka deployment needs), not historical data migration - so unlike
migrate_categories_from_freetext.py it is safe to run automatically,
every startup, against any database (fresh or already-seeded), and is
called from api.database.init_db() for exactly that reason.

Every insert below is skip-if-exists, keyed on name (top-level) or
(parent, name) (subcategories/filters), so re-running is always safe:
- Existing rows are never duplicated.
- Existing rows are never modified or deleted.
- Existing category IDs/relationships are preserved.

migrate_categories_from_freetext.py imports CANONICAL_CATEGORIES /
SUBCATEGORIES / CATEGORY_FILTERS / SUBCATEGORY_FILTERS from here (single
source of truth) and calls seed_categories() itself before doing its own,
separate job: backfilling listings.subcategory_id from old free-text
listings.category values. That backfill is the only part of this system
that is historical-data-shaped and needs to stay a manual, explicit step.
"""
from __future__ import annotations

import json
import uuid

from sqlalchemy import select

from api.database import AsyncSessionLocal, Category, CategoryFilter

# Canonical top-level taxonomy (Design Journal Volume 6 / spec §2).
CANONICAL_CATEGORIES = [
    "Vehicles", "Property", "Electronics", "Gaming", "Home & Furniture",
    "Fashion", "Agriculture", "Construction", "Beauty & Personal Care",
    "Sports & Fitness", "Books & Education", "Music & Instruments",
    "Business & Industrial", "Pets & Animals", "Services", "Other",
]

# Subcategories per top-level category (spec §3). "Other" is deliberately
# left with zero subcategories - a real catch-all, not padded out just to
# have rows.
SUBCATEGORIES: dict[str, list[str]] = {
    "Vehicles": [
        "Cars", "Motorcycles", "Trucks", "Buses & Matatus", "Vans",
        "Trailers", "Agricultural Vehicles", "Parts & Accessories",
    ],
    "Property": [
        "Houses", "Apartments", "Land", "Commercial Property", "Offices",
        "Shops", "Farms", "Rentals",
    ],
    "Electronics": [
        "Phones", "Laptops & Computers", "Tablets", "TVs", "Audio",
        "Cameras", "Gaming", "Networking", "Accessories",
    ],
    "Gaming": ["Consoles", "PC Gaming", "Games", "Accessories", "Controllers"],
    "Home & Furniture": [
        "Living Room", "Bedroom", "Kitchen & Dining", "Office Furniture",
        "Outdoor & Garden", "Home Décor", "Appliances", "Storage & Organization",
    ],
    "Fashion": [
        "Men's Clothing", "Women's Clothing", "Kids' Clothing", "Shoes",
        "Bags & Accessories", "Jewelry & Watches", "Traditional Wear",
    ],
    "Agriculture": [
        "Livestock", "Poultry", "Crops & Produce", "Seeds", "Animal Feed",
        "Farm Equipment", "Farm Tools", "Agricultural Supplies",
    ],
    "Construction": [
        "Building Materials", "Heavy Machinery", "Hand & Power Tools",
        "Plumbing & Electrical", "Paint & Hardware", "Scaffolding & Safety Gear",
    ],
    "Beauty & Personal Care": [
        "Skincare", "Haircare", "Makeup", "Fragrances", "Personal Hygiene",
        "Salon & Spa Equipment",
    ],
    "Sports & Fitness": [
        "Fitness Equipment", "Team Sports", "Outdoor & Camping", "Cycling",
        "Swimming", "Sportswear",
    ],
    "Books & Education": [
        "Textbooks", "Fiction", "Non-Fiction", "Children's Books",
        "Stationery & Supplies", "Educational Materials",
    ],
    "Music & Instruments": [
        "Guitars", "Keyboards & Pianos", "Drums & Percussion",
        "Wind Instruments", "DJ & Studio Equipment", "Accessories",
    ],
    "Business & Industrial": [
        "Office Equipment", "Industrial Machinery", "Restaurant & Catering Equipment",
        "Retail & Shop Fixtures", "Safety & Security Equipment", "Packaging Supplies",
    ],
    "Pets & Animals": [
        "Dogs", "Cats", "Birds", "Fish & Aquarium", "Pet Supplies & Accessories",
        "Pet Food",
    ],
    "Services": [
        "Home Services", "Automotive Services", "Professional Services",
        "Events & Entertainment", "Repair & Maintenance", "Tutoring & Lessons",
    ],
    "Other": [],
}

# "More Filters" fields per top-level category (spec §7). field_type is
# "text" | "number_range" | "select"; options only used for "select".
# Condition is deliberately never a CategoryFilter - it's the universal
# listings.condition column, handled separately.
CATEGORY_FILTERS: dict[str, list[tuple[str, str, list[str] | None]]] = {
    "Vehicles": [
        ("make", "text", None),
        ("model", "text", None),
        ("year", "number_range", None),
        ("transmission", "select", ["Automatic", "Manual"]),
        ("fuel", "select", ["Petrol", "Diesel", "Hybrid", "Electric"]),
        ("mileage", "number_range", None),
    ],
    "Property": [
        ("property_type", "select", ["House", "Apartment", "Land", "Commercial", "Office", "Shop"]),
        ("bedrooms", "number_range", None),
        ("acreage", "number_range", None),
        ("title_deed", "select", ["Yes", "No"]),
        ("furnished", "select", ["Yes", "No", "Partly"]),
        ("parking", "select", ["Yes", "No"]),
    ],
    "Electronics": [
        ("brand", "text", None),
        ("ram", "select", ["2GB", "4GB", "8GB", "16GB", "32GB+"]),
        ("storage", "select", ["16GB", "32GB", "64GB", "128GB", "256GB+"]),
        ("screen_size", "number_range", None),
    ],
    "Gaming": [
        ("platform", "select", ["PlayStation", "Xbox", "Nintendo Switch", "PC"]),
        ("brand", "text", None),
    ],
    "Home & Furniture": [
        ("material", "select", ["Wood", "Metal", "Plastic", "Upholstered", "Glass"]),
        ("brand", "text", None),
    ],
    "Fashion": [
        ("size", "select", ["XS", "S", "M", "L", "XL", "XXL"]),
        ("brand", "text", None),
    ],
    "Agriculture": [
        ("brand", "text", None),
        ("fuel_type", "select", ["Diesel", "Petrol", "Electric", "Manual"]),
    ],
    "Construction": [
        ("material_type", "text", None),
    ],
    "Beauty & Personal Care": [
        ("brand", "text", None),
        ("skin_hair_type", "select", ["Oily", "Dry", "Combination", "Normal", "All Types"]),
    ],
    "Sports & Fitness": [
        ("brand", "text", None),
        ("size", "text", None),
    ],
    "Books & Education": [
        ("genre", "text", None),
        ("language", "select", ["English", "Swahili", "Other"]),
    ],
    "Music & Instruments": [
        ("brand", "text", None),
    ],
    "Business & Industrial": [
        ("brand", "text", None),
        ("equipment_type", "text", None),
    ],
    "Pets & Animals": [
        ("species", "select", ["Dog", "Cat", "Bird", "Fish", "Other"]),
        ("breed", "text", None),
    ],
    "Services": [
        ("service_type", "text", None),
    ],
    "Other": [],
}

# Dynamic seller-form attribute fields, keyed by (top-level name, exact
# subcategory name) - spec §4/§19: same CategoryFilter table/endpoint as
# CATEGORY_FILTERS above, just seeded against subcategory rows instead of
# top-level rows.
SUBCATEGORY_FILTERS: dict[tuple[str, str], list[tuple[str, str, list[str] | None]]] = {
    ("Vehicles", "Cars"): [
        ("make", "text", None), ("model", "text", None),
        ("year", "number_range", None), ("mileage", "number_range", None),
        ("fuel", "select", ["Petrol", "Diesel", "Hybrid", "Electric"]),
        ("transmission", "select", ["Automatic", "Manual"]),
        ("engine_size", "text", None),
    ],
    ("Vehicles", "Motorcycles"): [
        ("make", "text", None), ("model", "text", None),
        ("year", "number_range", None), ("mileage", "number_range", None),
        ("engine_size", "text", None),
    ],
    ("Vehicles", "Trucks"): [
        ("make", "text", None), ("model", "text", None),
        ("year", "number_range", None), ("mileage", "number_range", None),
        ("payload_capacity", "text", None),
    ],
    ("Vehicles", "Buses & Matatus"): [
        ("make", "text", None), ("model", "text", None),
        ("year", "number_range", None), ("seating_capacity", "number_range", None),
    ],
    ("Vehicles", "Vans"): [
        ("make", "text", None), ("model", "text", None),
        ("year", "number_range", None), ("mileage", "number_range", None),
    ],
    ("Vehicles", "Trailers"): [("make", "text", None), ("capacity", "text", None)],
    ("Vehicles", "Agricultural Vehicles"): [
        ("make", "text", None), ("model", "text", None), ("year", "number_range", None),
    ],
    ("Vehicles", "Parts & Accessories"): [
        ("brand", "text", None), ("compatible_make", "text", None),
    ],

    ("Property", "Houses"): [
        ("bedrooms", "number_range", None), ("bathrooms", "number_range", None),
        ("title_deed", "select", ["Yes", "No"]),
        ("furnished", "select", ["Yes", "No", "Partly"]),
        ("parking", "select", ["Yes", "No"]),
    ],
    ("Property", "Apartments"): [
        ("bedrooms", "number_range", None), ("bathrooms", "number_range", None),
        ("furnished", "select", ["Yes", "No", "Partly"]),
        ("parking", "select", ["Yes", "No"]),
    ],
    ("Property", "Land"): [
        ("acreage", "number_range", None),
        ("title_deed", "select", ["Yes", "No"]),
        ("road_access", "select", ["Yes", "No"]),
        ("water", "select", ["Yes", "No"]),
        ("electricity", "select", ["Yes", "No"]),
    ],
    ("Property", "Commercial Property"): [
        ("square_footage", "number_range", None), ("parking", "select", ["Yes", "No"]),
    ],
    ("Property", "Offices"): [
        ("square_footage", "number_range", None), ("parking", "select", ["Yes", "No"]),
    ],
    ("Property", "Shops"): [
        ("square_footage", "number_range", None),
        ("foot_traffic", "select", ["High", "Medium", "Low"]),
    ],
    ("Property", "Farms"): [
        ("acreage", "number_range", None),
        ("water_source", "select", ["Yes", "No"]),
        ("soil_type", "text", None),
    ],
    ("Property", "Rentals"): [
        ("bedrooms", "number_range", None), ("furnished", "select", ["Yes", "No", "Partly"]),
    ],

    ("Electronics", "Phones"): [
        ("brand", "text", None), ("model", "text", None),
        ("storage", "select", ["16GB", "32GB", "64GB", "128GB", "256GB+"]),
        ("ram", "select", ["2GB", "4GB", "6GB", "8GB", "12GB+"]),
        ("battery_health", "number_range", None),
        ("warranty", "select", ["Yes", "No"]),
    ],
    ("Electronics", "Laptops & Computers"): [
        ("brand", "text", None), ("model", "text", None),
        ("ram", "select", ["4GB", "8GB", "16GB", "32GB+"]),
        ("storage_type", "select", ["HDD", "SSD"]),
        ("storage_capacity", "text", None), ("processor", "text", None),
    ],
    ("Electronics", "Tablets"): [
        ("brand", "text", None), ("model", "text", None),
        ("storage", "select", ["16GB", "32GB", "64GB", "128GB", "256GB+"]),
    ],
    ("Electronics", "TVs"): [
        ("brand", "text", None), ("screen_size", "number_range", None),
        ("smart_tv", "select", ["Yes", "No"]),
    ],
    ("Electronics", "Audio"): [
        ("brand", "text", None),
        ("type", "select", ["Speaker", "Headphones", "Soundbar", "Home Theatre"]),
    ],
    ("Electronics", "Cameras"): [
        ("brand", "text", None),
        ("type", "select", ["DSLR", "Mirrorless", "Point & Shoot", "Action Camera"]),
    ],
    ("Electronics", "Gaming"): [
        ("brand", "text", None),
        ("platform", "select", ["PlayStation", "Xbox", "Nintendo Switch", "PC"]),
    ],
    ("Electronics", "Networking"): [
        ("brand", "text", None), ("type", "select", ["Router", "Modem", "Switch", "Extender"]),
    ],
    ("Electronics", "Accessories"): [
        ("brand", "text", None), ("compatible_with", "text", None),
    ],

    ("Gaming", "Consoles"): [
        ("brand", "text", None), ("model", "text", None),
        ("storage", "select", ["500GB", "1TB", "2TB+"]),
    ],
    ("Gaming", "PC Gaming"): [
        ("brand", "text", None), ("gpu", "text", None),
        ("ram", "select", ["8GB", "16GB", "32GB+"]),
    ],
    ("Gaming", "Games"): [
        ("platform", "select", ["PlayStation", "Xbox", "Nintendo Switch", "PC"]),
        ("title", "text", None),
    ],
    ("Gaming", "Accessories"): [
        ("brand", "text", None),
        ("compatible_platform", "select", ["PlayStation", "Xbox", "Nintendo Switch", "PC"]),
    ],
    ("Gaming", "Controllers"): [
        ("brand", "text", None),
        ("compatible_platform", "select", ["PlayStation", "Xbox", "Nintendo Switch", "PC"]),
    ],

    ("Home & Furniture", "Living Room"): [
        ("material", "select", ["Wood", "Metal", "Plastic", "Upholstered", "Glass"]),
        ("brand", "text", None),
    ],
    ("Home & Furniture", "Bedroom"): [
        ("material", "select", ["Wood", "Metal", "Plastic", "Upholstered"]),
        ("size", "select", ["Single", "Double", "Queen", "King"]),
    ],
    ("Home & Furniture", "Kitchen & Dining"): [
        ("material", "select", ["Wood", "Metal", "Plastic", "Glass"]),
        ("seating_capacity", "number_range", None),
    ],
    ("Home & Furniture", "Office Furniture"): [
        ("material", "select", ["Wood", "Metal", "Plastic"]), ("brand", "text", None),
    ],
    ("Home & Furniture", "Outdoor & Garden"): [
        ("material", "select", ["Wood", "Metal", "Plastic", "Rattan"]), ("brand", "text", None),
    ],
    ("Home & Furniture", "Home Décor"): [("material", "text", None), ("style", "text", None)],
    ("Home & Furniture", "Appliances"): [
        ("brand", "text", None), ("power_rating_watts", "number_range", None),
    ],
    ("Home & Furniture", "Storage & Organization"): [
        ("material", "select", ["Wood", "Metal", "Plastic"]), ("capacity", "text", None),
    ],

    ("Fashion", "Men's Clothing"): [
        ("size", "select", ["XS", "S", "M", "L", "XL", "XXL"]), ("brand", "text", None),
    ],
    ("Fashion", "Women's Clothing"): [
        ("size", "select", ["XS", "S", "M", "L", "XL", "XXL"]), ("brand", "text", None),
    ],
    ("Fashion", "Kids' Clothing"): [("size", "text", None), ("brand", "text", None)],
    ("Fashion", "Shoes"): [("size", "number_range", None), ("brand", "text", None)],
    ("Fashion", "Bags & Accessories"): [("brand", "text", None), ("material", "text", None)],
    ("Fashion", "Jewelry & Watches"): [
        ("material", "select", ["Gold", "Silver", "Stainless Steel", "Leather", "Other"]),
        ("brand", "text", None),
    ],
    ("Fashion", "Traditional Wear"): [("size", "text", None), ("fabric", "text", None)],

    ("Agriculture", "Livestock"): [
        ("species", "select", ["Cattle", "Goat", "Sheep", "Pig", "Other"]),
        ("age", "text", None), ("breed", "text", None),
    ],
    ("Agriculture", "Poultry"): [
        ("species", "select", ["Chicken", "Duck", "Turkey", "Other"]), ("age", "text", None),
    ],
    ("Agriculture", "Crops & Produce"): [("type", "text", None), ("quantity", "text", None)],
    ("Agriculture", "Seeds"): [("crop_type", "text", None), ("quantity", "text", None)],
    ("Agriculture", "Animal Feed"): [("type", "text", None), ("quantity", "text", None)],
    ("Agriculture", "Farm Equipment"): [
        ("brand", "text", None),
        ("fuel_type", "select", ["Diesel", "Petrol", "Electric", "Manual"]),
    ],
    ("Agriculture", "Farm Tools"): [("brand", "text", None)],
    ("Agriculture", "Agricultural Supplies"): [("type", "text", None)],

    ("Construction", "Building Materials"): [
        ("material_type", "text", None), ("quantity", "text", None),
    ],
    ("Construction", "Heavy Machinery"): [
        ("brand", "text", None), ("fuel_type", "select", ["Diesel", "Petrol", "Electric"]),
        ("hours_used", "number_range", None),
    ],
    ("Construction", "Hand & Power Tools"): [
        ("brand", "text", None), ("power_source", "select", ["Manual", "Electric", "Battery"]),
    ],
    ("Construction", "Plumbing & Electrical"): [
        ("material_type", "text", None), ("brand", "text", None),
    ],
    ("Construction", "Paint & Hardware"): [("brand", "text", None), ("type", "text", None)],
    ("Construction", "Scaffolding & Safety Gear"): [("material_type", "text", None)],

    ("Beauty & Personal Care", "Skincare"): [
        ("brand", "text", None),
        ("skin_type", "select", ["Oily", "Dry", "Combination", "Normal", "All Types"]),
    ],
    ("Beauty & Personal Care", "Haircare"): [
        ("brand", "text", None),
        ("hair_type", "select", ["Straight", "Curly", "Coily", "All Types"]),
    ],
    ("Beauty & Personal Care", "Makeup"): [("brand", "text", None), ("shade", "text", None)],
    ("Beauty & Personal Care", "Fragrances"): [
        ("brand", "text", None), ("size_ml", "number_range", None),
    ],
    ("Beauty & Personal Care", "Personal Hygiene"): [("brand", "text", None)],
    ("Beauty & Personal Care", "Salon & Spa Equipment"): [
        ("brand", "text", None), ("power_source", "select", ["Electric", "Manual"]),
    ],

    ("Sports & Fitness", "Fitness Equipment"): [("brand", "text", None), ("type", "text", None)],
    ("Sports & Fitness", "Team Sports"): [("sport", "text", None), ("brand", "text", None)],
    ("Sports & Fitness", "Outdoor & Camping"): [("brand", "text", None), ("type", "text", None)],
    ("Sports & Fitness", "Cycling"): [
        ("brand", "text", None), ("frame_size", "text", None),
        ("bike_type", "select", ["Mountain", "Road", "BMX", "Hybrid", "Electric"]),
    ],
    ("Sports & Fitness", "Swimming"): [("brand", "text", None), ("size", "text", None)],
    ("Sports & Fitness", "Sportswear"): [
        ("size", "select", ["XS", "S", "M", "L", "XL", "XXL"]), ("brand", "text", None),
    ],

    ("Books & Education", "Textbooks"): [
        ("subject", "text", None),
        ("level", "select", ["Primary", "Secondary", "College", "University"]),
    ],
    ("Books & Education", "Fiction"): [
        ("genre", "text", None), ("language", "select", ["English", "Swahili", "Other"]),
    ],
    ("Books & Education", "Non-Fiction"): [
        ("genre", "text", None), ("language", "select", ["English", "Swahili", "Other"]),
    ],
    ("Books & Education", "Children's Books"): [("age_group", "text", None)],
    ("Books & Education", "Stationery & Supplies"): [("brand", "text", None), ("type", "text", None)],
    ("Books & Education", "Educational Materials"): [("subject", "text", None), ("level", "text", None)],

    ("Music & Instruments", "Guitars"): [
        ("brand", "text", None), ("type", "select", ["Acoustic", "Electric", "Bass", "Classical"]),
    ],
    ("Music & Instruments", "Keyboards & Pianos"): [
        ("brand", "text", None), ("type", "select", ["Digital", "Acoustic", "Keyboard", "Synth"]),
    ],
    ("Music & Instruments", "Drums & Percussion"): [("brand", "text", None), ("type", "text", None)],
    ("Music & Instruments", "Wind Instruments"): [("brand", "text", None), ("type", "text", None)],
    ("Music & Instruments", "DJ & Studio Equipment"): [("brand", "text", None), ("type", "text", None)],
    ("Music & Instruments", "Accessories"): [("brand", "text", None), ("compatible_with", "text", None)],

    ("Business & Industrial", "Office Equipment"): [("brand", "text", None), ("type", "text", None)],
    ("Business & Industrial", "Industrial Machinery"): [
        ("brand", "text", None),
        ("power_source", "select", ["Electric", "Diesel", "Petrol", "Manual"]),
    ],
    ("Business & Industrial", "Restaurant & Catering Equipment"): [
        ("brand", "text", None), ("power_source", "select", ["Electric", "Gas", "Manual"]),
    ],
    ("Business & Industrial", "Retail & Shop Fixtures"): [
        ("material", "text", None), ("type", "text", None),
    ],
    ("Business & Industrial", "Safety & Security Equipment"): [
        ("brand", "text", None), ("type", "text", None),
    ],
    ("Business & Industrial", "Packaging Supplies"): [
        ("material", "text", None), ("size", "text", None),
    ],

    ("Pets & Animals", "Dogs"): [
        ("breed", "text", None), ("age", "text", None), ("vaccinated", "select", ["Yes", "No"]),
    ],
    ("Pets & Animals", "Cats"): [
        ("breed", "text", None), ("age", "text", None), ("vaccinated", "select", ["Yes", "No"]),
    ],
    ("Pets & Animals", "Birds"): [("species", "text", None), ("age", "text", None)],
    ("Pets & Animals", "Fish & Aquarium"): [("species", "text", None), ("tank_size", "text", None)],
    ("Pets & Animals", "Pet Supplies & Accessories"): [("brand", "text", None), ("type", "text", None)],
    ("Pets & Animals", "Pet Food"): [
        ("brand", "text", None),
        ("pet_type", "select", ["Dog", "Cat", "Bird", "Fish", "Other"]),
    ],

    ("Services", "Home Services"): [
        ("service_type", "text", None), ("experience_years", "number_range", None),
    ],
    ("Services", "Automotive Services"): [
        ("service_type", "text", None), ("experience_years", "number_range", None),
    ],
    ("Services", "Professional Services"): [
        ("service_type", "text", None), ("experience_years", "number_range", None),
    ],
    ("Services", "Events & Entertainment"): [("service_type", "text", None)],
    ("Services", "Repair & Maintenance"): [
        ("service_type", "text", None), ("experience_years", "number_range", None),
    ],
    ("Services", "Tutoring & Lessons"): [("subject", "text", None), ("level", "text", None)],
}


async def seed_categories() -> dict:
    """Idempotently ensure the canonical taxonomy + filter metadata exist.

    Safe to call on every app startup and against a database that already
    has categories: every insert is skip-if-exists (by name for top-level
    categories, by (parent, name) for subcategories, by (category, field)
    for filters). Never deletes, never overwrites an existing row, never
    touches Listing/User data. Returns counts of what was newly created
    (all zeros on a re-run against an already-seeded database).
    """
    counts = {
        "categories_created": 0,
        "subcategories_created": 0,
        "filters_created": 0,
        "subcategory_filters_created": 0,
    }

    async with AsyncSessionLocal() as db:
        # ── Pass 1: top-level categories ──────────────────────────────────
        # Scoped to parent_id IS NULL, and .first() rather than
        # .scalar_one_or_none(): "Gaming" is both a top-level category AND
        # an Electronics subcategory (SUBCATEGORIES below), and
        # Category.name has no unique constraint (see api/database.py) -
        # same MultipleResultsFound trap trader_specialization_subscribers.py
        # already had to be hardened against. An unscoped/strict lookup
        # here would work on a fresh DB but raise on every re-run once that
        # Electronics/Gaming subcategory row exists.
        for name in CANONICAL_CATEGORIES:
            existing = (await db.execute(
                select(Category).where(Category.name == name, Category.parent_id.is_(None))
            )).scalars().first()
            if not existing:
                db.add(Category(id=str(uuid.uuid4()), name=name, icon=None, parent_id=None))
                counts["categories_created"] += 1
        await db.commit()

        # by_name is built ONE SCOPED LOOKUP PER CANONICAL NAME (same query
        # as just above, re-run post-commit to get real row objects either
        # way) and reused as-is through Pass 2/3/4 below - deliberately NOT
        # a single bulk "SELECT all top-level, group by .name" query. A
        # database can contain a non-canonical top-level row that happens
        # to share a canonical name (this test suite's own fixtures do,
        # e.g. "Electronics"/"Home & Furniture" - see test_categories.py),
        # and a bulk name-keyed dict has no way to prefer the canonical row
        # over such a collision: whichever happened to come back last from
        # the unordered SELECT silently wins the dict slot. Every lookup
        # below stays scoped to "the specific row Pass 1 just verified for
        # THIS canonical name", so a same-named non-canonical row elsewhere
        # in the table can never get mistaken for it - Pass 2 was already
        # correctly scoped this way onto `parent.id`, it's only the lookup
        # that fed `parent` in the first place that needs the same care.
        by_name = {}
        for name in CANONICAL_CATEGORIES:
            by_name[name] = (await db.execute(
                select(Category).where(Category.name == name, Category.parent_id.is_(None))
            )).scalars().first()

        # ── Pass 2: subcategories ───────────────────────────────────────
        for parent_name, sub_names in SUBCATEGORIES.items():
            parent = by_name.get(parent_name)
            if not parent:
                continue
            existing_subs = (await db.execute(
                select(Category.name).where(Category.parent_id == parent.id)
            )).scalars().all()
            for sub_name in sub_names:
                if sub_name in existing_subs:
                    continue
                db.add(Category(id=str(uuid.uuid4()), name=sub_name, icon=None, parent_id=parent.id))
                counts["subcategories_created"] += 1
        await db.commit()

        # ── Pass 3: top-level "More Filters" fields ─────────────────────
        for cat_name, fields in CATEGORY_FILTERS.items():
            cat = by_name.get(cat_name)
            if not cat:
                continue
            existing_fields = (await db.execute(
                select(CategoryFilter.field_name).where(CategoryFilter.category_id == cat.id)
            )).scalars().all()
            for field_name, field_type, options in fields:
                if field_name in existing_fields:
                    continue
                db.add(CategoryFilter(
                    id=str(uuid.uuid4()), category_id=cat.id,
                    field_name=field_name, field_type=field_type,
                    options=json.dumps(options) if options else None,
                ))
                counts["filters_created"] += 1
        await db.commit()

        # ── Pass 4: subcategory-level (seller form) attribute fields ────
        # Subcategory lookups stay a bulk (parent_id, name) -keyed query -
        # unlike the top-level case, a collision here would need the exact
        # same (parent_id, name) pair twice, and parent_id is now always
        # one of THIS pass's correctly-resolved canonical ids (by_name,
        # above) or another category's own true id - never ambiguous the
        # way a bare .name was.
        all_cats = (await db.execute(select(Category))).scalars().all()
        by_parent_and_name = {(c.parent_id, c.name): c for c in all_cats}

        for (top_name, sub_name), fields in SUBCATEGORY_FILTERS.items():
            top_cat = by_name.get(top_name)
            if not top_cat:
                continue
            sub_cat = by_parent_and_name.get((top_cat.id, sub_name))
            if not sub_cat:
                continue
            existing_fields = (await db.execute(
                select(CategoryFilter.field_name).where(CategoryFilter.category_id == sub_cat.id)
            )).scalars().all()
            for field_name, field_type, options in fields:
                if field_name in existing_fields:
                    continue
                db.add(CategoryFilter(
                    id=str(uuid.uuid4()), category_id=sub_cat.id,
                    field_name=field_name, field_type=field_type,
                    options=json.dumps(options) if options else None,
                ))
                counts["subcategory_filters_created"] += 1
        await db.commit()

    return counts
