# Device Classification Pipeline

[← Back to README](../README.md)

> Figures are rescaled and operator product names anonymised (see the note in the README).

All steps are in [`sql/household_device_classification.sql`](../sql/household_device_classification.sql). The code runs on Netezza (MPP) and processes one month of router Wi-Fi station logs (home = broadband circuit) at a time.

## 1. Inputs

| Source | Grain | Used for |
|---|---|---|
| Router Wi-Fi station log | day × circuit × hostname (+ connect time) | Device presence and activity |
| Product dimension | circuit | Keep individual (residential) home-broadband customers only |
| Team app-usage table | month × circuit × app category | Usage signals for use-case targeting |

## 2. Device groups

| Group | What it covers | Example hostnames |
|---|---|---|
| Mobile_Smartphone | Phones from all brands | `iphone`, `galaxy-s23`, `rmx2189`, `v2027` |
| Mobile_Tablet | Tablets | `ipad`, `galaxy-tab`, `matepad`, `dbr-w09` |
| PC_Laptop | Desktops and laptops | `desktop-xxxx`, `macbook`, `matebook`, `surface` |
| TV | Smart TVs with a built-in OS | `lgwebostv`, `tizen`, `mitv`, `x1-ultimate` |
| TV_BOX | Streaming / set-top boxes | `optv`, `chromecast`, `hi3798mv200` |
| Camera_CCTV | IP cameras | `opipc`, `nomi-ipc`, `chuangmi`, `c530ws` |
| IoT_SmartHome | Smart-home and appliances | `roborock-vacuum`, `zhimi-airpurifier`, `epson`, `lge_ac` |
| MESH_WIFI | Mesh nodes and extenders | `opmesh`, `deco`, `re650`, `tl-wa` |
| Wearable | Watches | `apple-watch`, `imoo` |
| Other / Unknown | User-named or random names that match no rule | — |

## 3. Pipeline steps

### 3.1 Monthly aggregation
For each circuit and hostname, compute **active days** (distinct dates seen) and **total connect time** for the month.

### 3.2 Hostname cleaning
- Remove broken UTF-8 surrogate byte sequences that appear in raw hostnames.
- Lowercase and trim.
- For grouping keys only: strip non-alphanumerics and long hex suffixes (MAC- or serial-like tails such as `...a1b2c3d4e5`).

### 3.3 Canonicalisation (de-duplicating renamed devices)
The same physical device often shows up under several names within one home in the same month. For example, a phone's name changes after an OS update, or an IoT module appends a random suffix.

```sql
-- group key: first 6+ letters (+ up to 2 digits) of the cleaned name
GRP_KEY = REGEXP_REPLACE(BASE_KEY, '^([a-z]{6,}[0-9]{0,2}).*$', '\1')

-- pick one canonical name per (month, circuit, group key)
ROW_NUMBER() OVER (
  PARTITION BY MNTH_ID, CIRCUIT, GRP_KEY
  ORDER BY SURVIVE_RANK ASC,      -- passes activity filter first
           ACTIVE_DAYS DESC,      -- then most active
           CONNECTTIME DESC,
           LENGTH(GRP_KEY) ASC, HOSTNAME_RAW ASC)   -- deterministic tie-break
```
Non-canonical variants are flagged as duplicates and removed.

### 3.4 Activity filter
Each record gets a priority-ordered flag:

| Flag | Rule | Kept? |
|---|---|---|
| 1 | Duplicate (non-canonical name) | ✗ |
| 5 | Always-on home device (TV, TV box, Mesh, CCTV, IoT) | ✓ always |
| 2 | Zero active days or zero connect time | ✗ |
| 3 | Seen on fewer than 2 days | ✗ |
| 4 | Connected less than 30 s in the month | ✗ |
| 5 | Everything else | ✓ |

Fixed home devices are exempt. A camera that connects once and then holds a single long session is still real, while a phone seen for a few seconds on one day is usually a visitor.

### 3.5 Rule-based classification
Three ordered `CASE` blocks, each evaluated top-down (first match wins):

| Block | Rules | Output |
|---|---|---|
| Device group | ~150 | 9 groups + Other/Unknown |
| Brand (within group) | ~200 | e.g. Apple, Samsung, OPPO, OpTV, OpMesh, Xiaomi, TP-Link Tapo |
| IoT category | ~60 | Air purifier, printer, robot vacuum, washing machine, smart bulb, speaker, fan, pet feeder, … |

Rule ordering matters, so the blocks are layered:
1. **Hard overrides.** Exact model codes, e.g. `ady-al00` → phone, `hi3798mv200` → TV box, `steamdeck` → tablet.
2. **Disambiguation guards.** Audio accessories (`earphone`, `speaker`) are caught before phone rules, and anything containing `book` before phone rules (MateBook, MacBook).
3. **Pattern families.** `rmx####` → realme, `2#######xx` → Xiaomi model codes, `c###ws` → TP-Link camera, `re###` → TP-Link extender.
4. **Brand keywords.** `iphone`, `galaxy`, `oppo`, `vivo`, `redmi`, …
5. **Generic catch-alls.** `android`, `tv`, `smart*` (but not `smartphone`), `watch`.

Rules were grown iteratively: each pass, I pulled the largest remaining "Other" hostnames, researched the model codes and added rules until the remaining unclassified long tail was mostly user-chosen names.

**Coverage:** 77% of active devices are classified into a group, and 68% carry a brand.

### 3.6 Household aggregation
Per circuit and month:
- device counts per group (`COUNT(DISTINCT hostname)` with a NULL sentinel)
- per-brand device counts per group (e.g. Apple phones, Apple tablets, operator TV boxes)
- IoT category mix
- a **combination key** built in a fixed order, e.g. `Mesh_wifi+Smartphone+TV_Box+CCTV`
- **Operator-device flags** (operator TV box, CCTV, Mesh, phone) and their combination

### 3.7 Outputs

| Table | Grain | Purpose |
|---|---|---|
| `AUTO_HBB_MASTER_DEVICE` | hostname | Dictionary: hostname → group, brand, IoT category |
| `AUTO_HBB_SUBR_USAGE_DEVICE` | month × circuit | Device counts per group |
| `AUTO_HBB_SUBR_USAGE_DEVICE_EXTENDED` | month × circuit | Full household profile for targeting |
| `HBB_USECASE_ASSESTNUM` | month × circuit × use case | Target lists |

## 4. Validation
- Compared device totals across three consecutive months. Group mix was stable month to month (smartphones ~50%, CCTV 6–7%, TV box ~4%).
- Measured how each filter step changed counts per device group. The 2-day rule removed ~23% of phone records, which are mostly visitors. It would also have removed ~18% of TV/TV-box records, which led to the decision to exempt always-on home devices.
- Checked brand shares against an external market-share reference for smartphones.

## 5. What I would improve
- **Move rules from `CASE` statements into a mapping table** (`pattern`, `priority`, `group`, `brand`) so analysts can add rules without editing SQL.
- **Keep a labelled regression set** of hostnames and re-check accuracy whenever rules change.
- **Track coverage monthly** (% classified, % branded) as a data-quality KPI.
- **Try a lightweight ML classifier** (character n-grams) on the remaining "Other" long tail, using the rule output as training labels.
