"""
generate_source_files.py

Creates the dummy source files for Assignment 2.3: five consecutive days of
four daily files, deliberately messy, with the five required defects in the
Day 3 files.

    item_master_YYYYMMDD.csv         daily snapshot   -> DIM_ITEM, DIM_SUBCATG, DIM_CATG
    store_master_YYYYMMDD.csv        store snapshot   -> DIM_LOCN, DIM_DISTRICT, DIM_REGN, DIM_AREA
    pos_sales_YYYYMMDD.csv           daily sales      -> FCT_SALES
    inventory_snapshot_YYYYMMDD.csv  daily position   -> FCT_INVENTORY

Items and stores are a small subset of the Northline Retail reference data
(RMS ITEM_MASTER, SUBCLASS, DEPS, STORE and the org hierarchy), so the dummy
files stay consistent with the 2.1 model and 2.2 architecture.

Usage:
    python generate_source_files.py --out ../sample_data --start 2026-11-01

The script is deterministic (fixed random seed): running it twice produces
identical files.
"""

from __future__ import annotations

import argparse
import csv
import random
from datetime import date, timedelta
from pathlib import Path

SEED = 2303
NUM_DAYS = 5

# ---------------------------------------------------------------------------
# Reference data (subset of Northline RMS)
# item_id, item_name, brand, subclass_id, subclass_name, dept_id, dept_name,
# unit_cost, unit_retail
# ---------------------------------------------------------------------------
ITEMS = [
    ["10000641", "Yardline Pro Pest", "Yardline", "10032", "Pest", "100", "Lawn & Garden", "110.67", "169.63"],
    ["10000640", "Yardline Trail Fertilizer", "Yardline", "10031", "Fertilizer", "100", "Lawn & Garden", "119.40", "308.79"],
    ["10000625", "Northline Heritage Shrub", "Northline", "10012", "Shrubs", "100", "Lawn & Garden", "31.98", "51.27"],
    ["10000631", "Northline Barn Hand Tool", "Northline", "10021", "Hand Tools", "100", "Lawn & Garden", "126.83", "267.97"],
    ["10000621", "Northline Barn Annual", "Northline", "10011", "Annuals", "100", "Lawn & Garden", "16.98", "41.01"],
    ["10000648", "Northline Lite Oil", "Northline", "11011", "Oil", "110", "Automotive", "105.39", "193.00"],
    ["10000666", "Iron Acre Summit Lawn", "Iron Acre", "11032", "Lawn", "110", "Automotive", "47.58", "75.71"],
    ["10000649", "Yardline Summit Coolant", "Yardline", "11012", "Coolant", "110", "Automotive", "24.56", "45.84"],
    ["10000652", "Trailmark Trail Coolant", "Trailmark", "11012", "Coolant", "110", "Automotive", "58.82", "87.63"],
    ["10000659", "Trailmark Barn Light", "Trailmark", "11022", "Lights", "110", "Automotive", "67.67", "139.53"],
    ["10000672", "Daily Barn Heavy Dog Large", "Daily Barn", "12011", "Dog", "120", "Pets", "5.04", "9.61"],
    ["10000682", "Northline Classic Treat Spicy", "Northline", "12022", "Treats", "120", "Pets", "47.10", "75.27"],
    ["10000669", "Clear Creek Pro Dog Unscented", "Clear Creek", "12011", "Dog", "120", "Pets", "43.23", "71.36"],
    ["10000684", "Clear Creek Trail Treat Unscented", "Clear Creek", "12022", "Treats", "120", "Pets", "11.59", "19.43"],
    ["10000679", "Northline Heavy Litter Spicy", "Northline", "12021", "Litter", "120", "Pets", "40.01", "72.23"],
    ["10000686", "Trailmark Pro Cattle", "Trailmark", "13011", "Cattle", "130", "Farm & Ranch", "28.43", "49.05"],
    ["10000692", "Northline Trail Poultry", "Northline", "13012", "Poultry", "130", "Farm & Ranch", "7.04", "15.95"],
    ["10000699", "Trailmark Trail Wire", "Trailmark", "13021", "Wire", "130", "Farm & Ranch", "88.20", "152.30"],
    ["10000701", "Trailmark Lite Post", "Trailmark", "13022", "Posts", "130", "Farm & Ranch", "14.49", "26.04"],
    ["10000688", "Iron Acre Daily Cattle", "Iron Acre", "13011", "Cattle", "130", "Farm & Ranch", "65.34", "129.57"],
    ["10000722", "Yardline Pro Supplie", "Yardline", "14021", "Supplies", "140", "Seasonal", "61.72", "99.75"],
    ["10000719", "Trailmark Summit Decor", "Trailmark", "14012", "Decor", "140", "Seasonal", "117.64", "258.17"],
    ["10000726", "Trailmark Trail Lunch", "Trailmark", "14022", "Lunch", "140", "Seasonal", "91.14", "174.40"],
    ["10000716", "Trailmark Classic Costume", "Trailmark", "14011", "Costumes", "140", "Seasonal", "50.99", "117.80"],
    ["10000729", "Yardline Barn Trim", "Yardline", "14031", "Trim", "140", "Seasonal", "58.60", "94.96"],
    ["10000114", "Harbor & Co Barn Denim Olive Sz L", "Harbor & Co", "2031", "Denim", "20", "Mens Apparel", "40.14", "91.52"],
    ["10000100", "Metro Line Heavy Flannel Olive Sz XS", "Metro Line", "2022", "Flannels", "20", "Mens Apparel", "32.03", "51.93"],
    ["10000061", "Harbor & Co Heavy Dress Shirt Navy Sz XXL", "Harbor & Co", "2021", "Dress Shirts", "20", "Mens Apparel", "42.88", "81.52"],
    ["10000020", "Red Barn Daily Tee White Sz XL", "Red Barn", "2011", "Tees", "20", "Mens Apparel", "35.69", "78.19"],
    ["10000094", "Red Barn Barn Flannel Khaki Sz M", "Red Barn", "2022", "Flannels", "20", "Mens Apparel", "6.08", "11.28"],
    ["10000285", "Red Barn Heavy Legging Red Sz XS", "Red Barn", "3032", "Leggings", "30", "Womens Apparel", "9.88", "25.06"],
    ["10000269", "Metro Line Heritage Denim Navy Sz S", "Metro Line", "3031", "Denim", "30", "Womens Apparel", "3.16", "7.86"],
    ["10000221", "Harbor & Co Heritage Casual Grey Sz S", "Harbor & Co", "3021", "Casual", "30", "Womens Apparel", "2.52", "5.29"],
    ["10000263", "Fieldwork Barn Denim Blue Sz XXL", "Fieldwork", "3031", "Denim", "30", "Womens Apparel", "25.43", "42.54"],
    ["10000280", "Red Barn Summit Denim Olive Sz L", "Red Barn", "3031", "Denim", "30", "Womens Apparel", "45.14", "105.58"],
    ["10000404", "Harbor & Co Barn Short White Sz XL", "Harbor & Co", "4022", "Shorts", "40", "Kids Apparel", "16.39", "24.59"],
    ["10000378", "Red Barn Lite Sweatshirt Black Sz XS", "Red Barn", "4012", "Sweatshirts", "40", "Kids Apparel", "45.01", "96.95"],
    ["10000402", "Harbor & Co Barn Short Red Sz XXL", "Harbor & Co", "4022", "Shorts", "40", "Kids Apparel", "34.72", "79.99"],
    ["10000359", "Fieldwork Daily Tee Blue Sz XL", "Fieldwork", "4011", "Tees", "40", "Kids Apparel", "9.05", "14.82"],
    ["10000383", "Metro Line Heavy Jean Black Sz XL", "Metro Line", "4021", "Jeans", "40", "Kids Apparel", "19.92", "44.68"]
]

# store_id, store_name, district_id, district_name, region_id, region_name,
# area_id, area_name, country, city, open_date
STORES = [
    ["1101", "Northline Hartford #1101", "101", "Northeast D1", "11", "Northeast", "1", "East", "US", "Hartford", "20191022"],
    ["1102", "Northline Albany #1102", "101", "Northeast D1", "11", "Northeast", "1", "East", "US", "Albany", "20201123"],
    ["1104", "Northline Boston #1104", "102", "Northeast D2", "11", "Northeast", "1", "East", "US", "Boston", "20140125"],
    ["1105", "Northline Providence #1105", "102", "Northeast D2", "11", "Northeast", "1", "East", "US", "Providence", "20150226"],
    ["1107", "Northline Savannah #1107", "103", "Southeast D1", "12", "Southeast", "1", "East", "US", "Savannah", "20170401"],
    ["1109", "Northline Savannah #1109", "103", "Southeast D1", "12", "Southeast", "1", "East", "US", "Savannah", "20190603"],
    ["1112", "Northline Jacksonville #1112", "108", "Plains D2", "22", "Plains", "2", "Central", "US", "Jacksonville", "20140906"],
    ["1116", "Northline Chicago #1116", "106", "Great Lakes D2", "21", "Great Lakes", "2", "Central", "US", "Chicago", "20180110"],
    ["1121", "Northline Minneapolis #1121", "107", "Plains D1", "22", "Plains", "2", "Central", "US", "Minneapolis", "20150615"],
    ["1125", "Northline Salt Lake City #1125", "109", "Rockies D1", "31", "Rockies", "3", "West", "US", "Salt Lake City", "20191019"],
    ["1131", "Northline Fresno #1131", "111", "Pacific D1", "32", "Pacific", "3", "West", "US", "Fresno", "20170425"],
    ["1137", "Northline Ottawa #1137", "113", "Ontario D1", "41", "Ontario", "4", "Canada", "CA", "Ottawa", "20151004"]
]

# Store 1112 starts in district 104 and moves to district 108 on Day 3 (SCD2).
MOVING_STORE = "1112"
DISTRICT_BEFORE = ["104", "Southeast D2", "12", "Southeast", "1", "East"]
DISTRICT_AFTER = ["108", "Plains D2", "22", "Plains", "2", "Central"]

# Planned changes (besides the Day 3 defects)
SCD1_ITEM = "10000722"                       # Day 2: name typo corrected (SCD1)
SCD1_ITEM_NEW_NAME = "Yardline Pro Supplies"
SCD2_ITEM = "10000020"                       # Day 4: moves subclass Tees -> Polos (SCD2)
SCD2_NEW_SUBCLASS = ("2012", "Polos")
NEW_ITEM = ["10000901", "Red Barn Daily Polo Green Sz M", "Red Barn",
            "2012", "Polos", "20", "Mens Apparel", "14.20", "29.99"]   # Day 5: new item
UNKNOWN_ITEM = "99990001"                    # Day 3: sold but not in item master

CAD_RATE = 1.36   # Ottawa store prices are in CAD


def us_currency(rng: random.Random) -> str:
    """Messy spellings of US dollars, as in the real source systems."""
    return rng.choices(["USD", "usd", "US$"], weights=[80, 10, 10])[0]


def messy_store_code(store_id: str, rng: random.Random) -> str:
    """Store codes arrive as 1101, 01101 or NL-01101."""
    return rng.choices([store_id, "0" + store_id, "NL-0" + store_id], weights=[80, 12, 8])[0]


def messy_date(d: date, rng: random.Random) -> str:
    """Business dates arrive as ISO or M/D/YYYY."""
    if rng.random() < 0.15:
        return f"{d.month}/{d.day}/{d.year}"
    return d.isoformat()


def write_csv(path: Path, header: list[str], rows: list[list]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def item_rows(day_no: int, rng: random.Random) -> list[list]:
    rows = []
    for it in ITEMS:
        item_id, name, brand, sub_id, sub_nm, dept_id, dept_nm, cost, retail = it
        if item_id == SCD1_ITEM and day_no >= 2:
            name = SCD1_ITEM_NEW_NAME
        if item_id == SCD2_ITEM and day_no >= 4:
            sub_id, sub_nm = SCD2_NEW_SUBCLASS
        # messy: stray spaces and inconsistent case on descriptive text
        if rng.random() < 0.1:
            name = "  " + name + " "
        if rng.random() < 0.1:
            sub_nm = sub_nm.upper()
        rows.append([item_id, name, brand, sub_id, sub_nm, dept_id, dept_nm,
                     cost, retail, "A"])
    if day_no >= 5:
        rows.append(NEW_ITEM + ["A"])
    return rows


def store_rows(day_no: int, rng: random.Random) -> list[list]:
    rows = []
    for st in STORES:
        store_id, name, d_id, d_nm, r_id, r_nm, a_id, a_nm, country, city, opened = st
        if store_id == MOVING_STORE:
            d_id, d_nm, r_id, r_nm, a_id, a_nm = DISTRICT_AFTER if day_no >= 3 else DISTRICT_BEFORE
        currency = "CAD" if country == "CA" else us_currency(rng)
        if rng.random() < 0.15:
            name = name.replace(" #", "  #")   # messy: double space
        rows.append([store_id, name, "S", d_id, d_nm, r_id, r_nm, a_id, a_nm,
                     country, city, currency, opened, ""])
    return rows


def sales_rows(day: date, day_no: int, items: list[list], rng: random.Random) -> list[list]:
    rows = []
    sellable = [r for r in items]
    for st in STORES:
        store_id, country = st[0], st[8]
        n_txn = rng.randint(12, 22)
        for t in range(1, n_txn + 1):
            txn_id = f"{store_id}-{day:%Y%m%d}-{rng.randint(1, 4)}-{t:04d}"
            for line in range(1, rng.randint(1, 4) + 1):
                it = rng.choice(sellable)
                qty = rng.choices([1, 2, 3, 4], weights=[60, 25, 10, 5])[0]
                price = float(it[8])
                if country == "CA":
                    price = round(price * CAD_RATE, 2)
                discount = round(price * qty * rng.choice([0, 0, 0, 0.1, 0.2]), 2)
                net = round(price * qty - discount, 2)
                currency = "CAD" if country == "CA" else us_currency(rng)
                item_id = it[0] if rng.random() > 0.05 else f" {it[0]} "   # messy: spaces
                rows.append([txn_id, line, messy_date(day, rng), messy_store_code(store_id, rng),
                             item_id, qty, f"{price:.2f}", f"{discount:.2f}", f"{net:.2f}", currency])
    if day_no == 3:
        rows = add_day3_defects(rows, day, rng)
    return rows


def add_day3_defects(rows: list[list], day: date, rng: random.Random) -> list[list]:
    """The four sales defects required on Day 3 (the fifth is the store move)."""
    # Pick four different rows so each defect appears exactly once.
    null_a, null_b, neg_idx, dup_idx = rng.sample(range(len(rows)), 4)
    # 1. Two rows with a null item id
    for idx in (null_a, null_b):
        rows[idx][4] = ""
    # 2. One row with a negative sales quantity
    idx = neg_idx
    qty = int(rows[idx][5])
    price = float(rows[idx][6])
    rows[idx][5] = -qty
    rows[idx][7] = "0.00"
    rows[idx][8] = f"{-qty * price:.2f}"
    # 3. One sale for an item missing from the item master
    rows.append([f"1101-{day:%Y%m%d}-9-9999", 1, day.isoformat(), "1101", UNKNOWN_ITEM,
                 1, "19.99", "0.00", "19.99", "USD"])
    # 4. One duplicated transaction line (exact copy of a clean row)
    rows.append(list(rows[dup_idx]))
    return rows


def inventory_rows(day: date, day_no: int, items: list[list], prev: dict, rng: random.Random) -> tuple[list[list], dict]:
    """Daily position. About 20% of item/store balances change each day."""
    state = {}
    rows = []
    for st in STORES:
        for it in items:
            key = (it[0], st[0])
            if key not in prev:
                qty = rng.randint(0, 60)
            elif rng.random() < 0.2:
                qty = prev[key] + rng.randint(-12, 15)       # may go negative, as in RMS
            else:
                qty = prev[key]
            state[key] = qty
            cost = float(it[7]) * (CAD_RATE if st[8] == "CA" else 1)
            rows.append([day.isoformat(), st[0], it[0], qty, f"{cost:.2f}"])
    return rows, state


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", default="sample_data", help="output folder")
    p.add_argument("--start", default="2026-11-01", help="first business date (YYYY-MM-DD)")
    args = p.parse_args()

    rng = random.Random(SEED)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    start = date.fromisoformat(args.start)
    inv_state: dict = {}

    for day_no in range(1, NUM_DAYS + 1):
        day = start + timedelta(days=day_no - 1)
        tag = f"{day:%Y%m%d}"

        items = item_rows(day_no, rng)
        write_csv(out / f"item_master_{tag}.csv",
                  ["item_id", "item_name", "brand_name", "subclass_id", "subclass_name",
                   "dept_id", "dept_name", "unit_cost", "unit_retail", "status"], items)

        write_csv(out / f"store_master_{tag}.csv",
                  ["store_id", "store_name", "store_type", "district_id", "district_name",
                   "region_id", "region_name", "area_id", "area_name", "country", "city",
                   "currency_code", "open_date", "close_date"], store_rows(day_no, rng))

        clean_items = [[c.strip() if isinstance(c, str) else c for c in r] for r in items]
        write_csv(out / f"pos_sales_{tag}.csv",
                  ["transaction_id", "line_number", "business_date", "store_id", "item_id",
                   "quantity", "unit_price", "discount_amount", "net_amount", "currency_code"],
                  sales_rows(day, day_no, clean_items, rng))

        inv, inv_state = inventory_rows(day, day_no, clean_items, inv_state, rng)
        write_csv(out / f"inventory_snapshot_{tag}.csv",
                  ["snapshot_date", "store_id", "item_id", "on_hand_qty", "unit_cost"], inv)

        print(f"Day {day_no} ({day}): 4 files written")


if __name__ == "__main__":
    main()
