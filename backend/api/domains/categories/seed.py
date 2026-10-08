"""Canonical Broka category taxonomy + idempotent seeding.

This is reference/application data (the fixed set of categories every
Broka deployment needs), not historical data migration - so unlike
migrate_categories_from_freetext.py it is safe to run automatically,
every startup, against any database (fresh or already-seeded), and is
called from api.database.init_db() for exactly that reason.

Every insert below is skip-if-exists, keyed on name (top-level) or
(parent, name) (subcategories/filters), so re-running is always safe:
- Existing rows are never duplicated.
- Existing rows are never modified or deleted, except where a table below
  says so (RENAMED_*, MOVED_SUBCATEGORIES, RETIRED_SUBCATEGORY_FILTERS, and
  the brand suggestions in BRAND_SUGGESTIONS).
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

from sqlalchemy import delete, func, select, update

from api.database import AsyncSessionLocal, Category, CategoryFilter

# Canonical top-level taxonomy (Design Journal Volume 6 / spec §2), in the
# order sellers and buyers see it: GET /categories returns this order (see
# service.py), so the Home rail and the sell wizard's category list lead
# with what Kenyans sell most and end on the catch-all "Other".
#
# 2026-09-25 listing overhaul: "Vehicles" is now "Automobiles" (renamed in
# place - see RENAMED_CATEGORIES), and Land, Food & Beverages, Health &
# Medical, Baby & Kids and Arts & Crafts are new. Land used to be a
# Property subcategory; a plot is what a large share of Kenyan sellers
# list, and it needs its own required details (its size), so it is a
# category of its own now (see MOVED_SUBCATEGORIES).
CANONICAL_CATEGORIES = [
    "Automobiles", "Property", "Land", "Electronics", "Fashion", "Agriculture",
    "Home & Furniture", "Food & Beverages", "Construction",
    "Beauty & Personal Care", "Health & Medical", "Baby & Kids", "Gaming",
    "Sports & Fitness", "Books & Education", "Music & Instruments",
    "Arts & Crafts", "Business & Industrial", "Pets & Animals", "Services",
    "Other",
]

# Top-level categories renamed in place: the row keeps its id, so every
# listing, subcategory, filter and store that points at it keeps pointing
# at it. The seed is otherwise skip-if-exists by name, so without this a
# new name would create a second, empty category next to the old one.
RENAMED_CATEGORIES: dict[str, str] = {
    "Vehicles": "Automobiles",
}

# Subcategories renamed in place, keyed by (parent's current name, old
# name). Same reason as above.
RENAMED_SUBCATEGORIES: dict[tuple[str, str], str] = {
    ("Automobiles", "Motorcycles"): "Motorcycles & Boda Bodas",
}

# Subcategories that moved to another top-level category, keyed by (old
# parent, old name) -> (new parent, new name). The row is re-parented, not
# copied, so listings filed under it move with it.
MOVED_SUBCATEGORIES: dict[tuple[str, str], tuple[str, str]] = {
    ("Property", "Land"): ("Land", "Residential Plots"),
}

# Seller-form fields a subcategory no longer asks for. Metadata only: the
# values listings already carry in their attributes are untouched. Land's
# size is its own required field now (land_size + land_size_unit, checked
# in listings/validation.py), so the old free "acreage" box would ask for
# it twice.
RETIRED_SUBCATEGORY_FILTERS: dict[tuple[str, str], tuple[str, ...]] = {
    ("Land", "Residential Plots"): ("acreage",),
}

# Subcategories per top-level category (spec §3), in display order - the
# most common first (service.py returns them in this order). "Other" is
# deliberately left with zero subcategories - a real catch-all, not padded
# out just to have rows.
MTUMBA = "Mtumba (Second-hand Clothes)"

SUBCATEGORIES: dict[str, list[str]] = {
    "Automobiles": [
        "Cars", "Motorcycles & Boda Bodas", "Pickups", "Buses & Matatus",
        "Trucks", "Vans", "Tuk-Tuks & Three-Wheelers", "Agricultural Vehicles",
        "Trailers", "Boats & Watercraft", "Parts & Accessories", "Tyres & Rims",
    ],
    "Property": [
        "Houses", "Apartments", "Rentals", "Short Stays & Airbnb",
        "Commercial Property", "Offices", "Shops", "Warehouses & Godowns",
        "Farms",
    ],
    "Land": [
        "Residential Plots", "Agricultural Land", "Commercial Land",
        "Industrial Land", "Beach & Waterfront Land", "Ranches & Large Tracts",
        "Land for Lease",
    ],
    "Electronics": [
        "Phones", "Laptops & Computers", "Tablets", "TVs", "Audio",
        "Smartwatches & Wearables", "Cameras", "Solar & Power Backup",
        "Printers & Scanners", "Computer Components", "Networking", "Gaming",
        "Accessories",
    ],
    "Fashion": [
        MTUMBA, "Men's Clothing", "Women's Clothing", "Kids' Clothing", "Shoes",
        "Bags & Accessories", "Jewelry & Watches", "Traditional Wear",
        "Wedding Wear", "Uniforms & Workwear", "Fabrics & Textiles",
    ],
    "Agriculture": [
        "Cereals & Grains", "Fruits & Vegetables", "Crops & Produce",
        "Livestock", "Poultry", "Dairy & Eggs", "Seeds", "Seedlings & Nursery",
        "Animal Feed", "Fertilizers & Agrochemicals", "Farm Equipment",
        "Farm Tools", "Irrigation & Water Tanks", "Beekeeping & Honey",
        "Agricultural Supplies",
    ],
    "Home & Furniture": [
        "Living Room", "Bedroom", "Beds & Mattresses", "Kitchen & Dining",
        "Kitchenware & Cookware", "Appliances", "Home Décor",
        "Bedding & Curtains", "Lighting", "Office Furniture", "Outdoor & Garden",
        "Storage & Organization",
    ],
    "Food & Beverages": [
        "Packaged Foods & Groceries", "Beverages", "Bakery & Snacks",
        "Meat & Fish", "Spices, Oils & Condiments", "Ready Meals & Catering",
    ],
    "Construction": [
        "Building Materials", "Roofing Materials", "Steel & Metal Works",
        "Doors, Windows & Gates", "Tiles & Flooring", "Plumbing & Electrical",
        "Paint & Hardware", "Hand & Power Tools", "Heavy Machinery",
        "Scaffolding & Safety Gear",
    ],
    "Beauty & Personal Care": [
        "Skincare", "Haircare", "Wigs & Hair Extensions", "Makeup", "Fragrances",
        "Nails", "Men's Grooming", "Personal Hygiene", "Salon & Spa Equipment",
    ],
    "Health & Medical": [
        "Medical Equipment", "Health Monitors", "Mobility Aids",
        "First Aid & Supplies", "Vitamins & Supplements",
    ],
    "Baby & Kids": [
        "Toys & Games", "Strollers & Car Seats", "Cots & Baby Furniture",
        "Feeding & Nursing", "Diapers & Baby Care", "Maternity",
    ],
    "Gaming": ["Consoles", "Games", "Controllers", "PC Gaming", "Accessories"],
    "Sports & Fitness": [
        "Fitness Equipment", "Team Sports", "Cycling", "Sportswear",
        "Racket Sports", "Outdoor & Camping", "Swimming",
    ],
    "Books & Education": [
        "Textbooks", "Revision Books & Past Papers", "Fiction", "Non-Fiction",
        "Children's Books", "Religious Books", "Stationery & Supplies",
        "Educational Materials",
    ],
    "Music & Instruments": [
        "Guitars", "Keyboards & Pianos", "Drums & Percussion",
        "Wind Instruments", "Traditional Instruments", "DJ & Studio Equipment",
        "PA & Sound Systems", "Accessories",
    ],
    "Arts & Crafts": [
        "Paintings & Wall Art", "Carvings & Sculptures", "Beadwork",
        "Baskets & Weaving", "Antiques & Collectibles", "Art & Craft Supplies",
    ],
    "Business & Industrial": [
        "Wholesale & Bulk Stock", "Office Equipment", "Industrial Machinery",
        "Restaurant & Catering Equipment", "Retail & Shop Fixtures",
        "Printing & Branding Equipment", "Welding & Workshop Equipment",
        "Safety & Security Equipment", "Packaging Supplies",
    ],
    "Pets & Animals": [
        "Dogs", "Cats", "Birds", "Fish & Aquarium", "Rabbits & Small Pets",
        "Pet Food", "Pet Supplies & Accessories",
    ],
    "Services": [
        "Home Services", "Cleaning Services", "Repair & Maintenance",
        "Construction & Renovation", "Transport & Moving", "Automotive Services",
        "Beauty & Wellness", "IT & Tech Services", "Photography & Videography",
        "Events & Entertainment", "Tutoring & Lessons", "Professional Services",
    ],
    "Other": [],
}

# How mtumba is graded and sold in Kenyan markets (Gikomba, Toi, Kongowea):
# "Grade 1" - the best of a bale, what traders call "camera" - down to
# mixed, and bought as a single piece, a bundle or a whole bale.
MTUMBA_GRADES = ["Grade 1 (Camera)", "Grade 2", "Grade 3", "Mixed"]
BABY_AGE_GROUPS = ["0-6 months", "6-12 months", "1-3 years", "3-5 years", "5+ years"]

# A Land listing must say how big the land is (listings/validation.py
# refuses one that doesn't), in one of these units - "50x100 plots" being
# how most Kenyan plots are sold. First in every Land subcategory's form:
# the sell wizard gives them their own control, and app builds from before
# it render them as ordinary fields, so either can post land.
LAND_SIZE_UNIT_OPTIONS = ["Acres", "Hectares", "50x100 plots", "Square metres", "Square feet"]
LAND_SIZE_FIELDS: list[tuple[str, str, list[str] | None]] = [
    ("land_size", "number_range", None),
    ("land_size_unit", "select", LAND_SIZE_UNIT_OPTIONS),
]

# "More Filters" fields per top-level category (spec §7). field_type is
# "text" | "number_range" | "select"; options only used for "select".
# Condition is deliberately never a CategoryFilter - it's the universal
# listings.condition column, handled separately.
CATEGORY_FILTERS: dict[str, list[tuple[str, str, list[str] | None]]] = {
    "Automobiles": [
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
    # land_size_acres is not something a seller types: the listing service
    # derives it from land_size + land_size_unit (validation.py), so plots
    # measured in acres, hectares or 50x100s can all be filtered on one scale.
    "Land": [
        ("land_size_acres", "number_range", None),
        ("title_deed", "select", ["Yes", "No"]),
        ("tenure", "select", ["Freehold", "Leasehold"]),
        ("road_access", "select", ["Yes", "No"]),
        ("water", "select", ["Yes", "No"]),
        ("electricity", "select", ["Yes", "No"]),
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
        ("grade", "select", MTUMBA_GRADES),
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
    "Food & Beverages": [
        ("brand", "text", None),
        ("packaging", "select", ["Single", "Pack", "Carton", "Bulk"]),
    ],
    "Health & Medical": [
        ("brand", "text", None),
    ],
    "Baby & Kids": [
        ("age_group", "select", BABY_AGE_GROUPS),
        ("brand", "text", None),
    ],
    "Arts & Crafts": [
        ("material", "text", None),
        ("handmade", "select", ["Yes", "No"]),
    ],
    "Other": [],
}

# Dynamic seller-form attribute fields, keyed by (top-level name, exact
# subcategory name) - spec §4/§19: same CategoryFilter table/endpoint as
# CATEGORY_FILTERS above, just seeded against subcategory rows instead of
# top-level rows.
SUBCATEGORY_FILTERS: dict[tuple[str, str], list[tuple[str, str, list[str] | None]]] = {
    ("Automobiles", "Cars"): [
        ("make", "text", None), ("model", "text", None),
        ("year", "number_range", None), ("mileage", "number_range", None),
        ("fuel", "select", ["Petrol", "Diesel", "Hybrid", "Electric"]),
        ("transmission", "select", ["Automatic", "Manual"]),
        ("engine_size", "text", None),
    ],
    ("Automobiles", "Motorcycles & Boda Bodas"): [
        ("make", "text", None), ("model", "text", None),
        ("year", "number_range", None), ("mileage", "number_range", None),
        ("engine_size", "text", None),
    ],
    ("Automobiles", "Trucks"): [
        ("make", "text", None), ("model", "text", None),
        ("year", "number_range", None), ("mileage", "number_range", None),
        ("payload_capacity", "text", None),
    ],
    ("Automobiles", "Buses & Matatus"): [
        ("make", "text", None), ("model", "text", None),
        ("year", "number_range", None), ("seating_capacity", "number_range", None),
    ],
    ("Automobiles", "Vans"): [
        ("make", "text", None), ("model", "text", None),
        ("year", "number_range", None), ("mileage", "number_range", None),
    ],
    ("Automobiles", "Trailers"): [("make", "text", None), ("capacity", "text", None)],
    ("Automobiles", "Agricultural Vehicles"): [
        ("make", "text", None), ("model", "text", None), ("year", "number_range", None),
    ],
    ("Automobiles", "Parts & Accessories"): [
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

    # ── 2026-09-25 listing overhaul: new categories and subcategories ────
    ("Automobiles", "Pickups"): [
        ("make", "text", None), ("model", "text", None),
        ("year", "number_range", None), ("mileage", "number_range", None),
        ("drive", "select", ["2WD", "4WD"]),
        ("fuel", "select", ["Petrol", "Diesel", "Hybrid", "Electric"]),
    ],
    ("Automobiles", "Tuk-Tuks & Three-Wheelers"): [
        ("make", "text", None), ("year", "number_range", None),
        ("use", "select", ["Passenger", "Cargo"]),
    ],
    ("Automobiles", "Boats & Watercraft"): [
        ("type", "select", ["Fishing Boat", "Speed Boat", "Canoe", "Jet Ski", "Other"]),
        ("length_ft", "number_range", None),
    ],
    ("Automobiles", "Tyres & Rims"): [
        ("brand", "text", None), ("tyre_size", "text", None),
        ("type", "select", ["Tyres", "Rims", "Tyres & Rims"]),
    ],

    ("Property", "Short Stays & Airbnb"): [
        ("bedrooms", "number_range", None), ("guests", "number_range", None),
        ("wifi", "select", ["Yes", "No"]), ("parking", "select", ["Yes", "No"]),
    ],
    ("Property", "Warehouses & Godowns"): [
        ("square_footage", "number_range", None),
        ("loading_bay", "select", ["Yes", "No"]),
    ],

    # LAND_SIZE_FIELDS lead every Land form: the size is required (see
    # listings/validation.py clean_land_details).
    ("Land", "Residential Plots"): [
        *LAND_SIZE_FIELDS,
        ("title_deed", "select", ["Yes", "No"]),
        ("tenure", "select", ["Freehold", "Leasehold"]),
        ("road_access", "select", ["Yes", "No"]),
        ("water", "select", ["Yes", "No"]),
        ("electricity", "select", ["Yes", "No"]),
        ("fenced", "select", ["Yes", "No"]),
    ],
    ("Land", "Agricultural Land"): [
        *LAND_SIZE_FIELDS,
        ("title_deed", "select", ["Yes", "No"]),
        ("water", "select", ["Yes", "No"]),
        ("soil_type", "select", ["Red Soil", "Black Cotton", "Loam", "Sandy", "Volcanic", "Other"]),
        ("road_access", "select", ["Yes", "No"]),
    ],
    ("Land", "Commercial Land"): [
        *LAND_SIZE_FIELDS,
        ("title_deed", "select", ["Yes", "No"]),
        ("tenure", "select", ["Freehold", "Leasehold"]),
        ("road_frontage", "select", ["Tarmac", "Murram", "None"]),
        ("electricity", "select", ["Yes", "No"]),
    ],
    ("Land", "Industrial Land"): [
        *LAND_SIZE_FIELDS,
        ("title_deed", "select", ["Yes", "No"]),
        ("tenure", "select", ["Freehold", "Leasehold"]),
        ("electricity", "select", ["Yes", "No"]),
        ("road_access", "select", ["Yes", "No"]),
    ],
    ("Land", "Beach & Waterfront Land"): [
        *LAND_SIZE_FIELDS,
        ("title_deed", "select", ["Yes", "No"]),
        ("water_frontage", "select", ["Ocean", "Lake", "River"]),
        ("road_access", "select", ["Yes", "No"]),
    ],
    ("Land", "Ranches & Large Tracts"): [
        *LAND_SIZE_FIELDS,
        ("title_deed", "select", ["Yes", "No"]),
        ("water", "select", ["Yes", "No"]),
        ("fenced", "select", ["Yes", "No"]),
    ],
    ("Land", "Land for Lease"): [
        *LAND_SIZE_FIELDS,
        ("lease_period", "select", ["Per season", "1 year", "2-5 years", "5+ years"]),
        ("water", "select", ["Yes", "No"]),
        ("road_access", "select", ["Yes", "No"]),
    ],

    ("Electronics", "Smartwatches & Wearables"): [
        ("brand", "text", None),
        ("compatible_with", "select", ["Android", "iPhone", "Both"]),
    ],
    ("Electronics", "Solar & Power Backup"): [
        ("type", "select", ["Solar Panel", "Battery", "Inverter", "Solar Kit", "Generator", "UPS"]),
        ("capacity", "text", None), ("brand", "text", None),
    ],
    ("Electronics", "Printers & Scanners"): [
        ("brand", "text", None),
        ("type", "select", ["Inkjet", "Laser", "Scanner", "All-in-one"]),
    ],
    ("Electronics", "Computer Components"): [
        ("type", "select", ["Hard Drive / SSD", "RAM", "Graphics Card", "Monitor", "Keyboard & Mouse", "Other"]),
        ("brand", "text", None),
    ],

    ("Fashion", MTUMBA): [
        ("sold_as", "select", ["Single piece", "Bundle", "Bale"]),
        ("grade", "select", MTUMBA_GRADES),
        ("clothing_type", "select", [
            "T-shirts & Tops", "Shirts", "Jeans & Trousers", "Dresses & Skirts",
            "Jackets & Coats", "Sweaters & Hoodies", "Kids' Wear", "Sportswear",
            "Shoes", "Bags", "Bedding & Duvets", "Curtains", "Mixed",
        ]),
        ("for", "select", ["Men", "Women", "Kids", "Unisex"]),
        ("size", "select", ["XS", "S", "M", "L", "XL", "XXL", "Mixed"]),
        ("bale_weight_kg", "number_range", None),
    ],
    ("Fashion", "Wedding Wear"): [
        ("size", "select", ["XS", "S", "M", "L", "XL", "XXL"]),
        ("for", "select", ["Bride", "Groom", "Bridal Party"]),
    ],
    ("Fashion", "Uniforms & Workwear"): [
        ("type", "select", ["School Uniform", "Corporate", "Medical", "Security", "Overalls"]),
        ("size", "text", None),
    ],
    ("Fashion", "Fabrics & Textiles"): [
        ("fabric", "select", ["Kitenge", "Kikoi", "Maasai Shuka", "Cotton", "Silk", "Other"]),
    ],

    ("Agriculture", "Cereals & Grains"): [
        ("crop", "select", ["Maize", "Beans", "Rice", "Wheat", "Sorghum", "Millet", "Green Grams", "Other"]),
        ("bag_size_kg", "select", ["50kg", "70kg", "90kg", "Other"]),
        ("moisture_dried", "select", ["Yes", "No"]),
    ],
    ("Agriculture", "Fruits & Vegetables"): [
        ("produce", "text", None), ("organic", "select", ["Yes", "No"]),
    ],
    ("Agriculture", "Dairy & Eggs"): [
        ("product", "select", ["Milk", "Eggs", "Ghee", "Cheese", "Yoghurt"]),
    ],
    ("Agriculture", "Seedlings & Nursery"): [("plant", "text", None)],
    ("Agriculture", "Fertilizers & Agrochemicals"): [
        ("type", "select", ["Fertilizer", "Pesticide", "Herbicide", "Fungicide", "Manure"]),
        ("brand", "text", None),
    ],
    ("Agriculture", "Irrigation & Water Tanks"): [
        ("type", "select", ["Water Tank", "Drip Kit", "Pump", "Sprinkler", "Pipes"]),
        ("capacity", "text", None),
    ],
    ("Agriculture", "Beekeeping & Honey"): [
        ("product", "select", ["Honey", "Beehive", "Beeswax", "Equipment"]),
    ],

    ("Home & Furniture", "Beds & Mattresses"): [
        ("size", "select", ["3x6", "4x6", "5x6", "6x6"]), ("brand", "text", None),
    ],
    ("Home & Furniture", "Kitchenware & Cookware"): [("material", "text", None), ("brand", "text", None)],
    ("Home & Furniture", "Bedding & Curtains"): [("type", "text", None), ("size", "text", None)],
    ("Home & Furniture", "Lighting"): [("type", "text", None)],

    ("Food & Beverages", "Packaged Foods & Groceries"): [("brand", "text", None)],
    ("Food & Beverages", "Beverages"): [
        ("type", "select", ["Soft Drinks", "Juice", "Water", "Tea & Coffee", "Other"]),
        ("brand", "text", None),
    ],
    ("Food & Beverages", "Meat & Fish"): [
        ("type", "select", ["Beef", "Goat", "Chicken", "Pork", "Fish", "Other"]),
    ],

    ("Construction", "Roofing Materials"): [
        ("material", "select", ["Iron Sheets", "Tiles", "Stone Coated", "Other"]),
        ("gauge", "text", None),
    ],
    ("Construction", "Steel & Metal Works"): [("type", "text", None)],
    ("Construction", "Doors, Windows & Gates"): [
        ("material", "select", ["Steel", "Wood", "Aluminium", "Glass"]),
    ],
    ("Construction", "Tiles & Flooring"): [("type", "text", None), ("size", "text", None)],

    ("Beauty & Personal Care", "Wigs & Hair Extensions"): [
        ("type", "select", ["Human Hair", "Synthetic", "Braids", "Weave"]),
        ("length", "text", None),
    ],
    ("Beauty & Personal Care", "Men's Grooming"): [("brand", "text", None)],

    ("Health & Medical", "Medical Equipment"): [("brand", "text", None), ("type", "text", None)],
    ("Health & Medical", "Health Monitors"): [
        ("type", "select", ["Blood Pressure", "Glucose", "Oximeter", "Thermometer", "Other"]),
        ("brand", "text", None),
    ],
    ("Health & Medical", "Mobility Aids"): [
        ("type", "select", ["Wheelchair", "Walker", "Crutches", "Other"]),
    ],

    ("Baby & Kids", "Toys & Games"): [("age_group", "select", BABY_AGE_GROUPS)],
    ("Baby & Kids", "Strollers & Car Seats"): [("brand", "text", None)],
    ("Baby & Kids", "Cots & Baby Furniture"): [("material", "text", None)],

    ("Arts & Crafts", "Paintings & Wall Art"): [("medium", "text", None), ("size", "text", None)],
    ("Arts & Crafts", "Carvings & Sculptures"): [
        ("material", "select", ["Wood", "Soapstone", "Metal", "Other"]),
    ],
    ("Arts & Crafts", "Beadwork"): [("type", "text", None)],

    ("Business & Industrial", "Wholesale & Bulk Stock"): [("product_type", "text", None)],
    ("Business & Industrial", "Printing & Branding Equipment"): [("brand", "text", None), ("type", "text", None)],

    ("Services", "Cleaning Services"): [("service_type", "text", None)],
    ("Services", "Transport & Moving"): [
        ("vehicle", "select", ["Pickup", "Lorry", "Van", "Motorbike"]),
    ],
    ("Services", "IT & Tech Services"): [("service_type", "text", None)],
    ("Services", "Photography & Videography"): [("service_type", "text", None)],
}

# The brands a subcategory's buyers filter by (its vehicles' makes, for
# Automobiles), the ones Kenyan sellers list most first. Each subcategory
# screen in the app leads with them as one-tap filters ("Phones": Samsung,
# Apple, Tecno...), and the sell form offers them as one tap too.
#
# They are the `options` of the subcategory's existing free-text "brand" or
# "make" field (SUGGESTION_FIELDS), not a "select": a seller with a brand
# that isn't here can still type it, and app builds from before this ignore
# options on a text field and keep showing the text box they always did.
# A free box alone is why brand filtering never worked: "samsung galaxy
# a54", "Samsung phone" and "SAMSUNG" are three brands to a filter. The
# listing service now files a typed brand under its spelling here
# (listings/validation.py canonical_suggestion), with BRAND_ALIASES for the
# names people use instead ("iPhone" is Apple).
#
# Unlike the rest of this file these are kept in line on every start
# (seed_categories Pass 4b): adding a brand here reaches a database that
# was seeded before it.
SUGGESTION_FIELDS = ("make", "brand")

_CAR_MAKES = [
    "Toyota", "Nissan", "Subaru", "Mazda", "Honda", "Suzuki", "Mitsubishi", "Isuzu",
    "Mercedes-Benz", "BMW", "Volkswagen", "Hyundai", "Kia", "Ford", "Land Rover",
    "Lexus", "Peugeot", "Volvo", "Audi", "Jeep",
]
_STYLE_BRANDS = ["Nike", "Adidas", "Puma", "H&M", "Zara", "Levi's", "Tommy Hilfiger", "Louis Vuitton"]
_POWER_TOOL_BRANDS = ["Bosch", "Makita", "DeWalt", "Stanley", "Black+Decker", "Total", "Ingco"]

BRAND_SUGGESTIONS: dict[tuple[str, str], list[str]] = {
    ("Automobiles", "Cars"): _CAR_MAKES,
    ("Automobiles", "Motorcycles & Boda Bodas"): [
        "Bajaj", "TVS", "Honda", "Yamaha", "Suzuki", "Haojue", "Kibo",
    ],
    ("Automobiles", "Pickups"): ["Toyota", "Isuzu", "Ford", "Nissan", "Mitsubishi", "Mazda", "Volkswagen"],
    ("Automobiles", "Buses & Matatus"): [
        "Isuzu", "Toyota", "Nissan", "Mercedes-Benz", "Scania", "Volvo", "Hino", "Ashok Leyland",
    ],
    ("Automobiles", "Trucks"): [
        "Isuzu", "Hino", "Mitsubishi Fuso", "Mercedes-Benz", "Volvo", "Scania", "MAN",
        "UD Trucks", "Tata", "Sinotruk",
    ],
    ("Automobiles", "Vans"): [
        "Toyota", "Nissan", "Mercedes-Benz", "Volkswagen", "Ford", "Hyundai", "Kia", "Renault",
    ],
    ("Automobiles", "Tuk-Tuks & Three-Wheelers"): ["Bajaj", "TVS", "Piaggio", "Dayun"],
    ("Automobiles", "Agricultural Vehicles"): [
        "Massey Ferguson", "New Holland", "John Deere", "Kubota", "Mahindra", "Case IH", "Deutz-Fahr",
    ],
    ("Automobiles", "Tyres & Rims"): [
        "Bridgestone", "Michelin", "Dunlop", "Yokohama", "Goodyear", "Continental",
        "Pirelli", "Hankook", "Firestone", "Toyo",
    ],

    ("Electronics", "Phones"): [
        "Samsung", "Apple", "Tecno", "Infinix", "Itel", "Oppo", "Xiaomi", "Vivo", "Realme",
        "Nokia", "Huawei", "Honor", "OnePlus", "Google", "Sony", "Motorola", "Nothing",
        "ZTE", "HMD",
    ],
    ("Electronics", "Laptops & Computers"): [
        "HP", "Lenovo", "Dell", "Apple", "Asus", "Acer", "Microsoft", "Huawei", "MSI",
        "Samsung", "Toshiba", "Razer",
    ],
    ("Electronics", "Tablets"): [
        "Apple", "Samsung", "Lenovo", "Huawei", "Xiaomi", "Microsoft", "Amazon", "Nokia",
        "Tecno", "Infinix",
    ],
    ("Electronics", "TVs"): [
        "Samsung", "LG", "Hisense", "TCL", "Sony", "Skyworth", "Vitron", "Vision Plus",
        "Bruhm", "Haier", "Philips",
    ],
    ("Electronics", "Audio"): [
        "JBL", "Sony", "Samsung", "LG", "Bose", "Harman Kardon", "Oraimo", "Anker",
        "Marshall", "Philips",
    ],
    ("Electronics", "Smartwatches & Wearables"): [
        "Apple", "Samsung", "Xiaomi", "Huawei", "Garmin", "Fitbit", "Amazfit", "Haylou", "Oraimo",
    ],
    ("Electronics", "Cameras"): [
        "Canon", "Nikon", "Sony", "Fujifilm", "Panasonic", "GoPro", "DJI", "Insta360",
    ],
    ("Electronics", "Solar & Power Backup"): [
        "Deye", "Victron", "Felicity Solar", "Must", "Growatt", "Sako", "SolarMax",
    ],
    ("Electronics", "Printers & Scanners"): [
        "HP", "Canon", "Epson", "Brother", "Ricoh", "Kyocera", "Xerox", "Pantum",
    ],
    ("Electronics", "Computer Components"): [
        "Intel", "AMD", "NVIDIA", "Asus", "Gigabyte", "MSI", "Corsair", "Kingston",
        "Crucial", "Samsung", "Western Digital", "Seagate",
    ],
    ("Electronics", "Networking"): [
        "TP-Link", "Tenda", "Huawei", "ZTE", "D-Link", "MikroTik", "Cisco", "Ubiquiti",
    ],
    ("Electronics", "Gaming"): [
        "Sony", "Microsoft", "Nintendo", "Valve", "Meta", "Razer", "Logitech", "Thrustmaster",
    ],
    ("Electronics", "Accessories"): [
        "Apple", "Samsung", "Anker", "Oraimo", "Baseus", "UGREEN", "Xiaomi", "JBL",
        "Logitech", "Belkin",
    ],

    ("Gaming", "Consoles"): ["Sony", "Microsoft", "Nintendo", "Valve"],
    ("Gaming", "Controllers"): ["Sony", "Microsoft", "Nintendo", "Logitech", "Razer", "Thrustmaster"],
    ("Gaming", "PC Gaming"): ["Asus", "MSI", "Lenovo", "HP", "Dell", "Acer", "Razer", "Logitech"],
    ("Gaming", "Accessories"): ["Sony", "Microsoft", "Nintendo", "Razer", "Logitech", "Thrustmaster"],

    ("Home & Furniture", "Living Room"): ["Ashley", "IKEA", "Midas", "Rochester", "Kifaru"],
    ("Home & Furniture", "Beds & Mattresses"): [
        "Slumberland", "Dr. Mattress", "Silentnight", "Midas", "Sealy",
    ],
    ("Home & Furniture", "Appliances"): [
        "Ramtons", "Von Hotpoint", "Bruhm", "LG", "Samsung", "Hisense", "Hotpoint", "Bosch",
        "Philips", "Kenwood", "Mika",
    ],
    ("Home & Furniture", "Office Furniture"): ["IKEA", "Rochester", "Duraco", "Kifaru"],
    ("Home & Furniture", "Outdoor & Garden"): ["IKEA", "Keter", "Midas"],

    ("Fashion", "Men's Clothing"): _STYLE_BRANDS,
    ("Fashion", "Women's Clothing"): _STYLE_BRANDS,
    ("Fashion", "Kids' Clothing"): ["Nike", "Adidas", "Puma", "H&M", "Carter's", "Mothercare"],
    ("Fashion", "Shoes"): [
        "Nike", "Adidas", "Puma", "New Balance", "Skechers", "Timberland", "Clarks", "Bata",
    ],
    ("Fashion", "Bags & Accessories"): ["Michael Kors", "Coach", "Nike", "Adidas", "Puma", "Louis Vuitton"],

    ("Agriculture", "Farm Equipment"): [
        "John Deere", "Massey Ferguson", "New Holland", "Kubota", "Mahindra", "Honda", "Stihl",
    ],
    ("Agriculture", "Farm Tools"): _POWER_TOOL_BRANDS,
    ("Agriculture", "Fertilizers & Agrochemicals"): [
        "Yara", "MEA Fertilizers", "Amiran", "Osho Chemical", "Syngenta", "Bayer",
    ],

    ("Beauty & Personal Care", "Skincare"): [
        "Nivea", "Neutrogena", "CeraVe", "Vaseline", "Garnier", "The Ordinary", "Dove",
    ],
    ("Beauty & Personal Care", "Haircare"): [
        "Dove", "L'Oreal", "Pantene", "Tresemme", "Cantu", "Dark & Lovely", "Motions",
    ],
    ("Beauty & Personal Care", "Makeup"): [
        "Maybelline", "L'Oreal", "MAC", "Revlon", "NYX", "Fenty Beauty", "Huda Beauty",
    ],
    ("Beauty & Personal Care", "Fragrances"): [
        "Hugo Boss", "Calvin Klein", "Davidoff", "Lattafa", "Armaf", "Jovan", "Chanel",
    ],
    ("Beauty & Personal Care", "Men's Grooming"): [
        "Gillette", "Nivea Men", "Dove Men+Care", "Old Spice", "Beard Gang", "Philips",
    ],

    ("Construction", "Hand & Power Tools"): _POWER_TOOL_BRANDS,
    ("Construction", "Heavy Machinery"): ["Caterpillar", "JCB", "Komatsu", "Volvo", "Hitachi"],
    ("Construction", "Plumbing & Electrical"): [
        "Schneider Electric", "ABB", "Legrand", "MK", "Davis & Shirtliff",
    ],
    ("Construction", "Paint & Hardware"): ["Crown Paints", "Bralo", "Basco", "Sadolin", "Dulux", "Plascon"],

    ("Sports & Fitness", "Fitness Equipment"): ["Adidas", "Nike", "Reebok", "Decathlon", "York", "Everlast"],
    ("Sports & Fitness", "Cycling"): ["Giant", "Trek", "Scott", "Specialized", "Cannondale", "Bianchi"],
    ("Sports & Fitness", "Sportswear"): ["Nike", "Adidas", "Puma", "Under Armour", "Reebok", "New Balance"],
    ("Sports & Fitness", "Outdoor & Camping"): [
        "Coleman", "Quechua", "The North Face", "Decathlon", "Kilimanjaro",
    ],

    ("Music & Instruments", "Guitars"): ["Yamaha", "Fender", "Gibson", "Ibanez", "Epiphone", "Cort"],
    ("Music & Instruments", "Keyboards & Pianos"): ["Yamaha", "Casio", "Roland", "Korg", "Kawai"],
    ("Music & Instruments", "Drums & Percussion"): ["Yamaha", "Pearl", "Tama", "Ludwig", "Mapex"],
    ("Music & Instruments", "DJ & Studio Equipment"): [
        "Pioneer DJ", "Behringer", "Numark", "Focusrite", "M-Audio", "Shure",
    ],
    ("Music & Instruments", "Accessories"): ["Yamaha", "Fender", "Gibson", "Roland", "Shure", "Behringer"],

    ("Pets & Animals", "Pet Food"): ["Royal Canin", "Purina", "Pedigree", "Whiskas", "Hills", "Drools"],
    ("Pets & Animals", "Pet Supplies & Accessories"): ["Royal Canin", "Kong", "Trixie", "Whiskas", "Pedigree"],

    ("Books & Education", "Stationery & Supplies"): [
        "Pilot", "Bic", "Staedtler", "Faber-Castell", "Kasuku", "Paper Mate",
    ],
}

# What people call a brand instead of its name, lower-case: a phone is an
# "iPhone", not an Apple. Only ever applied where the brand it names is one
# of the field's own suggestions, so "mi" means Xiaomi among phone brands
# and nothing at all anywhere Xiaomi isn't one.
BRAND_ALIASES: dict[str, str] = {
    "iphone": "Apple", "ipad": "Apple", "macbook": "Apple", "imac": "Apple",
    "airpods": "Apple", "apple watch": "Apple",
    "galaxy": "Samsung",
    "redmi": "Xiaomi", "poco": "Xiaomi", "mi": "Xiaomi",
    "pixel": "Google", "surface": "Microsoft",
    "playstation": "Sony", "ps4": "Sony", "ps5": "Sony", "xbox": "Microsoft",
    "mercedes": "Mercedes-Benz", "benz": "Mercedes-Benz", "vw": "Volkswagen",
    "range rover": "Land Rover", "fuso": "Mitsubishi Fuso", "ud": "UD Trucks",
    "massey": "Massey Ferguson", "cat": "Caterpillar",
}


def suggestion_field(top_name: str, sub_name: str) -> str | None:
    """The field [BRAND_SUGGESTIONS] fill for a subcategory: its form's
    "make" if it has one (a vehicle), else its "brand"."""
    names = {name for name, _kind, _opts in SUBCATEGORY_FILTERS.get((top_name, sub_name), [])}
    return next((f for f in SUGGESTION_FIELDS if f in names), None)


def _field_options(top_name: str, sub_name: str, field_name: str, options):
    """A subcategory field's options as seeded: its brand suggestions, when
    it is the field they fill."""
    brands = BRAND_SUGGESTIONS.get((top_name, sub_name))
    if brands and field_name == suggestion_field(top_name, sub_name):
        return brands
    return options


async def seed_categories() -> dict:
    """Idempotently ensure the canonical taxonomy + filter metadata exist.

    Safe to call on every app startup and against a database that already
    has categories: every insert is skip-if-exists (by name for top-level
    categories, by (parent, name) for subcategories, by (category, field)
    for filters). Never deletes a category, never touches User data.
    Returns counts of what was newly created or changed (all zeros on a
    re-run against an already-seeded database).

    The only rows it changes are the ones the tables above say changed: a
    renamed or moved category keeps its id (so everything pointing at it
    follows), and the free-text category name stored on listings, stores
    and buy-agent requests is brought in line with it - on every start, so
    a start that died between the two steps is finished by the next one.
    A brand/make field's suggestions follow BRAND_SUGGESTIONS the same way
    (Pass 4b).
    """
    counts = {
        "categories_created": 0,
        "subcategories_created": 0,
        "filters_created": 0,
        "subcategory_filters_created": 0,
        "categories_renamed": 0,
        "subcategories_moved": 0,
        "filters_retired": 0,
        "suggestions_updated": 0,
    }

    async with AsyncSessionLocal() as db:
        # ── Pass 0: renames, before anything is looked up by name ─────────
        # A rename done after Pass 1 would be too late: Pass 1 would already
        # have created an empty "Automobiles" next to the real "Vehicles".
        # Skipped when the new name already exists (a database seeded fresh
        # with the new taxonomy, or a rename done on an earlier start).
        for old_name, new_name in RENAMED_CATEGORIES.items():
            old_row = await _top_level(db, old_name)
            if old_row is not None and await _top_level(db, new_name) is None:
                old_row.name = new_name
                counts["categories_renamed"] += 1
        await db.flush()
        for (parent_name, old_name), new_name in RENAMED_SUBCATEGORIES.items():
            parent = await _top_level(db, parent_name)
            if parent is None:
                continue
            old_row = await _child(db, parent.id, old_name)
            if old_row is not None and await _child(db, parent.id, new_name) is None:
                old_row.name = new_name
                counts["categories_renamed"] += 1
        await db.commit()

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
            existing = await _top_level(db, name)
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
            by_name[name] = await _top_level(db, name)

        # ── Pass 1b: subcategories that moved to another category ─────────
        # Re-parented in place (after Pass 1, which created the new parent).
        # Skipped when the destination already has a row of that name, so a
        # fresh database - which never had the old row - is untouched.
        for (old_parent, old_name), (new_parent, new_name) in MOVED_SUBCATEGORIES.items():
            source, target = by_name.get(old_parent), by_name.get(new_parent)
            if source is None or target is None:
                continue
            row = await _child(db, source.id, old_name)
            if row is not None and await _child(db, target.id, new_name) is None:
                row.parent_id = target.id
                row.name = new_name
                counts["subcategories_moved"] += 1
        await db.commit()

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
                options = _field_options(top_name, sub_name, field_name, options)
                db.add(CategoryFilter(
                    id=str(uuid.uuid4()), category_id=sub_cat.id,
                    field_name=field_name, field_type=field_type,
                    options=json.dumps(options) if options else None,
                ))
                counts["subcategory_filters_created"] += 1

        for (top_name, sub_name), retired in RETIRED_SUBCATEGORY_FILTERS.items():
            top_cat = by_name.get(top_name)
            sub_cat = by_parent_and_name.get((top_cat.id, sub_name)) if top_cat else None
            if sub_cat is None:
                continue
            result = await db.execute(
                delete(CategoryFilter).where(
                    CategoryFilter.category_id == sub_cat.id,
                    CategoryFilter.field_name.in_(retired),
                )
            )
            counts["filters_retired"] += result.rowcount or 0
        await db.commit()

        # ── Pass 4b: brand suggestions follow BRAND_SUGGESTIONS ─────────
        # The one place rows that already exist are brought up to date
        # rather than left alone: a database seeded before a brand list
        # existed (or before a brand was added to one) would otherwise
        # never show it. Text fields only - a "select" is a closed list a
        # listing's value was checked against, and changing one under
        # listings that already hold a value is a different decision.
        for (top_name, sub_name), brands in BRAND_SUGGESTIONS.items():
            top_cat = by_name.get(top_name)
            sub_cat = by_parent_and_name.get((top_cat.id, sub_name)) if top_cat else None
            field_name = suggestion_field(top_name, sub_name)
            if sub_cat is None or field_name is None:
                continue
            row = (await db.execute(select(CategoryFilter).where(
                CategoryFilter.category_id == sub_cat.id,
                CategoryFilter.field_name == field_name,
            ))).scalars().first()
            if row is None or row.field_type != "text":
                continue
            try:
                current = json.loads(row.options) if row.options else None
            except (TypeError, ValueError):
                current = None
            if current != brands:
                row.options = json.dumps(brands)
                counts["suggestions_updated"] += 1
        await db.commit()

        # ── Pass 5: stored category names follow their category ─────────
        await _sync_stored_category_names(db, by_name)
        await db.commit()

    return counts


async def _top_level(db, name: str):
    return (await db.execute(
        select(Category).where(Category.name == name, Category.parent_id.is_(None))
    )).scalars().first()


async def _child(db, parent_id: str, name: str):
    return (await db.execute(
        select(Category).where(Category.parent_id == parent_id, Category.name == name)
    )).scalars().first()


async def _sync_stored_category_names(db, by_name: dict) -> None:
    """Listings, stores and buy-agent requests store their top-level
    category by NAME (free text, from before the taxonomy had ids), and the
    feed, the category filter and a store's category rail all match on it.
    After "Vehicles" became "Automobiles", a listing still saying "Vehicles"
    would drop out of the Automobiles zone's name filter and render with the
    catch-all icon. Matches nothing once done, so repeating it is one scan.
    """
    from api.database import BuyAgentRequest, Listing
    from api.models.store import Store

    for old_name, new_name in RENAMED_CATEGORIES.items():
        for model in (Listing, Store, BuyAgentRequest):
            await db.execute(
                update(model).where(func.lower(model.category) == old_name.lower())
                .values(category=new_name)
            )
    # A listing filed under a subcategory that moved (Property -> Land)
    # says the old parent's name; it now belongs to the new parent.
    for _old, (new_parent, new_name) in MOVED_SUBCATEGORIES.items():
        parent = by_name.get(new_parent)
        if parent is None:
            continue
        moved = await _child(db, parent.id, new_name)
        if moved is None:
            continue
        await db.execute(
            update(Listing).where(Listing.subcategory_id == moved.id, Listing.category != new_parent)
            .values(category=new_parent)
        )


def canonical_category_name(value: str) -> str:
    """The current name for a top-level category name that has been
    renamed ("vehicles" -> "Automobiles"), in any case; anything else is
    returned as given. Drafts and app builds from before a rename still
    send the old name."""
    renamed = {old.lower(): new for old, new in RENAMED_CATEGORIES.items()}
    return renamed.get(value.strip().lower(), value)
