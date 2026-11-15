/* ============================================================
   AGGREGATE THE DATA INTO MONTHLY TREND
   ============================================================ */
DROP TABLE TEMP_CURCUIT_DATA_AGG IF EXISTS;

CREATE TEMP TABLE TEMP_CURCUIT_DATA_AGG AS
(
SELECT
   CAST(SUBSTR(CAST(DATE_ID AS VARCHAR(8)), 1, 6) AS INT)                    AS MNTH_ID   
  ,CIRCUIT
  ,WIFI_STA_INFORMATION_HOSTNAME
  ,COUNT(DISTINCT SUBSTR(CAST(DATE_ID AS VARCHAR(8)), 1, 8))                  AS ACTIVE_DAYS  
  ,SUM(COALESCE(ABS(CAST(CONNECTTIME AS DOUBLE)), 0.0))   AS CONNECTTIME
FROM NZ_MART.admin.ROUTER_AGENT_WIFI_STA_INFO
WHERE DATE_ID BETWEEN 20250701 AND 20250731
GROUP BY 1, 2, 3
)
DISTRIBUTE ON (MNTH_ID, CIRCUIT, WIFI_STA_INFORMATION_HOSTNAME)
;


/* ============================================================
   FILTER OUT THE BUSINESS CUSTOMER
   ============================================================ */
DROP TABLE TMP_PROD_OK_DISTINCT IF EXISTS;

CREATE TEMP TABLE TMP_PROD_OK_DISTINCT AS
SELECT DISTINCT REF_RESRE_NBR AS CIRCUIT
FROM SANDBOX_NZ.ADMIN.DIM_PROD
WHERE PROD_TYP_CD = 2
  AND PROD_SUB_TYP IN ('I','IF','INF','Q','FT')
  AND SUBSTR(REF_RESRE_NBR, 1, 2) IN ('88','NF','91','96')
DISTRIBUTE ON (CIRCUIT);

DROP TABLE TEMP_CURCUIT_DATA_AGG_INDI IF EXISTS;

CREATE TEMP TABLE TEMP_CURCUIT_DATA_AGG_INDI AS
SELECT a.*
FROM TEMP_CURCUIT_DATA_AGG a
JOIN TMP_PROD_OK_DISTINCT p
  ON p.CIRCUIT = a.CIRCUIT
DISTRIBUTE ON (MNTH_ID, CIRCUIT, WIFI_STA_INFORMATION_HOSTNAME);



/* ============================================================
   A) CLEAN HOSTNAMES (surrogate scrub) FOR INDI SET
   ============================================================ */
DROP TABLE TEMP_CURCUIT_DATA_TEMP_INDI IF EXISTS;

CREATE TEMP TABLE TEMP_CURCUIT_DATA_TEMP_INDI AS
SELECT DISTINCT
     A.MNTH_ID
    ,A.CIRCUIT
    /* clean the surrogate triples */
    ,TRIM(
      NZ_MART.ADMIN.REGEXP_REPLACE(
        CAST(A.WIFI_STA_INFORMATION_HOSTNAME AS VARCHAR(1024)),
        '\\xED[\\xA0-\\xBF][\\x80-\\xBF]',
        ''
      )
    ) AS WIFI_STA_INFORMATION_HOSTNAME_CLEAN
FROM TEMP_CURCUIT_DATA_AGG_INDI A
WHERE A.WIFI_STA_INFORMATION_HOSTNAME IS NOT NULL
DISTRIBUTE ON (CIRCUIT, WIFI_STA_INFORMATION_HOSTNAME_CLEAN);

-- keep explicit NULL rows for completeness (will remain NULL in flags)
INSERT INTO TEMP_CURCUIT_DATA_TEMP_INDI (MNTH_ID, CIRCUIT, WIFI_STA_INFORMATION_HOSTNAME_CLEAN)
SELECT DISTINCT  A.MNTH_ID 
				,A.CIRCUIT 
				,A.WIFI_STA_INFORMATION_HOSTNAME
FROM TEMP_CURCUIT_DATA_AGG_INDI A
WHERE A.WIFI_STA_INFORMATION_HOSTNAME IS NULL;


/* ============================================================
   B) Build canonical mapping (raw_clean → canonical) per circuit
   ============================================================ */

/* ============================================================
   Build canonical mapping on INDI using CLEAN hostname
   and survivability-aware ranking.
   Inputs:
     - TEMP_CURCUIT_DATA_TEMP_INDI (CIRCUIT, WIFI_STA_INFORMATION_HOSTNAME_CLEAN)
     - TEMP_CURCUIT_DATA_AGG_INDI  (CIRCUIT, WIFI_STA_INFORMATION_HOSTNAME, ACTIVE_DAYS, CONNECTTIME)
   Output:
     - MAP_HOST_CANON_INDI (circuit, WIFI_STA_INFORMATION_HOSTNAME_CLEAN, WIFI_STA_INFORMATION_HOSTNAME_CANON)
   ============================================================ */
--lastest one add mnth_id

DROP TABLE MAP_HOST_CANON_INDI IF EXISTS;

CREATE TEMP TABLE MAP_HOST_CANON_INDI AS
WITH SRC AS (
  SELECT
       T.MNTH_ID
      ,CAST(T.CIRCUIT AS VARCHAR(64)) AS CIRCUIT
      ,T.WIFI_STA_INFORMATION_HOSTNAME_CLEAN            AS HOSTNAME_RAW
  FROM TEMP_CURCUIT_DATA_TEMP_INDI T
  WHERE T.WIFI_STA_INFORMATION_HOSTNAME_CLEAN IS NOT NULL
),

/* survivability metrics come from the *INDI* aggregate, join on CLEAN + month */
MET AS (
  SELECT
       A.MNTH_ID
      ,CAST(A.CIRCUIT AS VARCHAR(64))                   AS CIRCUIT
      /* NORMALIZE TO THE SAME CLEANED FORM USED IN SRC */
      ,TRIM(
        NZ_MART.ADMIN.REGEXP_REPLACE(
          CAST(A.WIFI_STA_INFORMATION_HOSTNAME AS VARCHAR(1024))
          ,'\\xED[\\xA0-\\xBF][\\x80-\\xBF]', ''
        )
      )                                                AS HOSTNAME_CLEAN
      ,COALESCE(A.ACTIVE_DAYS, 0)                       AS ACTIVE_DAYS
      ,COALESCE(A.CONNECTTIME, 0)                       AS CONNECTTIME
      ,CASE
        WHEN COALESCE(A.ACTIVE_DAYS,0) >= 2
         AND COALESCE(A.CONNECTTIME,0) >= 30000 THEN 0  -- SURVIVOR
        ELSE 1
      END                                              AS SURVIVE_RANK
  FROM TEMP_CURCUIT_DATA_AGG_INDI A
  WHERE A.WIFI_STA_INFORMATION_HOSTNAME IS NOT NULL
),

/* normalize + strip long hex suffixes; keep a non-empty key */
NORM AS (
  SELECT
       S.MNTH_ID
      ,S.CIRCUIT
      ,S.HOSTNAME_RAW
      ,NZ_MART.ADMIN.REGEXP_REPLACE(LOWER(S.HOSTNAME_RAW), '[^a-z0-9]+','') AS HOST_ALNUM
      ,NZ_MART.ADMIN.REGEXP_REPLACE(
        NZ_MART.ADMIN.REGEXP_REPLACE(LOWER(S.HOSTNAME_RAW), '[^a-z0-9]+',''),
        '([a-f0-9]{8,})$',''
      ) AS HOST_NOHEX
  FROM SRC S
),
KEYED AS (
  SELECT
       N.MNTH_ID
      ,N.CIRCUIT
      ,N.HOSTNAME_RAW
      ,COALESCE(NULLIF(N.HOST_NOHEX,''), N.HOST_ALNUM) AS BASE_KEY
  FROM NORM N
),

/* STRONGER grouping: prefix of ≥6 letters (+ up to 2 digits); else full key */
GRP AS (
  SELECT
       K.MNTH_ID
      ,K.CIRCUIT
      ,K.HOSTNAME_RAW
      ,COALESCE(
        NZ_MART.ADMIN.REGEXP_REPLACE(K.BASE_KEY, '^([a-z]{6,}[0-9]{0,2}).*$', '\1'),
        NZ_MART.ADMIN.REGEXP_REPLACE(K.BASE_KEY, '^([a-z]{6,}).*$', '\1'),
        K.BASE_KEY
      ) AS GRP_KEY
  FROM KEYED K
),

/* rank: survivability first, then activity/connecttime, then aesthetics */
RANKED AS (
  SELECT
       G.MNTH_ID
      ,G.CIRCUIT
      ,G.HOSTNAME_RAW
      ,G.GRP_KEY
      ,COALESCE(M.SURVIVE_RANK, 1) AS SURVIVE_RANK
      ,COALESCE(M.ACTIVE_DAYS, 0)  AS ACTIVE_DAYS
      ,COALESCE(M.CONNECTTIME, 0)  AS CONNECTTIME
      ,ROW_NUMBER() OVER (
        PARTITION BY G.MNTH_ID, G.CIRCUIT, G.GRP_KEY
        ORDER BY
          COALESCE(M.SURVIVE_RANK, 1) ASC,   -- SURVIVOR FIRST
          COALESCE(M.ACTIVE_DAYS, 0) DESC,   -- THEN MORE ACTIVE DAYS
          COALESCE(M.CONNECTTIME, 0) DESC,   -- THEN MORE CONNECT TIME
          CASE WHEN NZ_MART.ADMIN.REGEXP_LIKE(G.GRP_KEY,'[a-z]') THEN 0 ELSE 1 END,
          LENGTH(G.GRP_KEY) ASC,
          G.HOSTNAME_RAW ASC
      ) AS RN
  FROM GRP G
  LEFT JOIN MET M
    ON M.MNTH_ID = G.MNTH_ID
   AND M.CIRCUIT = G.CIRCUIT
   AND M.HOSTNAME_CLEAN = G.HOSTNAME_RAW
),

CANON AS (
  SELECT  MNTH_ID 
	     ,CIRCUIT 
		 ,GRP_KEY 
		 ,HOSTNAME_RAW AS CANONICAL_HOSTNAME
  FROM RANKED
  WHERE RN = 1
)

SELECT
     G.MNTH_ID
    ,G.CIRCUIT
    ,G.HOSTNAME_RAW                               AS WIFI_STA_INFORMATION_HOSTNAME_CLEAN
    ,C.CANONICAL_HOSTNAME                         AS WIFI_STA_INFORMATION_HOSTNAME_CANON
FROM GRP G
JOIN CANON C
  ON C.MNTH_ID = G.MNTH_ID
 AND C.CIRCUIT = G.CIRCUIT
 AND C.GRP_KEY = G.GRP_KEY
DISTRIBUTE ON (MNTH_ID, CIRCUIT, WIFI_STA_INFORMATION_HOSTNAME_CLEAN);



/* ============================================================
   C) Mark duplicates (cleaned values not equal to canonical)
   ============================================================ */
DROP TABLE TMP_DUP_HOSTS_INDI IF EXISTS;

CREATE TEMP TABLE TMP_DUP_HOSTS_INDI AS
SELECT DISTINCT
   T.MNTH_ID
  ,T.CIRCUIT
  ,T.WIFI_STA_INFORMATION_HOSTNAME_CLEAN
FROM TEMP_CURCUIT_DATA_TEMP_INDI T
JOIN MAP_HOST_CANON_INDI M
  ON M.MNTH_ID = T.MNTH_ID
 AND M.CIRCUIT = T.CIRCUIT
 AND M.WIFI_STA_INFORMATION_HOSTNAME_CLEAN = T.WIFI_STA_INFORMATION_HOSTNAME_CLEAN
WHERE T.WIFI_STA_INFORMATION_HOSTNAME_CLEAN IS NOT NULL
  AND T.WIFI_STA_INFORMATION_HOSTNAME_CLEAN <> M.WIFI_STA_INFORMATION_HOSTNAME_CANON
DISTRIBUTE ON (MNTH_ID, CIRCUIT, WIFI_STA_INFORMATION_HOSTNAME_CLEAN);

/* ============================================================
   D) GROUPING DEVICE
   ============================================================ */

DROP TABLE TEMP_CURCUIT_DEVICE_DETAIL_INDI IF EXISTS;

CREATE TEMP TABLE TEMP_CURCUIT_DEVICE_DETAIL_INDI AS
(

WITH BASE AS (
  SELECT
       A.MNTH_ID
      ,A.CIRCUIT
      /* CLEAN THE HOSTNAME CONSISTENTLY */
      ,TRIM(
        NZ_MART.ADMIN.REGEXP_REPLACE(
          CAST(A.WIFI_STA_INFORMATION_HOSTNAME AS VARCHAR(1024)),
          '\\xED[\\xA0-\\xBF][\\x80-\\xBF]',
          ''
        )
      ) AS WIFI_STA_INFORMATION_HOSTNAME_CLEAN
      ,A.ACTIVE_DAYS
      ,A.CONNECTTIME
  FROM TEMP_CURCUIT_DATA_AGG_INDI A
)

  SELECT
      A.MNTH_ID
    , A.CIRCUIT
    , A.WIFI_STA_INFORMATION_HOSTNAME_CLEAN AS WIFI_STA_INFORMATION_HOSTNAME
    , A.ACTIVE_DAYS
    , A.CONNECTTIME
    , LOWER(TRIM(a.WIFI_STA_INFORMATION_HOSTNAME_CLEAN)) AS hn
    , CASE
	    
-- Put these early (just after your hard overrides / platform rules):

-- Laptops before phones if “book”
WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])matebook([^a-z0-9]|$)|book')
THEN 'PC_Laptop'

-- TP-Link extenders/routers variants: tl-wa... and tlwa...
WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^tl[-_]?wa|(^|[^a-z0-9])re[0-9]{3,4}x?($|[^a-z0-9])')
THEN 'MESH_WIFI'

-- Sony TV video processor
WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])x1[-_ ]ultimate([^a-z0-9]|$)')
THEN 'TV'

-- Audio accessories should NOT be phones
WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])(earphone|headphone|speaker)([^a-z0-9]|$)')
THEN 'IoT_SmartHome'

  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^marshall') THEN 'IoT_SmartHome'
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^macbook') THEN 'PC_Laptop'
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^desktop') THEN 'PC_Laptop'
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^laptop') THEN 'PC_Laptop'
  WHEN LOWER(TRIM(hn)) IN ('lge_ac2_open','lge_air2_open') THEN 'IoT_SmartHome' 
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'lgwebosit') THEN 'TV'
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'lge_dhum2_open|rockrobo') THEN 'IoT_SmartHome'		    	    
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'^yi-jia') THEN 'Mobile_Smartphone'	    
/* ===== OVERRIDES: exact hostnames → force DEVICE_GROUP ===== */
  /* Unknowns */
  WHEN LOWER(TRIM(hn)) IN (
    'v6','jack','acc001','<DEVICE_ID_1>','em-acc2','grace','peach','achi','qca4002'
  ) THEN 'Unknown'

WHEN NZ_MART.ADMIN.REGEXP_LIKE(
         LOWER(hn),
         '(^|[^a-z0-9])(macbook|mac[-_ ]?mini|imac|mac[-_ ]?studio|mbp|apple[-_ ]?macintosh|mac)([^a-z0-9]|$)'
       )
 THEN 'PC_Laptop'
/* Broader catch for common Mac tokens */
WHEN NZ_MART.ADMIN.REGEXP_LIKE(
  LOWER(TRIM(hn)),
  '^(imac(pro)?|macs?[-_ ]?(mbp|air|imac)|macoss?[-_ ]?(mbp|air)|macairs[-_ ]?air|users[-_ ]imac|airkhxnacintosh|applemacintosh2|imac-mbhmbk)$'
) THEN 'PC_Laptop'

WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'aliosthings')
                                           THEN 'IoT_SmartHome'
                                           
WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'^opmesh')
                                           THEN 'MESH_WIFI'
WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'^tl-wa')
                                           THEN 'MESH_WIFI'
WHEN LOWER(TRIM(hn)) = 'ipc-a22e-d' THEN 'Camera_CCTV'
  /* IoT / Smart Home */
  WHEN LOWER(TRIM(hn)) = 'roborock-vacuum-a104' THEN 'IoT_SmartHome'
  WHEN LOWER(TRIM(hn)) = 'tizenrt'               THEN 'IoT_SmartHome'
  WHEN LOWER(TRIM(hn)) = 'smart cat litter box c20' THEN 'IoT_SmartHome'

  /* Camera / CCTV */
  WHEN LOWER(TRIM(hn)) = 'nomi-ipc-a22e-g-v2' THEN 'Camera_CCTV'
  WHEN LOWER(TRIM(hn)) = 'homemate_device' THEN 'IoT_SmartHome'

  /* Smartphones (brand handled in brand overrides) */
  WHEN LOWER(TRIM(hn)) = 'ac79nn'                 THEN 'Mobile_Smartphone'  -- OPPO
  WHEN LOWER(TRIM(hn)) IN ('smart_4g_adventure_pro','smart_4g_p1','smart_4g_p1_prime')
                                                THEN 'Mobile_Smartphone'  -- OPER
  WHEN LOWER(TRIM(hn)) = '<DEVICE_ID_2>'
                                                THEN 'Mobile_Smartphone'  -- Android
  WHEN LOWER(TRIM(hn)) = 'blackpearl2'           THEN 'Mobile_Smartphone'  -- Ninetology

  /* PC / Laptop: Microsoft Surface */
  WHEN LOWER(TRIM(hn)) IN ('surface','surfacepro6')            THEN 'PC_Laptop'


	    
/* ======= HARD OVERRIDES (put these at the very top of your CASE) ======= */
	    
  /* Exact tokens */
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'^macintosh')
                                           THEN 'PC_Laptop'
  WHEN hn = 't20'                          THEN 'Mobile_Smartphone'   -- Wiko smartphone
  WHEN hn = 't506t'                        THEN 'Mobile_Smartphone'   -- TCL smartphone
  WHEN hn = 'com-mid1'                     THEN 'Unknown'
  WHEN hn = 'lsicamgos1'                   THEN 'Camera_CCTV'
  WHEN hn = 'ipadmini'                     THEN 'Mobile_Tablet'

  /* Brand/feature patterns */
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'^roborock')
                                           THEN 'IoT_SmartHome'
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])roborock[-_ ]?vacuum([^a-z0-9]|$)')
                                           THEN 'IoT_SmartHome'
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])nomi[-_ ]?ipc([^a-z0-9]|$)')
                                           THEN 'Camera_CCTV'
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])tizenrt([^a-z0-9]|$)')
                                           THEN 'IoT_SmartHome'
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'smart[ _-]?cat[ _-]?litter[ _-]?box')
                                           THEN 'IoT_SmartHome'


  /* “Unknown” overrides */
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])yunos-[a-z0-9]+([^a-z0-9]|$)')
                                           THEN 'Unknown'
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])wlan0([^a-z0-9]|$)')
                                           THEN 'Unknown'

  /* iPad mini variants (token-safe) */
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])ipad[-_ ]?mini([^a-z0-9]|$)')
                                           THEN 'Mobile_Tablet'

  /* keep falling through to your existing rules below... */


/* ===== OVERRIDES: exacts & a contains rule (place before generic rules) ===== */

-- Exact hostnames → Mobile_Smartphone
WHEN hn IN (
  'ady-al00',
  'lio-an00',
  'hbn-al00',
  'nx729j',
  'mi-note-10-pro',
  'mi-note-10',
  'note10',
  'note3-gaming'
) THEN 'Mobile_Smartphone'

-- Exact → Mobile_Tablet
WHEN hn = 'mro-w09' THEN 'Mobile_Tablet'

-- Contains "electrolux" anywhere → IoT_SmartHome
-- (covers things like electrolux_appliance, electrolux-xxx, etc.)
WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'electrolux') THEN 'IoT_SmartHome'
	    
	    
	    
/* ===== OVERRIDES (place near top of CASE, before generic rules) ===== */

-- Exact matches
WHEN hn = 'honor'         THEN 'Mobile_Smartphone'
WHEN hn = 'aln-al80'      THEN 'Mobile_Smartphone'
WHEN hn = 'bt-speaker'    THEN 'IoT_SmartHome'
WHEN hn = 'hi3798mv200'   THEN 'TV_BOX'
WHEN hn = 'note3-gaming2' THEN 'Mobile_Smartphone'
WHEN hn = 'dby2-l09'      THEN 'Mobile_Tablet'
WHEN hn = 'z2351n'        THEN 'Mobile_Smartphone'
WHEN hn = 'alt-al10'      THEN 'Mobile_Smartphone'
WHEN hn = 'mrdi-w09'      THEN 'Mobile_Tablet'
WHEN hn = 'sweeper'       THEN 'IoT_SmartHome'
WHEN hn = '25028pc03g'    THEN 'Mobile_Smartphone'
WHEN hn = 'i2212'         THEN 'Mobile_Smartphone'

-- Patterns (token/word-boundary aware)


	    
	    
	/* ===== OVERRIDES FOR "OTHER" HOSTNAMES (paste near top of CASE) ===== */

-- Exact strings
WHEN hn = 'l530'           THEN 'IoT_SmartHome'
WHEN hn = 'hmd-arc'        THEN 'Mobile_Smartphone'
WHEN hn = '8196g'          THEN 'Mobile_Tablet'
WHEN hn = 'z2465n'         THEN 'Mobile_Smartphone'
WHEN hn = 'k12'            THEN 'IoT_SmartHome'
WHEN hn = 'tcl'            THEN 'Mobile_Smartphone'     -- per your mapping
WHEN hn = 'mi8lite-mi8lite' THEN 'Mobile_Smartphone'
WHEN hn = 'mimax3-mimax3'  THEN 'Mobile_Smartphone'
WHEN hn = 'p105'           THEN 'IoT_SmartHome'
WHEN hn = 'skg'            THEN 'IoT_SmartHome'
WHEN hn = 'v1818ca'        THEN 'Mobile_Smartphone'
WHEN hn = 'ctr-l81'        THEN 'Mobile_Smartphone'
WHEN hn = 'ags5-l09'       THEN 'Mobile_Tablet'
WHEN hn = 're450'          THEN 'MESH_WIFI'
WHEN hn = 'steamdeck'      THEN 'Mobile_Tablet'
WHEN hn = 'hmd-pulse'      THEN 'Mobile_Smartphone'
WHEN hn = 't612b'          THEN 'Mobile_Smartphone'
WHEN hn = 're200'          THEN 'MESH_WIFI'
WHEN hn = 'hi10-xpro'      THEN 'Mobile_Tablet'
WHEN hn = 'archer c20'     THEN 'MESH_WIFI'
WHEN hn = 'i10pro'         THEN 'Mobile_Tablet'
WHEN hn = 'i10-pro'        THEN 'Mobile_Tablet'
WHEN hn = 'nx769j'         THEN 'Mobile_Smartphone'
WHEN hn = 't509k'          THEN 'Mobile_Smartphone'
WHEN hn = 'dbr-w19'        THEN 'Mobile_Tablet'
WHEN hn = 'dbr-w09'        THEN 'Mobile_Tablet'
WHEN hn = 'x96pro'         THEN 'Mobile_Smartphone'

-- Pattern families
-- 25028rn03a (2 + 7–8 digits + optional 1–2 letters) and similar Xiaomi codes
WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|\\b)2[0-9]{7,8}[a-z]{0,2}($|\\b)')
THEN 'Mobile_Smartphone'

-- rmx2189 family (realme): rmx + 4 digits
WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|\\b)rmx[0-9]{4}($|\\b)')
THEN 'Mobile_Smartphone'

-- c530ws pattern family → c###ws
WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|\\b)c[0-9]{3}ws($|\\b)')
THEN 'Camera_CCTV'

-- re650 and friends → re + 3 digits (optionally ends with x)
WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|\\b)re[0-9]{3}x?($|\\b)')
THEN 'MESH_WIFI'

	    
	    /* ===== New pattern rules (as requested) ===== */

    -- 1) 'dbx' → IoT_SmartHome
    WHEN hn = 'dbx'
    THEN 'IoT_SmartHome'



    -- 3) contains 'iplay' → Mobile_Tablet
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'iplay')
    THEN 'Mobile_Tablet'

    -- 4) 'apples-mbp' or 'dell' → PC_Laptop
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'apples?-mbp|(^|[^a-z0-9])dell([^a-z0-9]|$)')
    THEN 'PC_Laptop'

    -- 5) contains 'iqoo' → Mobile_Smartphone
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'iqoo')
    THEN 'Mobile_Smartphone'

    -- 6) exact 'mi-note-10-lite' → Mobile_Smartphone
    WHEN hn = 'mi-note-10-lite'
    THEN 'Mobile_Smartphone'

    -- 7) exact 'c320ws' → Camera_CCTV
    WHEN hn = 'c320ws'
    THEN 'Camera_CCTV'

    -- 8) contains 'itel' → Mobile_Smartphone
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])itel([^a-z0-9]|$)')
    THEN 'Mobile_Smartphone'

    -- 9) contains 'bulb' or 'airfryer' or 'lge_air2' → IoT_SmartHome
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'bulb|airfryer|lge[_-]?air2')
    THEN 'IoT_SmartHome'

    -- 10) models like mao-lx9, mna-lx9, noh-nx9, bne-lx1 → Mobile_Smartphone
    --     (specifics + a general fallback for 3 letters, hyphen, 2 letters + 1 digit)
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(mao-lx9|mna-lx9|noh-nx9|bne-lx1|\b[a-z]{3}-[a-z]{2}[0-9]\b)')
    THEN 'Mobile_Smartphone'

    -- 11) 'view4 lite' (with optional space/underscore/hyphen) → Mobile_Smartphone
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'view4[ _-]?lite')
    THEN 'Mobile_Smartphone'
    
	    
	-- ob-628 anywhere → Mobile_Smartphone (catch exact or with prefixes/suffixes)
    WHEN hn = 'ob-628' OR hn LIKE '%ob-628%'
    THEN 'Mobile_Smartphone'
	    
	    /* ---------- Additional rules ---------- */

    -- 1) localhost / msi / lenovo / hp / admin / pc  → PC_Laptop
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])(localhost|msi|lenovo|hp|admin|pc)([^a-z0-9]|$)')
    THEN 'PC_Laptop'

    -- 2) contains 'samsung' → Mobile_Smartphone
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'samsung')
    THEN 'Mobile_Smartphone'

    -- 3) c### pattern (exactly 3 digits), e.g., c123 → Camera_CCTV
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '\bc[0-9]{3}\b')
    THEN 'Camera_CCTV'

    -- 4) contains 'repeater' → CPE_Router
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'repeater')
    THEN 'MESH_WIFI'

    -- 5) TV/STB (FIXED to catch aisplaybox/beyondtv and looser tv/box)
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(
      hn,
      '(aisplaybox|chromecast|opidtv|tv[-_ ]?box|set[-_ ]?top[-_ ]?box|\btv[-_ ]?box\b|\bbox\b)'
    )
    THEN 'TV_BOX'
	WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(beyondtv|androidtv|lgwebostv|webostv|mitv|smarttv|\btv\b)'
	)
    THEN 'TV'
     /* ---------- Specific rules requested ---------- */



    -- 2) contains 'camera' → Camera/CCTV
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'camera')
    THEN 'Camera_CCTV'

    -- 3) 'mac' token → PC/Laptop
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])mac([^a-z0-9]|$)')
    THEN 'PC_Laptop'

    -- 5) contains 'acer' → PC_Laptop
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'acer')
    THEN 'PC_Laptop'

    -- 6) z-fold / z-flip → Smartphone
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'z[-_ ]?fold|z[-_ ]?flip')
    THEN 'Mobile_Smartphone'




	WHEN hn IS NULL THEN 'NULL'
	
	    /* ======= ADD-ON: explicit labels for top HN values ======= */

    -- Camera / CCTV
    WHEN hn IN (
      'ipc','ipc365'
    ) THEN 'Camera_CCTV'

    -- IoT / Smart Home (SoC/OS/speakers/home devices)
    WHEN hn IN (
      'espressif','rtthread','google-nest-mini','levoit-purifier','wilc','dgiot',
      'mxchip','tesla','sonoszp','ttc-com-nb66','jbl','audiocast','homepod'
    ) THEN 'IoT_SmartHome'

    -- TV / Set-top / Console (adjusted: com-mid1 → TV_STB)
    WHEN hn IN (
      'coolita'
    ) THEN 'TV'
	
	    WHEN hn IN (
      'xbox'
    ) THEN 'TV_BOX'

    -- CPE / Routers & Extenders
    WHEN hn IN (
      're305','re205','mw300re','miwifi-rd10m'
    ) THEN 'MESH_WIFI'

    -- Mobile / Tablet (Wi-Fi or LTE variants)
    WHEN hn IN (
      'btkr-w09','dby-w09','btk-w09','btk-al09','bky-w09','ags5-w09','t506t','t20','tgr-w09'
    ) THEN 'Mobile_Tablet'

    -- Mobile / Smartphone (explicit model strings & brands)
    WHEN hn IN (
      'm2103k19g','21081111rg','xiaomi','m2010j19sg','21061119ag','i2218','m2004j19c',
      'm2007j3sg','m2101k6g','narzo-50i','21051182g','m2101k7ag','y82','2109119dg',
      'z2453','m2101k7bg','sunny5','2107113sg','mi-10t-pro','s1a','s6518','i2219',
      'm2003j15sc','23129rn51x','z2352n','z6','klxng-thiwi-xiaomi','jln-lx1',
      'm2012k11ag','i2405','m2102j20sg','i2216','i2401','i2220','m2007j20ct',
      'sunny5 lite','mi-10t','narzo-50','benco-v91','nam-lx9','i2213','m2101k9ag',
      'z2467','nubia-8150n','z2353','z2450','z2350','nothing-phone-2a',
      'm2007j22g','jad-lx9','mi-11-lite','rog-phone6','aln-al00','android'
    ) THEN 'Mobile_Smartphone'

    -- Other (labels/user-defined/rooms/misc)
    WHEN hn IN (
      'ob-628','dbx','xtc_d2','user','living-room','bedroom','p','d1'
    ) THEN 'Other'
	
	
	    /* ===== NEW PATTERN RULES ===== */

    -- 'phone' anywhere → Mobile_Smartphone  (covers ...phone, smartphone, etc.)
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'phone')
    THEN 'Mobile_Smartphone'



    -- 4) mxxxxxxx models (e.g., m2007j3sy, m2101k7ag, m2101k6g) → Mobile_Smartphone
    --    allow 7–9 trailing [a-z0-9] to cover common Xiaomi/Realme model patterns
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '\bm[0-9a-z]{7,9}\b')
    THEN 'Mobile_Smartphone'

    -- 5) 'mi-xx' (e.g., mi-11, mi-10t) → Mobile_Smartphone
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '\bmi[-_ ]?[0-9]{1,3}\b')
    THEN 'Mobile_Smartphone'

    -- 5b) contains 'benco' → Mobile_Smartphone
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'benco')
    THEN 'Mobile_Smartphone'


    -- 7) contains 'pixel' → Mobile_Smartphone
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'pixel')
    THEN 'Mobile_Smartphone'

    -- 'admin' anywhere → PC_Laptop  (handles admin, administrator, admins-*)
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'admin')
    THEN 'PC_Laptop'

    -- also catch 'computer' explicitly → PC_Laptop
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'computer')
    THEN 'PC_Laptop'

    -- 9) contains 'narzo' → Mobile_Smartphone
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'narzo')
    THEN 'Mobile_Smartphone'

    -- 10) 2xxxxxx patterns like 21061110ag, 21081111rg → Mobile_Smartphone
    --     start with '2', 7–8 digits, optional 1–2 trailing letters
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '\b2[0-9]{7,8}[a-z]{0,2}\b')
    THEN 'Mobile_Smartphone'



    -- 12) contains 'epson' → IoT_SmartHome
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'epson')
    THEN 'IoT_SmartHome'


  /* ------------------------------------------------------------------
     YOUR ORIGINAL RULES (leave these exactly as you have them)
     ------------------------------------------------------------------ */

  -- 📱 Smartphone
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,
    '(iphone|ios|galaxy-|sm-[a-z0-9]+|s[0-9]{2}-|a[0-9]{2}|oppo|vivo|realme|redmi|xiaomi-|poco|huawei_|mate|nova|honor-|oneplus|infinix|tecno|nokia|asus|lenovo-|moto|meizu|zte-|yunos)'
  ) THEN 'Mobile_Smartphone'

  -- 📲 Tablet
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,
    '(ipad|galaxy-tab|tab-|mediapad|matepad|mi[-_ ]?pad|xiaomi-pad)'
  ) THEN 'Mobile_Tablet'

  -- 💻 PC/Laptop
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,
    '(desktop-|laptop-|macbook|macmini|win7|win-)'
  ) THEN 'PC_Laptop'

  -- 📺 TV 
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,
    '(lgwebostv|smart[ _]?tv|mitv|androidtv|tizen)'
  ) THEN 'TV'
    -- 📺 Set-top
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,
    'opidtv'
  ) THEN 'TV_BOX'

  -- 📷 Camera/CCTV
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,
    '(opipc|nomi-ipc|chuangmi|ipc-|ipcam|ezviz|c6n_|c510w|c20[0-9]|c520ws)'
  ) THEN 'Camera_CCTV'

  -- 🏠 IoT / Smart Home + Smart Appliances
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,
    '(xiaomi_vacuum|roborock|dreame_vacuum|esp[_-]|esp32|yeelink|zhimi|petkit|google-home|qca4002|lwip|gecko_os|bouffalolab|blackvue|washer|dryer|fridge|refrigerator|microwave|aircon)'
  ) THEN 'IoT_SmartHome'

  -- 📶 CPE / Router
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,
    '(opmesh|opx-node|gwipc-|net_|wlan0|sky000|opmesh_)'
  ) THEN 'MESH_WIFI'

  -- ⌚ Wearable
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(watch|imoo-)')
  THEN 'Wearable'
  
      -- 'pad' anywhere → Mobile_Tablet  (handles giantpad, ipad, matepad, mi pad)
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'pad')
  THEN 'Mobile_Tablet'
  
      -- 'cam' anywhere → Camera_CCTV  (catches ipcam, qcam, cam-xxx, camera)
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'cam')
    THEN 'Camera_CCTV'
	
    -- 8) contains 'mesh' → CPE_Router
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'mesh')
    THEN 'MESH_WIFI'
	
	    -- 4) contains 'watch' → Wearable
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'watch')
    THEN 'Wearable'
    
        -- 6) IoT_SmartHome (FIXED to include fan + robot; smart* but not smartphone)
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'smart(?!phone)[-_a-z0-9]*|(^|[^a-z0-9])fan([^a-z0-9]|$)|robot')
    THEN 'IoT_SmartHome'

  -- ❓ Unknown
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,
    '(\[null\]|^unknown$|^n/a$|localhost|^mac$|([0-9a-f]{2}:){5}[0-9a-f]{2})'
  ) OR hn IS NULL
  THEN 'Unknown'
  
  -- a + 1–3 digits (e.g., a9, a50, a70); optional year suffix like -2020
-- (covers your "a9" and general 'aX' number family as Mobile_Smartphone)
WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|\\b)a[0-9]{1,3}([_-]20[0-9]{2})?($|\\b)')
THEN 'Mobile_Smartphone'

-- i + 4 digits (e.g., i2212, i2218, i2401) → Mobile_Smartphone
WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|\\b)i[0-9]{4}($|\\b)')
THEN 'Mobile_Smartphone'

    -- 2) 's' + single digit token (e.g., s1, s9) → Mobile_Smartphone
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])s[0-9]([^a-z0-9]|$)')
    THEN 'Mobile_Smartphone'
	
    -- 1) v#### models → Smartphone
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '\bv[0-9]{4}\b')
    THEN 'Mobile_Smartphone'

    -- 7) contains 'book' → PC_Laptop
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'book')
    THEN 'PC_Laptop'

        ELSE 'Other'
      END AS DEVICE_GROUP
  FROM base a
)
DISTRIBUTE ON (MNTH_ID, CIRCUIT, WIFI_STA_INFORMATION_HOSTNAME);



/* ============================================================
   E) FINAL FLAGS (NEW ORDER) — INDI
   ============================================================ */
-- New flag split active_days and Connecttime
DROP TABLE TEMP_CURCUIT_DATA_AGG_FLAG_INDI IF EXISTS;

CREATE TEMP TABLE TEMP_CURCUIT_DATA_AGG_FLAG_INDI AS

SELECT
     B.MNTH_ID
    ,B.CIRCUIT

    /* USE CANONICAL WHERE AVAILABLE; OTHERWISE THE CLEANED HOSTNAME */
    ,COALESCE(M.WIFI_STA_INFORMATION_HOSTNAME_CANON, B.WIFI_STA_INFORMATION_HOSTNAME)
      AS WIFI_STA_INFORMATION_HOSTNAME

    ,B.ACTIVE_DAYS
    ,B.CONNECTTIME
    ,B.DEVICE_GROUP

    /* PRIORITY (TOP-DOWN):
       1) DUPLICATE (NON-CANONICAL)
       2) ACTIVE_DAYS = 0 OR CONNECTTIME = 0
       3) ACTIVE_DAYS < 2
       4) CONNECTTIME < 30000
       5) REMAIN
    */
    ,CASE
      WHEN D.CIRCUIT IS NOT NULL THEN 1
	  WHEN B.DEVICE_GROUP IN ('MESH_WIFI','IoT_SmartHome','Camera_CCTV','TV','TV_BOX') THEN 5
      WHEN COALESCE(B.ACTIVE_DAYS,0) = 0 OR COALESCE(B.CONNECTTIME,0) = 0 THEN 2
      WHEN B.ACTIVE_DAYS < 2 THEN 3
      WHEN B.CONNECTTIME < 30000 THEN 4
      ELSE 5
    END AS FLAG

FROM TEMP_CURCUIT_DEVICE_DETAIL_INDI B
LEFT JOIN MAP_HOST_CANON_INDI M
  ON M.MNTH_ID = B.MNTH_ID
 AND M.CIRCUIT = B.CIRCUIT
 AND M.WIFI_STA_INFORMATION_HOSTNAME_CLEAN = B.WIFI_STA_INFORMATION_HOSTNAME
LEFT JOIN TMP_DUP_HOSTS_INDI D
  ON D.MNTH_ID = B.MNTH_ID
 AND D.CIRCUIT = B.CIRCUIT
 AND D.WIFI_STA_INFORMATION_HOSTNAME_CLEAN = B.WIFI_STA_INFORMATION_HOSTNAME
DISTRIBUTE ON (MNTH_ID, CIRCUIT, WIFI_STA_INFORMATION_HOSTNAME);



/* ============================================================
   F) FILTER ONLY HOUSE DEVICE 
   ============================================================ */
DROP TABLE TEMP_CURCUIT_DATA_HOUSE_DEVICE IF EXISTS;

CREATE TEMP TABLE TEMP_CURCUIT_DATA_HOUSE_DEVICE AS

SELECT 
	 MNTH_ID
	,CIRCUIT
	,WIFI_STA_INFORMATION_HOSTNAME
	,ACTIVE_DAYS
	,CONNECTTIME
	,DEVICE_GROUP
FROM TEMP_CURCUIT_DATA_AGG_FLAG_INDI
WHERE FLAG = 5
DISTRIBUTE ON (MNTH_ID, CIRCUIT, WIFI_STA_INFORMATION_HOSTNAME);


/* ============================================================
   PUT ON THE DEVICE BRAND GROUP FOR ALL DEVICE
   ============================================================ */
DROP TABLE TEMP_CURCUIT_DATA_DEVICE_BRAND IF EXISTS;

CREATE TEMP TABLE TEMP_CURCUIT_DATA_DEVICE_BRAND AS

SELECT 
	 MNTH_ID
	,CIRCUIT
	,WIFI_STA_INFORMATION_HOSTNAME AS HN
	,ACTIVE_DAYS
	,CONNECTTIME
	,DEVICE_GROUP
	, CASE
    /* --- Mobile_Smartphone --- */
    WHEN device_group = 'Mobile_Smartphone' THEN
      CASE
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(iphone|ios)') THEN 'Apple'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^(oppo|cph[0-9]+|reno|find)') THEN 'OPPO'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(\bvivo\b|vivo-|v[0-9]{4}\b|^vivo|s1|z6)|v1818ca') THEN 'vivo'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^(realme|rmx[0-9]{4}\b|narzo)') THEN 'realme'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(\bredmi\b|redmi-|^redmi|23129rn51x)') THEN 'Xiaomi'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(\bpoco\b|poco-)') THEN 'Xiaomi'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(xiaomi|xiaomi-|xiaomi_|mi[-_ ]?[0-9]{1,3}\b|m[0-9]{4}[a-z0-9]{3,}\b|20[0-9]{6,}[a-z]{0,2}\b|^mi)|pocophonef1-pocophon') THEN 'Xiaomi'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(LOWER(hn), '(^|\\b)2[0-9]{7,8}[a-z]{1,2}($|\\b)') THEN 'Xiaomi'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(huawei_|huawei-|jln-lx1|jad-lx9)|ady-lx9|noh-nx9|mao-lx9|bne-lx1|nam-lx9|alt-al10|lio-an00|aln-al80|blk-lx9|aln-al00|mna-lx9|ctr-l81|hbn-al00') THEN 'HUAWEI'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^honor|honor-)') THEN 'HONOR'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(oneplus)') THEN 'OnePlus'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(infinix)') THEN 'Infinix'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(tecno)') THEN 'TECNO'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(nokia)') THEN 'Nokia'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(asus|zenfone|rog-phone|^rog)') THEN 'ASUS'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(lenovo-|lenovo_)') THEN 'Lenovo'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(moto|motorola)') THEN 'Motorola'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(meizu)') THEN 'Meizu'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(zte-)|nx729j') THEN 'ZTE'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(pixel-|google-?pixel)') THEN 'Google'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^nothing-phone') THEN 'Nothing'
        WHEN LOWER(hn) LIKE '%nothing-phone%' THEN 'Nothing'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^benco') THEN 'Benco'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^iqoo') THEN 'iQOO'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^itel') THEN 'Itel'
        WHEN hn = 'ob-628' THEN 'Altron'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^view|^sunny)|y82|t20') THEN 'Wiko'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(LOWER(hn), '(^|[^a-z0-9])i[0-9]{4}([^a-z0-9]|$)') THEN 'iQOO'
        WHEN hn IN ('2109119dg','2107113sg','23129rn51x','' ) THEN 'Xiaomi'
        WHEN LOWER(hn) = 's1a' THEN 'BRAND_A'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(LOWER(hn), '(^|[^a-z0-9])z[0-9]{3,5}([^a-z0-9]|$)|z2351n|nx769j') THEN 'ZTE'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(LOWER(hn), 'nubia|z2352n|z2465n') THEN 'ZTE'
        WHEN LOWER(hn) = 's6518' THEN 'AIS'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(LOWER(hn), 'android') THEN 'Android'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(LOWER(hn), 'tcl|t612b|t506t|t509k|z2351n') THEN 'TCL'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(samsung|galaxy-|sm-|z-fold|z-flip|s[0-9]{2}-|a[0-9]{2}\b|note[0-9]*|note-)|a05s|s9|a20ultra|a04s|a9') THEN 'Samsung'
        WHEN LOWER(TRIM(hn)) = 'ac79nn'                 THEN 'OPPO'
  		WHEN LOWER(TRIM(hn)) IN ('smart_4g_adventure_pro','smart_4g_p1','smart_4g_p1_prime') THEN 'BRAND_A'
  		WHEN LOWER(TRIM(hn)) = '<DEVICE_ID_2>' THEN 'Android'
  		WHEN LOWER(TRIM(hn)) = 'blackpearl2'           THEN 'Ninetology'
  		WHEN NZ_MART.ADMIN.REGEXP_LIKE(LOWER(hn), '^yi-jia') THEN 'Yijia'
  		WHEN NZ_MART.ADMIN.REGEXP_LIKE(
       LOWER(hn),
       '^a(0[0-9]|[1-9][0-9])s-khxng-[a-z0-9_-]+'
     )
THEN 'Samsung'
		WHEN NZ_MART.ADMIN.REGEXP_LIKE(LOWER(hn), '^hmd') THEN 'HMD'
		-- Huawei model codes ending with -lx1 / -lx2 / -lx3 / -lx9  (e.g., pal-lx9, any-lx2, nco-lx1)
WHEN NZ_MART.ADMIN.REGEXP_LIKE(
       LOWER(hn),
       '[-_]lx(1|2|3|9)($|[^a-z0-9])'
     )
THEN 'HUAWEI'
	WHEN NZ_MART.ADMIN.REGEXP_LIKE(LOWER(hn), 'x96pro') THEN 'DOOGEE'
	WHEN NZ_MART.ADMIN.REGEXP_LIKE(LOWER(hn), 'yunos') THEN 'Yunos'

        ELSE 'Other/Unmapped'
      END
  

    /* --- Mobile_Tablet --- */
    WHEN device_group = 'Mobile_Tablet' THEN
      CASE
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'ipad') THEN 'Apple'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(galaxy-tab|tab-[a-z0-9]+)') THEN 'Samsung'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(mediapad|matepad|dby-w09|btk-al09)') THEN 'HUAWEI'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(xiaomi-pad|mi[-_ ]?pad)') THEN 'Xiaomi'
      /* OPPO tablets */
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])oppo-pad(?![^a-z0-9]*phone)') THEN 'OPPO'
        /* HONOR tablets (English + some CN aliases) */
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])honor-pad([^a-z0-9]|$)|(^|[^a-z0-9])rong-yao-ping-ban|pad-13|pad-10') THEN 'HONOR'
        /* Xiaomi family tablets (Xiaomi/Redmi/POCO) */
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'xiaomi-pad|(^|[^a-z0-9])mi[-_ ]?pad([^a-z0-9]|$)') THEN 'Xiaomi'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])redmi[-_ ]?k[-_ ]?pad([^a-z0-9]|$)') THEN 'Xiaomi'
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])poco[-_ ]?pad([^a-z0-9]|$)') THEN 'Xiaomi'

    /* realme tablets */
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])realme-pad([^a-z0-9]|$)') THEN 'realme'

    /* HUAWEI tablets: MediaPad/MatePad + common model codes */
       WHEN NZ_MART.ADMIN.REGEXP_LIKE(
         hn,
           '(^|[^a-z0-9])(mediapad|matepad|ags[0-9]-[wl]09|btk[ar]?-[wl]09|bky-w09|tgr-w09|dby2?-l09|mrdi-w09|mro-w09|dbr-w(09|19))([^a-z0-9]|$)'
         )
        THEN 'HUAWEI'
    /* vivo tablets */
       WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])vivo-pad([^a-z0-9]|$)') THEN 'vivo'

    /* OnePlus tablets */
        WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])oneplus-pad([^a-z0-9]|$)') THEN 'OnePlus'
 
    /* Lenovo tablets (ThinkPad/IdeaPad/Xiaoxin Pad) */
       WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(thinkpad|ideapad|xiao[-_ ]?xinpad|lenovoideapad)' ) THEN 'Lenovo'
       
     /* Alldocube iPlay series */
      WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])iplay(50|40|60|20|[-_ ]?mini|[-_ ]?pro)?') THEN 'Alldocube'
       
       /* GIANTPAD, MIXPAD, KPAD, etc. brand-like tokens */
       WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])giant[-_ ]?pad|(^|[^a-z0-9])giantpad') THEN 'GiantPad'
       
       WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '8196g') THEN 'TCL'
       
       /* Infinix */
       WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])infinix[-_ ]?xpad([^a-z0-9]|$)') THEN 'Infinix'
       
           /* CHUWI / Teclast / misc China tablets (best-effort) */
       WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])hi10[-_ ]?x?pro?([^a-z0-9]|$)') THEN 'CHUWI'
       WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])t20([^a-z0-9]|$)') THEN 'Teclast'
           /* Orvibo MixPad (smart panel; keep as Orvibo for clarity) */
       WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])orvibo[_-]?mixpad([^a-z0-9]|$)') THEN 'Orvibo'
           /* Valve (Steam Deck sometimes lands in Tablet bucket) */
       WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])steamdeck([^a-z0-9]|$)') THEN 'Valve'
       WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'i10pro|i10-pro') THEN 'BMAX'
       WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^dengo') THEN 'Dengo'
       WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'propadp1') THEN 'Wealthy'
        ELSE 'Other/Unmapped'
      END
  
 /* --- TV_STB --- */
        WHEN device_group = 'TV' THEN
          CASE

            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(mi[-_ ]?box|mi[-_ ]?tv[-_ ]?stick|xiaomi[-_ ]?tv[-_ ]?box|xiaomi[-_ ]?tv|mi[-_ ]?tv)|mi-xupkrn-cheuxm-tx-tv') THEN 'Xiaomi'
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])beyondtv2?([^a-z0-9]|$)') THEN 'BeyondTV'
        
            /* ===== TV brands / OS families ===== */
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])lg[ _-]?webos[ _-]?tv([^a-z0-9]|$)|(^|\[lg\]\s*)webos[ _-]?tv|^lg|lgwebosit') THEN 'LG'
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])tizen([^a-z0-9]|$)') THEN 'Samsung'
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])tcl[ .-]?tv([^a-z0-9]|$)|^tcl\.tv$') THEN 'TCL'
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])toshiba[-_ ]?cast[-_ ]?tv([^a-z0-9]|$)') THEN 'Toshiba'
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])coolita([^a-z0-9]|$)') THEN 'Coolita (Skyworth/Coocaa)'
 
            /* ===== Generic Android/Smart TV (catch-all before Other) =====
               - handles "android tv", "android-tv", "android tv" (NBSP), "smart tv", "google tv"
            */
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(android\\s*[-_]?\\s*tv|smart[ _]?tv|android tv|^android)') THEN 'Other/Unmapped'
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(google[ _]?tv)') THEN 'Google TV'
        	WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])x1[-_ ]ultimate([^a-z0-9]|$)') THEN 'Sony'
            /* ===== Everything else ===== */
            ELSE 'Other/Unmapped'
          END
 
/* --- TV_STB --- */
        WHEN device_group = 'TV_BOX' THEN
          CASE
            /* ===== Specific platforms / devices (highest priority) ===== */
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])apple[-_ ]?tv([^-a-z0-9]|$)|^apple') THEN 'Apple TV'
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'chromecast|google[-_ ]?tv|chromecast[-_ ](ultra|hd|4k)|chromecast[-_ ]with[-_ ]google?tv') THEN 'Google Chromecast'
        	WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'opidtv|opid[-_ ]?tv[-_ ]?box') THEN 'OpTV'
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])aisplaybox([^a-z0-9]|$)') THEN 'AIS Playbox'
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])nokia[-_ ]streaming[-_ ]box([^a-z0-9]|$)') THEN 'Nokia Streaming Box'
            /* ===== Common generic Android boxes ===== */
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])x96pro([^a-z0-9]|$)') THEN 'X96 Android Box'
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])hi3798mv200([^a-z0-9]|$)') THEN 'HiSilicon-based Box'
            WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])xbox([^a-z0-9]|$)') THEN 'Microsoft Xbox'
			
            ELSE 'Other/Unmapped'
          END 
 
 
 /* --- Camera_CCTV --- */
WHEN device_group = 'Camera_CCTV' THEN
  CASE
    /* ===== Oper / Operator-branded ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])opx-node-sc201([^a-z0-9]|$)') THEN 'BRAND_A'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'opipc') THEN 'BRAND_A'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'nomi-ipc') THEN 'NOMI'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'ezviz|c6n_') THEN 'EZVIZ'

    /* ===== Xiaomi ecosystem ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])chuangmi([^a-z0-9]|$)|mijia_camera_v3|(^|[^a-z0-9])mijia[_-]camera([^a-z0-9]|$)') THEN 'Xiaomi'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])xiaovv[-_ ]camera([^a-z0-9]|$)') THEN 'Xiaomi'

    /* ===== TP-Link Tapo (cxxx / cxxxws common SKUs) ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(
           hn,
           '(^|[^a-z0-9])c(100|110|200|210|211|212|213|216|225|230|260|300|310|320ws|410|425|500|530ws)([^a-z0-9]|$)|c220|c200c|c520ws'
         )
    THEN 'TP-Link_Tapo'

    /* ===== Google / Nest ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])nest[-_ ]?cam([^a-z0-9]|$)') THEN 'Google_Nest'

    /* ===== Wyze ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])wyze[_-]cam([^a-z0-9]|$)') THEN 'Wyze'

    /* ===== 360 brand (Qihoo 360) ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])360[_-]?camera([^a-z0-9]|$)') THEN '360'

    /* ===== MXIANG lines ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])mxiang[._-]camera([^a-z0-9]|$)') THEN 'MXIANG'

    /* ===== JD / ISA camera lines ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])jd[_-]camera([^a-z0-9]|$)')  THEN 'JD_Camera'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])isa[_-]camera([^a-z0-9]|$)') THEN 'Other/Unmapped'

    /* ===== QCAM / generic IPC tokens ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])qcam([^a-z0-9]|$)') THEN 'QCAM'
    
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'c510w|ipc-a22e-d') THEN 'IMOU'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'ipc-|ipcam|ipc|ipc365|ip camera') THEN 'Other/Unmapped'

    /* ===== Fallback ===== */
    ELSE 'Other/Unmapped'
  END
      
/* --- IoT_SmartHome --- */
WHEN device_group = 'IoT_SmartHome' THEN
  CASE
	  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^marshall') THEN 'Marshall'
    /* ===== Xiaomi ecosystem / partners ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])(xiaomi_vacuum|yeelink|zhimi|imilab[-_ ]smart[-_ ]hub)([^a-z0-9]|$)')
      THEN 'Xiaomi'
    /* Xiaomi/Dmaker fan SKUs often show as dmaker-... */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])dmaker[-_ ]?fan([^a-z0-9]|$)')
      THEN 'Xiaomi'

    /* ===== Robotic vacuums & cleaners ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])roborock([^a-z0-9]|$)|rockrobo')    THEN 'Roborock'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'^roborock')
                                           THEN 'Roborock'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])dreame[_-]vacuum([^a-z0-9]|$)')
      THEN 'Dreame'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])(irobot|roomba)([^a-z0-9]|$)')
      THEN 'iRobot'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])narwalrobotics([^a-z0-9]|$)')
      THEN 'Narwal'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])(vacuum|sweeper|robot)([^a-z0-9]|$)')
      THEN 'Other/Unmapped'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'petkit') THEN 'Petkit'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'blackvue') THEN 'BlackVue'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'^smart cat litter box') THEN 'UBPet'

    /* ===== Smart speakers / audio ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])google[-_ ]nest[-_ ]mini([^a-z0-9]|$)')
      THEN 'Google'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])google[-_ ]home([^a-z0-9]|$)')
      THEN 'Google'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])homepod([^a-z0-9]|$)')
      THEN 'Apple_HomePod'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])sonoszp([^a-z0-9]|$)')
      THEN 'Sonos'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])bose[-_ ]smart([^a-z0-9]|$)|bose-portable-smart-speaker')
      THEN 'Bose_Smart'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])jbl([^a-z0-9]|$)')
      THEN 'JBL'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])audiocast([^a-z0-9]|$)')
      THEN 'AudioCast'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])bt[-_ ]speaker([^a-z0-9]|$)')
      THEN 'Other/Unmapped'

    /* ===== TP-Link Tapo (plugs, bulbs) ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])tapo[_-](smartplug|bulb)([^a-z0-9]|$)|l530|p105')
      THEN 'TP-Link_Tapo'

    /* ===== LG / Electrolux / Levoit / Tesla (appliances & HVAC) ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])(lg[_-]smart|lge_.*_open|lg[_-]webos|lg[_-]smart_)([^a-z0-9]|$)|lge_dhum2_open')
      THEN 'LG_SmartAppliance'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])electrolux([^a-z0-9]|$)')
      THEN 'Electrolux'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])levoit[-_ ](purifier|tower[_-]fan)([^a-z0-9]|$)')
      THEN 'Levoit'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])tesla([^a-z0-9]|$)')
      THEN 'Tesla'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'dbx')
      THEN 'DBX_Audio'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'k12')
      THEN 'K12_Audio'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'skg')
      THEN 'skg_Audio'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'renac_wifi')
      THEN 'Renac'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'aliosthings')
      THEN 'Other/Unmapped'  
    /* Generic “smart appliance” signals */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'washer|dryer|fridge|refrigerator|microwave')
      THEN 'Other/Unmapped'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])(aircon|ac)([^a-z0-9]|$)')
      THEN 'Other/Unmapped'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])airfryer([^a-z0-9]|$)')
      THEN 'Other/Unmapped'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'^smart scale')
      THEN 'Other/Unmapped'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'homemate_device')
      THEN 'Homemate'

    /* ===== Embedded modules / SDKs / IoT stacks ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])(espressif|esp32|esp[_-])([^a-z0-9]|$)|^esp')
      THEN 'Other/Unmapped'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])rtthread([^a-z0-9]|$)')
      THEN 'Other/Unmapped'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])mxchip([^a-z0-9]|$)')
      THEN 'Other/Unmapped'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])wilc([^a-z0-9]|$)')
      THEN 'Other/Unmapped'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])(qca4002|lwip|gecko_os|bouffalolab)([^a-z0-9]|$)|lwip0')
      THEN 'Other/Unmapped'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])dgiot([^a-z0-9]|$)')
      THEN 'Other/Unmapped'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'(^|[^a-z0-9])rk3308[_-]robot32([^a-z0-9]|$)')
      THEN 'Rockchip_Robot'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'^epson')
      THEN 'Epson'
      ELSE 'Other/Unmapped'
  END
/* --- CPE_Router --- */
WHEN device_group = 'MESH_WIFI' THEN
  CASE
    /* ===== Xiaomi repeaters / routers ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])xiaomirepeater(_v[0-9])?([^a-z0-9]|$)') THEN 'Xiaomi'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])miwifi([^a-z0-9]|$)') THEN 'Xiaomi'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])miwifi[-_ ]?rd[0-9a-z]+([^a-z0-9]|$)') THEN 'Xiaomi'

    /* ===== TP-Link RE-series extenders ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(
           hn,
           '(^|[^a-z0-9])re(190|200|205|210|215|220|300|305|315|330|355|450|500|505x|550|600|603x|605x|650|655|700x|705x|815x)([^a-z0-9]|$)|^tl-wa'
         ) THEN 'TP-Link'
    /* Archer routers (e.g., Archer C20) */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])archer[ _-]?c[0-9]+([^a-z0-9]|$)') THEN 'TP-Link'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^tl[-_]?wa|(^|[^a-z0-9])re[0-9]{3,4}x?($|[^a-z0-9])') THEN 'TP-Link'
    /* Deco mesh (e.g., “decomeshx50”) */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])deco(mesh)?x[0-9]+([^a-z0-9]|$)|(^|[^a-z0-9])decomeshx[0-9]+([^a-z0-9]|$)') THEN 'TP-Link'

    /* ===== Tenda (MW300RE etc.) ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])mw300re([^a-z0-9]|$)') THEN 'Tenda'

    /* ===== AVM FRITZ! ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])fritz[.]repeater([^a-z0-9]|$)') THEN 'AVM FRITZ!Repeater'

    /* ===== Raspberry Pi makeshift repeater ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])rpi[-_ ]repeater([^a-z0-9]|$)') THEN 'RaspberryPi'

    /* ===== Your existing buckets ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'opmesh|^opmesh') THEN 'OpMesh'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'opx-node') THEN 'OpX'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'gwipc-') THEN 'GWIPC'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn,'sky000') THEN 'SkyRouter'

    ELSE 'Other/Unmapped'
  END

      
/* --- PC_Laptop --- */
WHEN device_group = 'PC_Laptop' THEN
  CASE
    /* ===== Apple (Mac) ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, 'mac|macbook|macmini|(^|[^a-z0-9])(macbook|mac[-_ ]?mini|imac|mac[-_ ]?studio|mbp|macs[-_ ]?mac[-_ ]?mini|apples?[-_ ]?mbp|admins[-_ ]?(mbp|air|imac))([^a-z0-9]|$)')
      THEN 'Apple'
    WHEN LOWER(TRIM(hn)) IN (
    'imac','macs-mbp','macs-air','imacs-imac','macs-imac','apples-imac','macs-mbp-2',
    'macoss-mbp','users-imac','airkhxnacintosh','macoss-air','macairs-air','imacs-imac-2',
    'imacpro','applemacintosh2','macs-imac-2','imac-mbhmbk'
  ) THEN 'Apple'
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(
             LOWER(hn),
             '(^|[^a-z0-9])(macbook|mac[-_ ]?mini|imac|mac[-_ ]?studio|mbp|apple[-_ ]?macintosh|mac)([^a-z0-9]|$)'
           )
      THEN 'Apple'
  WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '^macbook') THEN 'Apple'
    /* ===== Dell / HP / Lenovo / ASUS / Acer / MSI / Fujitsu / NEC / Sony / Samsung / Compaq / Gigabyte / eMachines / Microsoft ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])dell([^a-z0-9]|$)') THEN 'Dell'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])hp([^a-z0-9]|$)|elitebook') THEN 'HP'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])(lenovo|thinkpad|ideapad)([^a-z0-9]|$)') THEN 'Lenovo'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])(asus|zenbook|vivobook)([^a-z0-9]|$)|^asus') THEN 'ASUS'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])(acer|aspire)([^a-z0-9]|$)|acer') THEN 'Acer'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])msi([^a-z0-9]|$)') THEN 'MSI'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])(fujitsu|lifebook)([^a-z0-9]|$)') THEN 'Fujitsu'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])nec([^a-z0-9]|$)') THEN 'NEC'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])(sony|vaio)([^a-z0-9]|$)') THEN 'Sony'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])samsung[-_ ]?pc([^a-z0-9]|$)') THEN 'Samsung'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])compaq([^a-z0-9]|$)') THEN 'Compaq'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])gigabyte([^a-z0-9]|$)') THEN 'Gigabyte'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])emachines([^a-z0-9]|$)') THEN 'eMachines'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])surface([^a-z0-9]|$)|surface|surfacepro6') THEN 'Microsoft Surface'

    /* ===== Infinix InBook (inbook_x1/x2/pro) ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])inbook[_-]x[12]([^a-z0-9]|$)') THEN 'Infinix InBook'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])inbook[_-]x1[_-]?pro([^a-z0-9]|$)') THEN 'Infinix InBook'

    /* ===== Toshiba / VAIO (legacy tokens included above; duplicate-safe) ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])toshiba([^a-z0-9]|$)') THEN 'Toshiba'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])matebook([^a-z0-9]|$)') THEN 'Huawei'

    /* ===== Generic Windows PC signals =====
       (localhost, admin, *-pc, computer, notebook, windows tokens, etc.) */
    -- put this BEFORE the generic Windows_PC catch-all
    WHEN hn LIKE 'desktop-%' OR hn LIKE 'laptop-%' THEN 'Other/Unmapped'

    WHEN NZ_MART.ADMIN.REGEXP_LIKE(
           hn,
           '(desktop-|laptop-|win7|win-|^|[^a-z0-9])(localhost(\\.localdomain)?|admin(istrator|s?)?(-pc)?|itadmin|user[-_ ]?pc|[a-z0-9_-]*-pc|pc(-[0-9]+)?|computer([0-9a-z_-]+)?|notebook|windows[0-9-]*|win7|win-)([^a-z0-9]|$)'
         )
      THEN 'Other/Unmapped'

    /* ===== Everything else in PC_Laptop ===== */
    ELSE 'Other/Unmapped'
  END
    
      
      
/* --- Wearable --- */
WHEN device_group = 'Wearable' THEN
  CASE
    /* ===== Apple Watch (applewatch, apple-watch, apple watch) ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])apple[-_ ]?watch([^a-z0-9]|$)')
      THEN 'Apple Watch'

    /* ===== Google Pixel Watch (v1/2/3) ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])(google[-_ ]?pixel[-_ ]?watch|pixel[-_ ]?watch)([-_ ]?[0-9]+)?([^a-z0-9]|$)')
      THEN 'Google Pixel Watch'

    /* ===== Samsung Galaxy Watch (future-proof) ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])galaxy[-_ ]?watch([^a-z0-9]|$)')
      THEN 'Samsung Galaxy Watch'

    /* ===== imoo kids watch (you already use this brand elsewhere) ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])imoo-')
      THEN 'Imoo'

    /* ===== Other popular wearables (optional but useful) ===== */
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])fitbit([^a-z0-9]|$)')
      THEN 'Fitbit'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])garmin([^a-z0-9]|$)')
      THEN 'Garmin'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])amazfit([^a-z0-9]|$)')
      THEN 'Amazfit'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])(huawei[-_ ]?watch)([^a-z0-9]|$)')
      THEN 'Huawei'
    WHEN NZ_MART.ADMIN.REGEXP_LIKE(hn, '(^|[^a-z0-9])(honor[-_ ]?(band|watch))([^a-z0-9]|$)')
      THEN 'Honor'
    /* ===== Fallback ===== */
    ELSE 'Other/Unmapped'
  END
  
    /* --- Unknown / Other --- */
    ELSE 'Unknown'
  END AS DEVICE_BRAND
FROM TEMP_CURCUIT_DATA_HOUSE_DEVICE 
DISTRIBUTE ON (MNTH_ID, CIRCUIT, HN);

/* ============================================================
   PUT ON CATEGORY FOR IOT DEVICE 
   ============================================================ */

DROP TABLE TEMP_CURCUIT_DATA_DEVICE_CAT IF EXISTS;

CREATE TEMP TABLE TEMP_CURCUIT_DATA_DEVICE_CAT AS
SELECT
     MNTH_ID
    ,CIRCUIT
    ,HN
    ,ACTIVE_DAYS
    ,CONNECTTIME
    ,DEVICE_GROUP
    ,DEVICE_BRAND
    /* Only categorize IoT_SmartHome; others stay NULL */
    ,CASE
      WHEN DEVICE_GROUP <> 'IoT_SmartHome' THEN NULL

      /* ===== Specific LG Smart Appliances first (very specific tokens) ===== */
      WHEN LOWER(HN) LIKE '%lg_smart_laundry2_open%'    THEN 'Washing Machine'
      WHEN LOWER(HN) LIKE '%lg_smart_dryer2_open%'      THEN 'Dryer'
      WHEN LOWER(HN) LIKE '%lg_smart_washtower2_open%'  THEN 'Washing Machine'
      WHEN LOWER(HN) LIKE '%lg_smart_fridge2_open%'     THEN 'Fridge'
      WHEN LOWER(HN) LIKE '%lg_smart_water2_open%'      THEN 'Water Purifier'
      WHEN LOWER(HN) LIKE '%lg_smart_handstick2_open%'  THEN 'Stick Vacuum'
      WHEN LOWER(HN) LIKE '%lge_air2_open%'             THEN 'Air Conditioner'
      WHEN LOWER(HN) LIKE '%lge_dhum2_open%'            THEN 'Dehumidifier'
      WHEN LOWER(HN) LIKE '%lge_ac2_open%'              THEN 'Air Conditioner'

      /* ===== Robot / Floor care ===== */
      WHEN LOWER(HN) LIKE '%roborock-wetdryvac%'        THEN 'Stick Vacuum'
      WHEN LOWER(HN) LIKE '%wetdryvac%'                 THEN 'Stick Vacuum'
      WHEN LOWER(HN) LIKE '%roborock-vacuum%'           THEN 'Robot Vacuum'
      WHEN LOWER(HN) LIKE '%dreame_vacuum%'             THEN 'Robot Vacuum'
      WHEN LOWER(HN) LIKE '%xiaomi_vacuum%'             THEN 'Robot Vacuum'
      WHEN LOWER(HN) LIKE '%rockrobo%'                  THEN 'Robot Vacuum'
      WHEN LOWER(HN) LIKE '%sweeper%'                   THEN 'Robot Vacuum'
      WHEN LOWER(HN) LIKE '%vacuum%'                    THEN 'Robot Vacuum'

      /* ===== Air quality (Purifier / Fan) ===== */
      WHEN LOWER(HN) LIKE 'zhimi-airpurifier-%'         THEN 'Air Purifier'
      WHEN LOWER(HN) LIKE 'zhimi-airp-%'                THEN 'Air Purifier'
      WHEN LOWER(HN) LIKE '%zhimi-airpurifier%'         THEN 'Air Purifier'
      WHEN LOWER(HN) LIKE '%levoit-purifier%'           THEN 'Air Purifier'
      WHEN LOWER(HN) LIKE '%dmaker-fan%'                THEN 'Fan'
      WHEN LOWER(HN) LIKE '%airpurifier%'               THEN 'Air Purifier'
      WHEN LOWER(HN) LIKE '%airfryer%'                  THEN 'Airfryer'

      /* ===== Pet devices ===== */
      WHEN LOWER(HN) LIKE 'petkit_%'                    THEN 'Pet Feeder'
      WHEN LOWER(HN) LIKE '%smart cat litter box%'      THEN 'Pet Feeder'

      /* ===== Smart plug / bulb ===== */
      WHEN LOWER(HN) LIKE '%tapo_smartplug%'            THEN 'Smart Plug'
      WHEN LOWER(HN) LIKE '%tapo_bulb%'                 THEN 'Smart Bulb'
      WHEN LOWER(HN) LIKE '%bulb%'                      THEN 'Smart Bulb'

      /* ===== Voice assistant / speakers / audio ===== */
      WHEN LOWER(HN) LIKE '%google-home-mini%'          THEN 'Voice Assistant Speaker'
      WHEN LOWER(HN) LIKE '%google-home%'               THEN 'Voice Assistant Speaker'
      WHEN LOWER(HN) LIKE '%google-nest-mini%'          THEN 'Voice Assistant Speaker'
      WHEN LOWER(HN) LIKE '%homepod%'                   THEN 'Voice Assistant Speaker'
      WHEN LOWER(HN) LIKE '%bose-smart-soundbar-%'      THEN 'Soundbar'
      WHEN LOWER(HN) LIKE '%bose-smart-speaker-%'       THEN 'Smart Speaker'
      WHEN LOWER(HN) LIKE '%bose-smart-ultra-soundbar-%'  THEN 'Soundbar'
      WHEN LOWER(HN) LIKE '%bose-portable-smart-speaker%' THEN 'Smart Speaker'
      WHEN LOWER(HN) LIKE '%sonoszp%'                   THEN 'Smart Speaker'
      WHEN LOWER(HN) LIKE '%jbl%'                       THEN 'Smart Speaker'
      WHEN LOWER(HN) LIKE '%audiocast%'                 THEN 'Audio Streamer'
      WHEN LOWER(HN) LIKE '%bt-speaker%'                THEN 'Bluetooth Speaker'

      /* ===== Printers ===== */
      WHEN LOWER(HN) LIKE 'epson%'                      THEN 'Printer'

      /* ===== Kitchen / generic big appliance words ===== */
      WHEN LOWER(HN) LIKE '%washer%'                    THEN 'Washing Machine'
      WHEN LOWER(HN) LIKE '%dryer%'                     THEN 'Dryer'
      WHEN LOWER(HN) LIKE '%fridge%'                    THEN 'Fridge'
      WHEN LOWER(HN) LIKE '%refrigerator%'              THEN 'Fridge'
      WHEN LOWER(HN) LIKE '%microwave%'                 THEN 'Microwave'
      WHEN LOWER(HN) LIKE '%light%'                     THEN 'Smart Bulb'

      /* ===== Climate / AC tokens ===== */
      WHEN LOWER(HN) LIKE '%aircon%'                    THEN 'Air Conditioner'

      /* ===== Water / purifier ===== */
      WHEN LOWER(HN) LIKE '%water2_open%'               THEN 'Water Purifier'

      /* ===== Hubs / Gateways / Modules / SDK OS ===== */
      WHEN LOWER(HN) LIKE '%smartgateway%'              THEN 'Smart Hub/Gateway'
      WHEN LOWER(HN) LIKE '%gbeacon%'                   THEN 'Beacon'

      /* ===== Energy / inverter ===== */
      WHEN LOWER(HN) LIKE '%renac_wifi%'                THEN 'Solar Inverter/Power'

      /* ===== Scales / health ===== */
      WHEN LOWER(HN) LIKE '%smart scale%'               THEN 'Smart Scale'

      /* ===== Misc brand codes you listed (classify to best-effort buckets) ===== */
      WHEN LOWER(HN) = 'l530'                           THEN 'Smart Bulb'
      WHEN LOWER(HN) = 'k12'                            THEN 'Bluetooth Speaker'
      WHEN LOWER(HN) = 'p105'                           THEN 'Smart Plug'
      WHEN LOWER(HN) = 'skg'                            THEN 'Bluetooth Speaker'
      WHEN LOWER(HN) = 'dbx'                            THEN 'DriveRack'

      /* ===== Catch-alls for generic words ===== */
      WHEN LOWER(HN) LIKE '%robot%'                     THEN 'Robot'

      /* ===== Default for IoT_SmartHome when nothing else matched ===== */
      ELSE 'IoT_Other'
    END AS DEVICE_CAT
FROM TEMP_CURCUIT_DATA_DEVICE_BRAND
DISTRIBUTE ON (MNTH_ID, CIRCUIT, HN);



/* ============================================================
   CREATE THE AGGREGATE TEMP TABLE FOR NUM OF DEVICE
   ============================================================ */
DROP TABLE TEMP_CURCUIT_DATA_AGG_DEVICE IF EXISTS;

CREATE TEMP TABLE TEMP_CURCUIT_DATA_AGG_DEVICE AS
WITH BASE AS (
  SELECT
       MNTH_ID
      ,CIRCUIT
      -- sentinel so DISTINCT works even when hostname is NULL
      ,COALESCE(HN, '__NULL__') AS HOSTNAME_KEY
      -- force NULL hostnames into their own bucket
      ,CASE
        WHEN HN IS NULL THEN 'NULL'
        ELSE DEVICE_GROUP
      END AS DEVICE_GROUP_EFF
  FROM TEMP_CURCUIT_DATA_DEVICE_BRAND
)
SELECT
     MNTH_ID
    ,CIRCUIT

    /* distinct device counts by group */
    ,COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'Mobile_Smartphone' THEN HOSTNAME_KEY END) AS COUNT_MOBILE_DEVICE
    ,COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'Mobile_Tablet'     THEN HOSTNAME_KEY END) AS COUNT_TABLET_DEVICE
    ,COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'PC_Laptop'         THEN HOSTNAME_KEY END) AS COUNT_PC_DEVICE
    ,COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'TV'                THEN HOSTNAME_KEY END) AS COUNT_TV_DEVICE
	,COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'TV_BOX'            THEN HOSTNAME_KEY END) AS COUNT_TV_BOX_DEVICE
    ,COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'Camera_CCTV'       THEN HOSTNAME_KEY END) AS COUNT_CCTV_DEVICE
    ,COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'IoT_SmartHome'     THEN HOSTNAME_KEY END) AS COUNT_IOT_DEVICE
    ,COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'MESH_WIFI'        THEN HOSTNAME_KEY END)  AS COUNT_MESH_WIFI_DEVICE
    ,COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'Wearable'          THEN HOSTNAME_KEY END) AS COUNT_WEARABLE_DEVICE
    /* "Other" = Unknown/Other only (NULL hostnames are excluded) */
    ,COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF IN ('Unknown','Other') THEN HOSTNAME_KEY END) AS COUNT_OTHER_DEVICE
    /* NULL bucket = true NULL hostnames only */
    ,COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'NULL'              THEN HOSTNAME_KEY END) AS COUNT_NULL_DEVICE

FROM BASE
GROUP BY MNTH_ID, CIRCUIT
DISTRIBUTE ON (MNTH_ID, CIRCUIT);

/* ============================================================
   CREATE MASTER DEVICE BY GROUP BRAND CATEGORY
   ============================================================ */
DROP TABLE SANDBOX_NZ.ADMIN.AUTO_HBB_MASTER_DEVICE IF EXISTS;
 
CREATE TABLE SANDBOX_NZ.ADMIN.AUTO_HBB_MASTER_DEVICE AS

SELECT DISTINCT
	  HN
	, DEVICE_GROUP
	, DEVICE_BRAND
	, DEVICE_CAT
FROM TEMP_CURCUIT_DATA_DEVICE_CAT
DISTRIBUTE ON (HN, DEVICE_GROUP);  

/* ============================================================
   FIND SIZING FOR THE USE CASE 
   ============================================================ */
-- CREATE THE REAL AGGREAGATE TABLE IN NEWNZ
DROP TABLE SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE IF EXISTS;
 
CREATE TABLE SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE AS
SELECT * FROM TEMP_CURCUIT_DATA_AGG_DEVICE

DISTRIBUTE ON (MNTH_ID, CIRCUIT);

-- USE CASE 1 
SELECT
    MNTH_ID
  , COUNT(DISTINCT CIRCUIT) AS CIRCUIT_CNT
FROM TEMP_CURCUIT_DATA_DEVICE_BRAND
WHERE DEVICE_GROUP = 'Camera_CCTV'
  AND DEVICE_BRAND IN ('Xiaomi', 'TP-Link_Tapo')
GROUP BY MNTH_ID
ORDER BY MNTH_ID;

-- USE CASE 2
SELECT COUNT(*)
FROM TEMP_CURCUIT_DATA_AGG_DEVICE
WHERE COALESCE(COUNT_TV_DEVICE, 0) >= 1
  AND COALESCE(COUNT_TV_BOX_DEVICE, 0) < COALESCE(COUNT_TV_DEVICE, 0);
  
  
/* ============================================================
   CREATE THE AGGREAGATE TABLE FOR THE CIRCUIT IN EACH USE CASE 
   ============================================================ */  
DROP TABLE SANDBOX_NZ.ADMIN.HBB_USECASE_ASSESTNUM IF EXISTS ;

CREATE TABLE SANDBOX_NZ.ADMIN.HBB_USECASE_ASSESTNUM AS
(
    /* USECASE1::CCTV Upgrader */
    SELECT DISTINCT
        A.MNTH_ID
      , CAST(A.CIRCUIT AS VARCHAR(64)) AS CIRCUIT_NO
      , 'USECASE1::CCTV Upgrader'      AS USECASE
    FROM TEMP_CURCUIT_DATA_DEVICE_BRAND A
    WHERE A.DEVICE_GROUP = 'Camera_CCTV'
      AND A.DEVICE_BRAND IN ('Xiaomi', 'TP-Link_Tapo')

    UNION ALL

    /* USECASE2::MULTI TV HOUSEHOLD */
    SELECT DISTINCT
        B.MNTH_ID
      , CAST(B.CIRCUIT AS VARCHAR(64)) AS CIRCUIT_NO
      , 'USECASE2::MULTI TV HOUSEHOLD' AS USECASE
    FROM TEMP_CURCUIT_DATA_AGG_DEVICE B
    WHERE COALESCE(B.COUNT_TV_DEVICE, 0) >= 1
      AND COALESCE(B.COUNT_TV_BOX_DEVICE, 0) < COALESCE(B.COUNT_TV_DEVICE, 0)
) DISTRIBUTE ON (MNTH_ID, CIRCUIT_NO);


/* ============================================================
   CREATE THE AGGREAGATE TABLE THAT HAVE MANY FLAG FOR MERGE WITH WEB USAGE
   ============================================================ */
-- 1. BASE: raw host + brand
DROP TABLE TEMP_HBB_DEVICE_BASE IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_DEVICE_BASE AS
SELECT
     MNTH_ID
    ,CIRCUIT
    ,COALESCE(HN, '__NULL__') AS HOST_KEY
    ,DEVICE_GROUP
    ,NULLIF(UPPER(TRIM(DEVICE_BRAND)), '') AS BRAND_UP
FROM TEMP_CURCUIT_DATA_DEVICE_CAT
DISTRIBUTE ON (MNTH_ID, CIRCUIT);


-- 2. BRAND_BASE: keep OTHER/UNMAPPED, drop UNKNOWN/NULL
DROP TABLE TEMP_HBB_BRAND_BASE IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_BRAND_BASE AS
SELECT
     MNTH_ID
    ,CIRCUIT
    ,HOST_KEY
    ,DEVICE_GROUP
    ,CASE
      WHEN BRAND_UP IS NULL OR BRAND_UP = 'UNKNOWN' THEN NULL
      ELSE BRAND_UP          -- keep OTHER/UNMAPPED as a real brand
    END AS BRAND
FROM TEMP_HBB_DEVICE_BASE
DISTRIBUTE ON (MNTH_ID, CIRCUIT);


-- 3. TOTALS: total devices per circuit
DROP TABLE TEMP_HBB_TOTALS IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_TOTALS AS
SELECT
     MNTH_ID
    ,CIRCUIT
    ,COUNT(DISTINCT HOST_KEY) AS TOTAL_DEVICE
FROM TEMP_HBB_BRAND_BASE
GROUP BY MNTH_ID, CIRCUIT
DISTRIBUTE ON (MNTH_ID, CIRCUIT);


-- 4. GROUP_CNT: device count per circuit + device_group
DROP TABLE TEMP_HBB_GROUP_CNT IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_GROUP_CNT AS
SELECT
     MNTH_ID
    ,CIRCUIT
    ,DEVICE_GROUP
    ,COUNT(DISTINCT HOST_KEY) AS CNT
FROM TEMP_HBB_BRAND_BASE
GROUP BY MNTH_ID, CIRCUIT, DEVICE_GROUP
DISTRIBUTE ON (MNTH_ID, CIRCUIT);

DROP TABLE TEMP_HBB_BRAND_DEVICE_CNT IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_BRAND_DEVICE_CNT AS
SELECT
     MNTH_ID
    ,CIRCUIT
    ,DEVICE_GROUP
    ,BRAND
    ,COUNT(DISTINCT HOST_KEY) AS BRAND_DEVICE_CNT
FROM TEMP_HBB_BRAND_BASE
WHERE BRAND IS NOT NULL
GROUP BY
     MNTH_ID
    ,CIRCUIT
    ,DEVICE_GROUP
    ,BRAND
DISTRIBUTE ON (MNTH_ID, CIRCUIT);



DROP TABLE TEMP_HBB_BRAND_FLAGS IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_BRAND_FLAGS AS
SELECT
      MNTH_ID
    , CIRCUIT
    , DEVICE_GROUP
    , COUNT(DISTINCT BRAND) AS BRAND_CNT

    /* --- Core smartphone / tablet brands --- */
    , MAX(CASE WHEN BRAND = 'APPLE'   THEN 1 ELSE 0 END) AS HAS_APPLE
    , MAX(CASE WHEN BRAND = 'SAMSUNG' THEN 1 ELSE 0 END) AS HAS_SAMSUNG
    , MAX(CASE WHEN BRAND = 'OPPO'    THEN 1 ELSE 0 END) AS HAS_OPPO
    , MAX(CASE WHEN BRAND = 'VIVO'    THEN 1 ELSE 0 END) AS HAS_VIVO
    , MAX(CASE WHEN BRAND = 'REALME'  THEN 1 ELSE 0 END) AS HAS_REALME
    , MAX(CASE WHEN BRAND = 'XIAOMI'  THEN 1 ELSE 0 END) AS HAS_XIAOMI
    , MAX(CASE WHEN BRAND = 'HUAWEI'  THEN 1 ELSE 0 END) AS HAS_HUAWEI
    , MAX(CASE WHEN BRAND = 'HONOR'   THEN 1 ELSE 0 END) AS HAS_HONOR
    , MAX(CASE WHEN BRAND = 'ONEPLUS' THEN 1 ELSE 0 END) AS HAS_ONEPLUS
    , MAX(CASE WHEN BRAND = 'INFINIX' THEN 1 ELSE 0 END) AS HAS_INFINIX
    , MAX(CASE WHEN BRAND = 'TECNO'   THEN 1 ELSE 0 END) AS HAS_TECNO
    , MAX(CASE WHEN BRAND = 'NOKIA'   THEN 1 ELSE 0 END) AS HAS_NOKIA
    , MAX(CASE WHEN BRAND = 'ASUS'    THEN 1 ELSE 0 END) AS HAS_ASUS
    , MAX(CASE WHEN BRAND = 'LENOVO'  THEN 1 ELSE 0 END) AS HAS_LENOVO
    , MAX(CASE WHEN BRAND = 'MOTOROLA' THEN 1 ELSE 0 END) AS HAS_MOTOROLA
    , MAX(CASE WHEN BRAND = 'MEIZU'   THEN 1 ELSE 0 END) AS HAS_MEIZU
    , MAX(CASE WHEN BRAND = 'ZTE'     THEN 1 ELSE 0 END) AS HAS_ZTE
    , MAX(CASE WHEN BRAND = 'GOOGLE'  THEN 1 ELSE 0 END) AS HAS_GOOGLE
    , MAX(CASE WHEN BRAND = 'NOTHING' THEN 1 ELSE 0 END) AS HAS_NOTHING
    , MAX(CASE WHEN BRAND = 'BENCO'   THEN 1 ELSE 0 END) AS HAS_BENCO
    , MAX(CASE WHEN BRAND = 'IQOO'    THEN 1 ELSE 0 END) AS HAS_IQOO
    , MAX(CASE WHEN BRAND = 'ITEL'    THEN 1 ELSE 0 END) AS HAS_ITEL
    , MAX(CASE WHEN BRAND = 'ALTRON'  THEN 1 ELSE 0 END) AS HAS_ALTRON
    , MAX(CASE WHEN BRAND = 'WIKO'    THEN 1 ELSE 0 END) AS HAS_WIKO
    , MAX(CASE WHEN BRAND = 'BRAND_A'    THEN 1 ELSE 0 END) AS HAS_OPER
    , MAX(CASE WHEN BRAND = 'AIS'     THEN 1 ELSE 0 END) AS HAS_AIS
    , MAX(CASE WHEN BRAND = 'ANDROID' THEN 1 ELSE 0 END) AS HAS_ANDROID
    , MAX(CASE WHEN BRAND = 'TCL'     THEN 1 ELSE 0 END) AS HAS_TCL
    , MAX(CASE WHEN BRAND = 'NINETOLOGY' THEN 1 ELSE 0 END) AS HAS_NINETOLOGY
    , MAX(CASE WHEN BRAND = 'YIJIA'   THEN 1 ELSE 0 END) AS HAS_YIJIA
    , MAX(CASE WHEN BRAND = 'HMD'     THEN 1 ELSE 0 END) AS HAS_HMD
    , MAX(CASE WHEN BRAND = 'DOOGEE'  THEN 1 ELSE 0 END) AS HAS_DOOGEE
    , MAX(CASE WHEN BRAND = 'YUNOS'   THEN 1 ELSE 0 END) AS HAS_YUNOS

    /* --- Tablet / mid-tier brands --- */
    , MAX(CASE WHEN BRAND = 'ALLDOCUBE' THEN 1 ELSE 0 END) AS HAS_ALLDOCUBE
    , MAX(CASE WHEN BRAND = 'GIANTPAD'  THEN 1 ELSE 0 END) AS HAS_GIANTPAD
    , MAX(CASE WHEN BRAND = 'ORVIBO'    THEN 1 ELSE 0 END) AS HAS_ORVIBO
    , MAX(CASE WHEN BRAND = 'VALVE'     THEN 1 ELSE 0 END) AS HAS_VALVE
    , MAX(CASE WHEN BRAND = 'CHUWI'     THEN 1 ELSE 0 END) AS HAS_CHUWI
    , MAX(CASE WHEN BRAND = 'TECLAST'   THEN 1 ELSE 0 END) AS HAS_TECLAST
    , MAX(CASE WHEN BRAND = 'BMAX'      THEN 1 ELSE 0 END) AS HAS_BMAX
    , MAX(CASE WHEN BRAND = 'DENGO'     THEN 1 ELSE 0 END) AS HAS_DENGO
    , MAX(CASE WHEN BRAND = 'WEALTHY'   THEN 1 ELSE 0 END) AS HAS_WEALTHY

    /* --- TV / TV_BOX brands --- */
    , MAX(CASE WHEN BRAND = 'LG'                           THEN 1 ELSE 0 END) AS HAS_LG
    , MAX(CASE WHEN BRAND = 'TOSHIBA'                      THEN 1 ELSE 0 END) AS HAS_TOSHIBA
    , MAX(CASE WHEN BRAND = 'COOLITA (SKYWORTH/COOCAA)'    THEN 1 ELSE 0 END) AS HAS_COOLITA
    , MAX(CASE WHEN BRAND = 'GOOGLE TV'                    THEN 1 ELSE 0 END) AS HAS_GOOGLE_TV
    , MAX(CASE WHEN BRAND = 'BEYONDTV'                     THEN 1 ELSE 0 END) AS HAS_BEYONDTV
    , MAX(CASE WHEN BRAND = 'APPLE TV'                     THEN 1 ELSE 0 END) AS HAS_APPLE_TV
    , MAX(CASE WHEN BRAND = 'GOOGLE CHROMECAST'            THEN 1 ELSE 0 END) AS HAS_CHROMECAST
    , MAX(CASE WHEN BRAND = 'OPTV'                     THEN 1 ELSE 0 END) AS HAS_OPTV
    , MAX(CASE WHEN BRAND = 'AIS PLAYBOX'                  THEN 1 ELSE 0 END) AS HAS_AIS_PLAYBOX
    , MAX(CASE WHEN BRAND = 'NOKIA STREAMING BOX'          THEN 1 ELSE 0 END) AS HAS_NOKIA_STREAMING_BOX
    , MAX(CASE WHEN BRAND = 'X96 ANDROID BOX'              THEN 1 ELSE 0 END) AS HAS_X96_BOX
    , MAX(CASE WHEN BRAND = 'HISILICON-BASED BOX'          THEN 1 ELSE 0 END) AS HAS_HISILICON_BOX
    , MAX(CASE WHEN BRAND = 'MICROSOFT XBOX'               THEN 1 ELSE 0 END) AS HAS_XBOX
    , MAX(CASE WHEN BRAND = 'SONY'                         THEN 1 ELSE 0 END) AS HAS_SONY

    /* --- CCTV brands --- */
    , MAX(CASE WHEN BRAND = 'NOMI'         THEN 1 ELSE 0 END) AS HAS_NOMI
    , MAX(CASE WHEN BRAND = 'EZVIZ'        THEN 1 ELSE 0 END) AS HAS_EZVIZ
    , MAX(CASE WHEN BRAND = 'TP-LINK_TAPO' THEN 1 ELSE 0 END) AS HAS_TP_LINK_TAPO
    , MAX(CASE WHEN BRAND = 'GOOGLE_NEST'  THEN 1 ELSE 0 END) AS HAS_GOOGLE_NEST
    , MAX(CASE WHEN BRAND = 'WYZE'         THEN 1 ELSE 0 END) AS HAS_WYZE
    , MAX(CASE WHEN BRAND = '360'          THEN 1 ELSE 0 END) AS HAS_360
    , MAX(CASE WHEN BRAND = 'MXIANG'       THEN 1 ELSE 0 END) AS HAS_MXIANG
    , MAX(CASE WHEN BRAND = 'JD_CAMERA'    THEN 1 ELSE 0 END) AS HAS_JD_CAMERA
    , MAX(CASE WHEN BRAND = 'QCAM'         THEN 1 ELSE 0 END) AS HAS_QCAM
    , MAX(CASE WHEN BRAND = 'IMOU'         THEN 1 ELSE 0 END) AS HAS_IMOU

    /* --- IoT / SmartHome brands --- */
    , MAX(CASE WHEN BRAND = 'MARSHALL'            THEN 1 ELSE 0 END) AS HAS_MARSHALL
    , MAX(CASE WHEN BRAND = 'ROBOROCK'            THEN 1 ELSE 0 END) AS HAS_ROBOROCK
    , MAX(CASE WHEN BRAND = 'DREAME'              THEN 1 ELSE 0 END) AS HAS_DREAME
    , MAX(CASE WHEN BRAND = 'IROBOT'              THEN 1 ELSE 0 END) AS HAS_IROBOT
    , MAX(CASE WHEN BRAND = 'NARWAL'              THEN 1 ELSE 0 END) AS HAS_NARWAL
    , MAX(CASE WHEN BRAND = 'PETKIT'              THEN 1 ELSE 0 END) AS HAS_PETKIT
    , MAX(CASE WHEN BRAND = 'BLACKVUE'            THEN 1 ELSE 0 END) AS HAS_BLACKVUE
    , MAX(CASE WHEN BRAND = 'UBPET'               THEN 1 ELSE 0 END) AS HAS_UBPET
    , MAX(CASE WHEN BRAND = 'APPLE_HOMEPOD'       THEN 1 ELSE 0 END) AS HAS_APPLE_HOMEPOD
    , MAX(CASE WHEN BRAND = 'SONOS'               THEN 1 ELSE 0 END) AS HAS_SONOS
    , MAX(CASE WHEN BRAND = 'BOSE_SMART'          THEN 1 ELSE 0 END) AS HAS_BOSE_SMART
    , MAX(CASE WHEN BRAND = 'JBL'                 THEN 1 ELSE 0 END) AS HAS_JBL
    , MAX(CASE WHEN BRAND = 'AUDIOCAST'           THEN 1 ELSE 0 END) AS HAS_AUDIOCAST
    , MAX(CASE WHEN BRAND = 'LG_SMARTAPPLIANCE'   THEN 1 ELSE 0 END) AS HAS_LG_SMARTAPPLIANCE
    , MAX(CASE WHEN BRAND = 'ELECTROLUX'          THEN 1 ELSE 0 END) AS HAS_ELECTROLUX
    , MAX(CASE WHEN BRAND = 'LEVOIT'              THEN 1 ELSE 0 END) AS HAS_LEVOIT
    , MAX(CASE WHEN BRAND = 'TESLA'               THEN 1 ELSE 0 END) AS HAS_TESLA
    , MAX(CASE WHEN BRAND = 'DBX_AUDIO'           THEN 1 ELSE 0 END) AS HAS_DBX_AUDIO
    , MAX(CASE WHEN BRAND = 'K12_AUDIO'           THEN 1 ELSE 0 END) AS HAS_K12_AUDIO
    , MAX(CASE WHEN BRAND = 'SKG_AUDIO'           THEN 1 ELSE 0 END) AS HAS_SKG_AUDIO
    , MAX(CASE WHEN BRAND = 'RENAC'               THEN 1 ELSE 0 END) AS HAS_RENAC
    , MAX(CASE WHEN BRAND = 'HOMEMATE'            THEN 1 ELSE 0 END) AS HAS_HOMEMATE
    , MAX(CASE WHEN BRAND = 'ROCKCHIP_ROBOT'      THEN 1 ELSE 0 END) AS HAS_ROCKCHIP_ROBOT
    , MAX(CASE WHEN BRAND = 'EPSON'               THEN 1 ELSE 0 END) AS HAS_EPSON

    /* --- Mesh / extender / router-like brands --- */
    , MAX(CASE WHEN BRAND = 'TP-LINK'              THEN 1 ELSE 0 END) AS HAS_TP_LINK
    , MAX(CASE WHEN BRAND = 'TENDA'                THEN 1 ELSE 0 END) AS HAS_TENDA
    , MAX(CASE WHEN BRAND = 'AVM FRITZ!REPEATER'   THEN 1 ELSE 0 END) AS HAS_FRITZ_REPEATER
    , MAX(CASE WHEN BRAND = 'RASPBERRYPI'          THEN 1 ELSE 0 END) AS HAS_RASPBERRYPI
    , MAX(CASE WHEN BRAND = 'OPMESH'             THEN 1 ELSE 0 END) AS HAS_OPMESH
    , MAX(CASE WHEN BRAND = 'OPX'                THEN 1 ELSE 0 END) AS HAS_OPX
    , MAX(CASE WHEN BRAND = 'GWIPC'                THEN 1 ELSE 0 END) AS HAS_GWIPC
    , MAX(CASE WHEN BRAND = 'SKYROUTER'            THEN 1 ELSE 0 END) AS HAS_SKYROUTER

    /* --- PC / Laptop brands --- */
    , MAX(CASE WHEN BRAND = 'DELL'                THEN 1 ELSE 0 END) AS HAS_DELL
    , MAX(CASE WHEN BRAND = 'HP'                  THEN 1 ELSE 0 END) AS HAS_HP
    , MAX(CASE WHEN BRAND = 'ACER'                THEN 1 ELSE 0 END) AS HAS_ACER
    , MAX(CASE WHEN BRAND = 'MSI'                 THEN 1 ELSE 0 END) AS HAS_MSI
    , MAX(CASE WHEN BRAND = 'FUJITSU'             THEN 1 ELSE 0 END) AS HAS_FUJITSU
    , MAX(CASE WHEN BRAND = 'NEC'                 THEN 1 ELSE 0 END) AS HAS_NEC
    , MAX(CASE WHEN BRAND = 'COMPAQ'              THEN 1 ELSE 0 END) AS HAS_COMPAQ
    , MAX(CASE WHEN BRAND = 'GIGABYTE'            THEN 1 ELSE 0 END) AS HAS_GIGABYTE
    , MAX(CASE WHEN BRAND = 'EMACHINES'           THEN 1 ELSE 0 END) AS HAS_EMACHINES
    , MAX(CASE WHEN BRAND = 'MICROSOFT SURFACE'   THEN 1 ELSE 0 END) AS HAS_MICROSOFT_SURFACE
    , MAX(CASE WHEN BRAND = 'INFINIX INBOOK'      THEN 1 ELSE 0 END) AS HAS_INFINIX_INBOOK
    , MAX(CASE WHEN BRAND = 'TOSHIBA'             THEN 1 ELSE 0 END) AS HAS_PC_TOSHIBA

    /* --- Wearable brands --- */
    , MAX(CASE WHEN BRAND = 'APPLE WATCH'         THEN 1 ELSE 0 END) AS HAS_APPLE_WATCH
    , MAX(CASE WHEN BRAND = 'GOOGLE PIXEL WATCH'  THEN 1 ELSE 0 END) AS HAS_GOOGLE_PIXEL_WATCH
    , MAX(CASE WHEN BRAND = 'SAMSUNG GALAXY WATCH' THEN 1 ELSE 0 END) AS HAS_GALAXY_WATCH
    , MAX(CASE WHEN BRAND = 'IMOO'                THEN 1 ELSE 0 END) AS HAS_IMOO
    , MAX(CASE WHEN BRAND = 'FITBIT'              THEN 1 ELSE 0 END) AS HAS_FITBIT
    , MAX(CASE WHEN BRAND = 'GARMIN'              THEN 1 ELSE 0 END) AS HAS_GARMIN
    , MAX(CASE WHEN BRAND = 'AMAZFIT'             THEN 1 ELSE 0 END) AS HAS_AMAZFIT

    , MAX(CASE WHEN BRAND = 'OTHER/UNMAPPED'  THEN 1 ELSE 0 END) AS HAS_OTHER_UNMAPPED

FROM TEMP_HBB_BRAND_BASE
WHERE BRAND IS NOT NULL
GROUP BY
      MNTH_ID
    , CIRCUIT
    , DEVICE_GROUP
DISTRIBUTE ON (MNTH_ID, CIRCUIT);





DROP TABLE TEMP_HBB_BRAND_STATS IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_BRAND_STATS AS
SELECT
     MNTH_ID
    ,CIRCUIT
    ,DEVICE_GROUP
    ,BRAND_CNT
    ,RTRIM(
      /* smartphone / tablet */
      (CASE WHEN HAS_APPLE         = 1 THEN 'Apple+'         ELSE '' END) ||
      (CASE WHEN HAS_SAMSUNG       = 1 THEN 'Samsung+'       ELSE '' END) ||
      (CASE WHEN HAS_OPPO          = 1 THEN 'OPPO+'          ELSE '' END) ||
      (CASE WHEN HAS_VIVO          = 1 THEN 'vivo+'          ELSE '' END) ||
      (CASE WHEN HAS_REALME        = 1 THEN 'realme+'        ELSE '' END) ||
      (CASE WHEN HAS_XIAOMI        = 1 THEN 'Xiaomi+'        ELSE '' END) ||
      (CASE WHEN HAS_HUAWEI        = 1 THEN 'HUAWEI+'        ELSE '' END) ||
      (CASE WHEN HAS_HONOR         = 1 THEN 'HONOR+'         ELSE '' END) ||
      (CASE WHEN HAS_ONEPLUS       = 1 THEN 'OnePlus+'       ELSE '' END) ||
      (CASE WHEN HAS_INFINIX       = 1 THEN 'Infinix+'       ELSE '' END) ||
      (CASE WHEN HAS_TECNO         = 1 THEN 'TECNO+'         ELSE '' END) ||
      (CASE WHEN HAS_NOKIA         = 1 THEN 'Nokia+'         ELSE '' END) ||
      (CASE WHEN HAS_ASUS          = 1 THEN 'ASUS+'          ELSE '' END) ||
      (CASE WHEN HAS_LENOVO        = 1 THEN 'Lenovo+'        ELSE '' END) ||
      (CASE WHEN HAS_MOTOROLA      = 1 THEN 'Motorola+'      ELSE '' END) ||
      (CASE WHEN HAS_MEIZU         = 1 THEN 'Meizu+'         ELSE '' END) ||
      (CASE WHEN HAS_ZTE           = 1 THEN 'ZTE+'           ELSE '' END) ||
      (CASE WHEN HAS_GOOGLE        = 1 THEN 'Google+'        ELSE '' END) ||
      (CASE WHEN HAS_NOTHING       = 1 THEN 'Nothing+'       ELSE '' END) ||
      (CASE WHEN HAS_BENCO         = 1 THEN 'Benco+'         ELSE '' END) ||
      (CASE WHEN HAS_IQOO          = 1 THEN 'iQOO+'          ELSE '' END) ||
      (CASE WHEN HAS_ITEL          = 1 THEN 'Itel+'          ELSE '' END) ||
      (CASE WHEN HAS_ALTRON        = 1 THEN 'Altron+'        ELSE '' END) ||
      (CASE WHEN HAS_WIKO          = 1 THEN 'Wiko+'          ELSE '' END) ||
      (CASE WHEN HAS_OPER          = 1 THEN 'OPER+'          ELSE '' END) ||
      (CASE WHEN HAS_AIS           = 1 THEN 'AIS+'           ELSE '' END) ||
      (CASE WHEN HAS_ANDROID       = 1 THEN 'Android+'       ELSE '' END) ||
      (CASE WHEN HAS_TCL           = 1 THEN 'TCL+'           ELSE '' END) ||
      (CASE WHEN HAS_NINETOLOGY    = 1 THEN 'Ninetology+'    ELSE '' END) ||
      (CASE WHEN HAS_YIJIA         = 1 THEN 'Yijia+'         ELSE '' END) ||
      (CASE WHEN HAS_HMD           = 1 THEN 'HMD+'           ELSE '' END) ||
      (CASE WHEN HAS_DOOGEE        = 1 THEN 'DOOGEE+'        ELSE '' END) ||
      (CASE WHEN HAS_YUNOS         = 1 THEN 'YunOS+'         ELSE '' END) ||

      /* tablet / mid-tier */
      (CASE WHEN HAS_ALLDOCUBE     = 1 THEN 'Alldocube+'     ELSE '' END) ||
      (CASE WHEN HAS_GIANTPAD      = 1 THEN 'GiantPad+'      ELSE '' END) ||
      (CASE WHEN HAS_ORVIBO        = 1 THEN 'Orvibo+'        ELSE '' END) ||
      (CASE WHEN HAS_VALVE         = 1 THEN 'Valve+'         ELSE '' END) ||
      (CASE WHEN HAS_CHUWI         = 1 THEN 'CHUWI+'         ELSE '' END) ||
      (CASE WHEN HAS_TECLAST       = 1 THEN 'Teclast+'       ELSE '' END) ||
      (CASE WHEN HAS_BMAX          = 1 THEN 'BMAX+'          ELSE '' END) ||
      (CASE WHEN HAS_DENGO         = 1 THEN 'Dengo+'         ELSE '' END) ||
      (CASE WHEN HAS_WEALTHY       = 1 THEN 'Wealthy+'       ELSE '' END) ||

      /* TV / TV_BOX */
      (CASE WHEN HAS_LG                  = 1 THEN 'LG+'                  ELSE '' END) ||
      (CASE WHEN HAS_TOSHIBA             = 1 THEN 'Toshiba+'             ELSE '' END) ||
      (CASE WHEN HAS_COOLITA             = 1 THEN 'Coolita+'             ELSE '' END) ||
      (CASE WHEN HAS_GOOGLE_TV           = 1 THEN 'Google TV+'           ELSE '' END) ||
      (CASE WHEN HAS_BEYONDTV            = 1 THEN 'BeyondTV+'            ELSE '' END) ||
      (CASE WHEN HAS_APPLE_TV            = 1 THEN 'Apple TV+'            ELSE '' END) ||
      (CASE WHEN HAS_CHROMECAST          = 1 THEN 'Chromecast+'          ELSE '' END) ||
      (CASE WHEN HAS_OPTV            = 1 THEN 'OpTV+'            ELSE '' END) ||
      (CASE WHEN HAS_AIS_PLAYBOX         = 1 THEN 'AIS Playbox+'         ELSE '' END) ||
      (CASE WHEN HAS_NOKIA_STREAMING_BOX = 1 THEN 'Nokia Streaming Box+' ELSE '' END) ||
      (CASE WHEN HAS_X96_BOX             = 1 THEN 'X96 Android Box+'     ELSE '' END) ||
      (CASE WHEN HAS_HISILICON_BOX       = 1 THEN 'HiSilicon Box+'       ELSE '' END) ||
      (CASE WHEN HAS_XBOX                = 1 THEN 'Xbox+'                ELSE '' END) ||
      (CASE WHEN HAS_SONY                = 1 THEN 'Sony+'                ELSE '' END) ||

      /* CCTV */
      (CASE WHEN HAS_NOMI          = 1 THEN 'NOMI+'          ELSE '' END) ||
      (CASE WHEN HAS_EZVIZ         = 1 THEN 'EZVIZ+'         ELSE '' END) ||
      (CASE WHEN HAS_TP_LINK_TAPO  = 1 THEN 'TP-Link Tapo+'  ELSE '' END) ||
      (CASE WHEN HAS_GOOGLE_NEST   = 1 THEN 'Google Nest+'   ELSE '' END) ||
      (CASE WHEN HAS_WYZE          = 1 THEN 'Wyze+'          ELSE '' END) ||
      (CASE WHEN HAS_360           = 1 THEN '360+'           ELSE '' END) ||
      (CASE WHEN HAS_MXIANG        = 1 THEN 'MXIANG+'        ELSE '' END) ||
      (CASE WHEN HAS_JD_CAMERA     = 1 THEN 'JD Camera+'     ELSE '' END) ||
      (CASE WHEN HAS_QCAM          = 1 THEN 'QCAM+'          ELSE '' END) ||
      (CASE WHEN HAS_IMOU          = 1 THEN 'IMOU+'          ELSE '' END) ||

      /* IoT / SmartHome */
      (CASE WHEN HAS_MARSHALL          = 1 THEN 'Marshall+'          ELSE '' END) ||
      (CASE WHEN HAS_ROBOROCK          = 1 THEN 'Roborock+'          ELSE '' END) ||
      (CASE WHEN HAS_DREAME            = 1 THEN 'Dreame+'            ELSE '' END) ||
      (CASE WHEN HAS_IROBOT            = 1 THEN 'iRobot+'            ELSE '' END) ||
      (CASE WHEN HAS_NARWAL            = 1 THEN 'Narwal+'            ELSE '' END) ||
      (CASE WHEN HAS_PETKIT            = 1 THEN 'Petkit+'            ELSE '' END) ||
      (CASE WHEN HAS_BLACKVUE          = 1 THEN 'BlackVue+'          ELSE '' END) ||
      (CASE WHEN HAS_UBPET             = 1 THEN 'UBPet+'             ELSE '' END) ||
      (CASE WHEN HAS_APPLE_HOMEPOD     = 1 THEN 'Apple HomePod+'     ELSE '' END) ||
      (CASE WHEN HAS_SONOS             = 1 THEN 'Sonos+'             ELSE '' END) ||
      (CASE WHEN HAS_BOSE_SMART        = 1 THEN 'Bose Smart+'        ELSE '' END) ||
      (CASE WHEN HAS_JBL               = 1 THEN 'JBL+'               ELSE '' END) ||
      (CASE WHEN HAS_AUDIOCAST         = 1 THEN 'AudioCast+'         ELSE '' END) ||
      (CASE WHEN HAS_LG_SMARTAPPLIANCE = 1 THEN 'LG SmartAppliance+' ELSE '' END) ||
      (CASE WHEN HAS_ELECTROLUX        = 1 THEN 'Electrolux+'        ELSE '' END) ||
      (CASE WHEN HAS_LEVOIT            = 1 THEN 'Levoit+'            ELSE '' END) ||
      (CASE WHEN HAS_TESLA             = 1 THEN 'Tesla+'             ELSE '' END) ||
      (CASE WHEN HAS_DBX_AUDIO         = 1 THEN 'DBX Audio+'         ELSE '' END) ||
      (CASE WHEN HAS_K12_AUDIO         = 1 THEN 'K12 Audio+'         ELSE '' END) ||
      (CASE WHEN HAS_SKG_AUDIO         = 1 THEN 'SKG Audio+'         ELSE '' END) ||
      (CASE WHEN HAS_RENAC             = 1 THEN 'Renac+'             ELSE '' END) ||
      (CASE WHEN HAS_HOMEMATE          = 1 THEN 'Homemate+'          ELSE '' END) ||
      (CASE WHEN HAS_ROCKCHIP_ROBOT    = 1 THEN 'Rockchip Robot+'    ELSE '' END) ||
      (CASE WHEN HAS_EPSON             = 1 THEN 'Epson+'             ELSE '' END) ||

      /* Mesh / routers */
      (CASE WHEN HAS_TP_LINK       = 1 THEN 'TP-Link+'       ELSE '' END) ||
      (CASE WHEN HAS_TENDA         = 1 THEN 'Tenda+'         ELSE '' END) ||
      (CASE WHEN HAS_FRITZ_REPEATER= 1 THEN 'FRITZ!Repeater+' ELSE '' END) ||
      (CASE WHEN HAS_RASPBERRYPI   = 1 THEN 'RaspberryPi+'   ELSE '' END) ||
      (CASE WHEN HAS_OPMESH      = 1 THEN 'OpMesh+'      ELSE '' END) ||
      (CASE WHEN HAS_OPX         = 1 THEN 'OpX+'         ELSE '' END) ||
      (CASE WHEN HAS_GWIPC         = 1 THEN 'GWIPC+'         ELSE '' END) ||
      (CASE WHEN HAS_SKYROUTER     = 1 THEN 'SkyRouter+'     ELSE '' END) ||

      /* PC / Laptop */
      (CASE WHEN HAS_DELL              = 1 THEN 'Dell+'              ELSE '' END) ||
      (CASE WHEN HAS_HP                = 1 THEN 'HP+'                ELSE '' END) ||
      (CASE WHEN HAS_ACER              = 1 THEN 'Acer+'              ELSE '' END) ||
      (CASE WHEN HAS_MSI               = 1 THEN 'MSI+'               ELSE '' END) ||
      (CASE WHEN HAS_FUJITSU           = 1 THEN 'Fujitsu+'           ELSE '' END) ||
      (CASE WHEN HAS_NEC               = 1 THEN 'NEC+'               ELSE '' END) ||
      (CASE WHEN HAS_COMPAQ            = 1 THEN 'Compaq+'            ELSE '' END) ||
      (CASE WHEN HAS_GIGABYTE          = 1 THEN 'Gigabyte+'          ELSE '' END) ||
      (CASE WHEN HAS_EMACHINES         = 1 THEN 'eMachines+'         ELSE '' END) ||
      (CASE WHEN HAS_MICROSOFT_SURFACE = 1 THEN 'Microsoft Surface+' ELSE '' END) ||
      (CASE WHEN HAS_INFINIX_INBOOK    = 1 THEN 'Infinix InBook+'    ELSE '' END) ||
      (CASE WHEN HAS_PC_TOSHIBA        = 1 THEN 'Toshiba (PC)+'      ELSE '' END) ||

      /* Wearables */
      (CASE WHEN HAS_APPLE_WATCH       = 1 THEN 'Apple Watch+'       ELSE '' END) ||
      (CASE WHEN HAS_GOOGLE_PIXEL_WATCH= 1 THEN 'Google Pixel Watch+' ELSE '' END) ||
      (CASE WHEN HAS_GALAXY_WATCH      = 1 THEN 'Galaxy Watch+'      ELSE '' END) ||
      (CASE WHEN HAS_IMOO              = 1 THEN 'Imoo+'              ELSE '' END) ||
      (CASE WHEN HAS_FITBIT            = 1 THEN 'Fitbit+'            ELSE '' END) ||
      (CASE WHEN HAS_GARMIN            = 1 THEN 'Garmin+'            ELSE '' END) ||
      (CASE WHEN HAS_AMAZFIT           = 1 THEN 'Amazfit+'           ELSE '' END) ||
      (CASE WHEN HAS_OTHER_UNMAPPED    = 1 THEN 'Other/Unmapped+'    ELSE '' END),
      '+'
    ) AS BRAND_MIX
FROM TEMP_HBB_BRAND_FLAGS
DISTRIBUTE ON (MNTH_ID, CIRCUIT);


-- 4A.1 Join totals + group_cnt + brand_stats
DROP TABLE TEMP_HBB_JOINED IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_JOINED AS
SELECT
      T.MNTH_ID
    , T.CIRCUIT
    , T.TOTAL_DEVICE
    , GC.DEVICE_GROUP
    , COALESCE(GC.CNT, 0)       AS CNT
    , COALESCE(BS.BRAND_CNT, 0) AS BRAND_CNT
    , BS.BRAND_MIX
FROM TEMP_HBB_TOTALS T
LEFT JOIN TEMP_HBB_GROUP_CNT GC
  ON GC.MNTH_ID = T.MNTH_ID
 AND GC.CIRCUIT = T.CIRCUIT
LEFT JOIN TEMP_HBB_BRAND_STATS BS
  ON BS.MNTH_ID = T.MNTH_ID
 AND BS.CIRCUIT = T.CIRCUIT
 AND BS.DEVICE_GROUP = GC.DEVICE_GROUP
DISTRIBUTE ON (MNTH_ID, CIRCUIT);

-- 4A.2 BASE TOTALS PER CIRCUIT
DROP TABLE TEMP_HBB_AGG_BASE IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_AGG_BASE AS
SELECT
      MNTH_ID
    , CIRCUIT
    , MAX(TOTAL_DEVICE) AS TOTAL_DEVICE
FROM TEMP_HBB_JOINED
GROUP BY
      MNTH_ID
    , CIRCUIT
DISTRIBUTE ON (MNTH_ID, CIRCUIT);



DROP TABLE TEMP_HBB_MOBILE IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_MOBILE AS
SELECT
      G.MNTH_ID
    , G.CIRCUIT
    , 1 AS MOBILE_FLAG

    -- total devices in this circuit for Mobile_Smartphone
    , G.CNT AS MOBILE_CNT

    , CAST(G.CNT AS NUMERIC(20,6))
      / NULLIF(CAST(B.TOTAL_DEVICE AS NUMERIC(20,6)), 0) AS MOBILE_PCT

    , COALESCE(BS.BRAND_CNT, 0) AS MOBILE_BRAND_CNT
    , BS.BRAND_MIX              AS MOBILE_BRAND_MIX

    /* === Per-brand device counts (distinct HOST_KEY) === */
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'APPLE'   THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_APPLE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'SAMSUNG' THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_SAMSUNG_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OPPO'    THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_OPPO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'VIVO'    THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_VIVO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'REALME'  THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_REALME_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'XIAOMI'  THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_XIAOMI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'HUAWEI'  THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_HUAWEI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'HONOR'   THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_HONOR_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ONEPLUS' THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_ONEPLUS_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'INFINIX' THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_INFINIX_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'TECNO'   THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_TECNO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'NOKIA'   THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_NOKIA_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ASUS'    THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_ASUS_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'LENOVO'  THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_LENOVO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'MOTOROLA' THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_MOTOROLA_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'MEIZU'   THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_MEIZU_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ZTE'     THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_ZTE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'GOOGLE'  THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_GOOGLE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'NOTHING' THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_NOTHING_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'BENCO'   THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_BENCO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'IQOO'    THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_IQOO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ITEL'    THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_ITEL_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ALTRON'  THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_ALTRON_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'WIKO'    THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_WIKO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'BRAND_A'    THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_OPER_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'AIS'     THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_AIS_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ANDROID' THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_ANDROID_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'TCL'     THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_TCL_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'NINETOLOGY' THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_NINETOLOGY_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'YIJIA'   THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_YIJIA_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'HMD'     THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_HMD_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'DOOGEE'  THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_DOOGEE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'YUNOS'   THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_YUNOS_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OTHER/UNMAPPED'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MOBILE_BRAND_OTHER_UNMAPPED_CNT

FROM TEMP_HBB_GROUP_CNT G
JOIN TEMP_HBB_AGG_BASE B
  ON B.MNTH_ID = G.MNTH_ID
 AND B.CIRCUIT = G.CIRCUIT
LEFT JOIN TEMP_HBB_BRAND_STATS BS
  ON BS.MNTH_ID      = G.MNTH_ID
 AND BS.CIRCUIT      = G.CIRCUIT
 AND BS.DEVICE_GROUP = G.DEVICE_GROUP
LEFT JOIN TEMP_HBB_BRAND_DEVICE_CNT BC
  ON BC.MNTH_ID      = G.MNTH_ID
 AND BC.CIRCUIT      = G.CIRCUIT
 AND BC.DEVICE_GROUP = G.DEVICE_GROUP
WHERE G.DEVICE_GROUP = 'Mobile_Smartphone'
GROUP BY
      G.MNTH_ID
    , G.CIRCUIT
    , G.CNT
    , B.TOTAL_DEVICE
    , BS.BRAND_CNT
    , BS.BRAND_MIX
DISTRIBUTE ON (MNTH_ID, CIRCUIT);



DROP TABLE TEMP_HBB_TABLET IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_TABLET AS
SELECT
      G.MNTH_ID
    , G.CIRCUIT
    , 1 AS TABLET_FLAG

    , G.CNT AS TABLET_CNT

    , CAST(G.CNT AS NUMERIC(20,6))
      / NULLIF(CAST(B.TOTAL_DEVICE AS NUMERIC(20,6)), 0) AS TABLET_PCT

    , COALESCE(BS.BRAND_CNT, 0) AS TABLET_BRAND_CNT
    , BS.BRAND_MIX              AS TABLET_BRAND_MIX

    /* === PER-BRAND DEVICE COUNTS FOR TABLETS === */
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'APPLE'     THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_APPLE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'SAMSUNG'   THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_SAMSUNG_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'HUAWEI'    THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_HUAWEI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'XIAOMI'    THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_XIAOMI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OPPO'      THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_OPPO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'HONOR'     THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_HONOR_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'REALME'    THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_REALME_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'VIVO'      THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_VIVO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ONEPLUS'   THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_ONEPLUS_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'LENOVO'    THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_LENOVO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ALLDOCUBE' THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_ALLDOCUBE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'GIANTPAD'  THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_GIANTPAD_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ORVIBO'    THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_ORVIBO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'VALVE'     THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_VALVE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'CHUWI'     THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_CHUWI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'TECLAST'   THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_TECLAST_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'BMAX'      THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_BMAX_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'DENGO'     THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_DENGO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'WEALTHY'   THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_WEALTHY_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'TCL'       THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_TCL_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'INFINIX'   THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_INFINIX_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OTHER/UNMAPPED'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TABLET_BRAND_OTHER_UNMAPPED_CNT

FROM TEMP_HBB_GROUP_CNT G
JOIN TEMP_HBB_AGG_BASE B
  ON B.MNTH_ID = G.MNTH_ID
 AND B.CIRCUIT = G.CIRCUIT
LEFT JOIN TEMP_HBB_BRAND_STATS BS
  ON BS.MNTH_ID      = G.MNTH_ID
 AND BS.CIRCUIT      = G.CIRCUIT
 AND BS.DEVICE_GROUP = G.DEVICE_GROUP
LEFT JOIN TEMP_HBB_BRAND_DEVICE_CNT BC
  ON BC.MNTH_ID      = G.MNTH_ID
 AND BC.CIRCUIT      = G.CIRCUIT
 AND BC.DEVICE_GROUP = G.DEVICE_GROUP
WHERE G.DEVICE_GROUP = 'Mobile_Tablet'
GROUP BY
      G.MNTH_ID
    , G.CIRCUIT
    , G.CNT
    , B.TOTAL_DEVICE
    , BS.BRAND_CNT
    , BS.BRAND_MIX
DISTRIBUTE ON (MNTH_ID, CIRCUIT);



DROP TABLE TEMP_HBB_PC IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_PC AS
SELECT
      G.MNTH_ID
    , G.CIRCUIT
    , 1 AS PC_LAPTOP_FLAG

    , G.CNT AS PC_LAPTOP_CNT

    , CAST(G.CNT AS NUMERIC(20,6))
      / NULLIF(CAST(B.TOTAL_DEVICE AS NUMERIC(20,6)), 0) AS PC_LAPTOP_PCT

    , COALESCE(BS.BRAND_CNT, 0) AS PC_LAPTOP_BRAND_CNT
    , BS.BRAND_MIX              AS PC_LAPTOP_BRAND_MIX

    /* === PER-BRAND DEVICE COUNTS FOR PC_LAPTOP === */
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'APPLE'             THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_APPLE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'DELL'              THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_DELL_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'HP'                THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_HP_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'LENOVO'            THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_LENOVO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ASUS'              THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_ASUS_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ACER'              THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_ACER_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'MSI'               THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_MSI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'FUJITSU'           THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_FUJITSU_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'NEC'               THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_NEC_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'SONY'              THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_SONY_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'SAMSUNG'           THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_SAMSUNG_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'COMPAQ'            THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_COMPAQ_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'GIGABYTE'          THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_GIGABYTE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'EMACHINES'         THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_EMACHINES_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'MICROSOFT SURFACE' THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_MICROSOFT_SURFACE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'INFINIX INBOOK'    THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_INFINIX_INBOOK_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'TOSHIBA'           THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_TOSHIBA_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'HUAWEI'            THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_HUAWEI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OTHER/UNMAPPED'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS PC_LAPTOP_BRAND_OTHER_UNMAPPED_CNT

FROM TEMP_HBB_GROUP_CNT G
JOIN TEMP_HBB_AGG_BASE B
  ON B.MNTH_ID = G.MNTH_ID
 AND B.CIRCUIT = G.CIRCUIT
LEFT JOIN TEMP_HBB_BRAND_STATS BS
  ON BS.MNTH_ID      = G.MNTH_ID
 AND BS.CIRCUIT      = G.CIRCUIT
 AND BS.DEVICE_GROUP = G.DEVICE_GROUP
LEFT JOIN TEMP_HBB_BRAND_DEVICE_CNT BC
  ON BC.MNTH_ID      = G.MNTH_ID
 AND BC.CIRCUIT      = G.CIRCUIT
 AND BC.DEVICE_GROUP = G.DEVICE_GROUP
WHERE G.DEVICE_GROUP = 'PC_Laptop'
GROUP BY
      G.MNTH_ID
    , G.CIRCUIT
    , G.CNT
    , B.TOTAL_DEVICE
    , BS.BRAND_CNT
    , BS.BRAND_MIX
DISTRIBUTE ON (MNTH_ID, CIRCUIT);





DROP TABLE TEMP_HBB_TV IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_TV AS
SELECT
      G.MNTH_ID
    , G.CIRCUIT
    , 1 AS TV_FLAG

    , G.CNT AS TV_CNT

    , CAST(G.CNT AS NUMERIC(20,6))
      / NULLIF(CAST(B.TOTAL_DEVICE AS NUMERIC(20,6)), 0) AS TV_PCT

    , COALESCE(BS.BRAND_CNT, 0) AS TV_BRAND_CNT
    , BS.BRAND_MIX              AS TV_BRAND_MIX

    /* === Per-brand device counts for TV === */
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'XIAOMI'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BRAND_XIAOMI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'BEYONDTV'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BRAND_BEYONDTV_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'LG'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BRAND_LG_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'SAMSUNG'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BRAND_SAMSUNG_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'TCL'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BRAND_TCL_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'TOSHIBA'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BRAND_TOSHIBA_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'COOLITA (SKYWORTH/COOCAA)'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BRAND_COOLITA_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'GOOGLE TV'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BRAND_GOOGLE_TV_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'SONY'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BRAND_SONY_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OTHER/UNMAPPED'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BRAND_OTHER_UNMAPPED_CNT

FROM TEMP_HBB_GROUP_CNT G
JOIN TEMP_HBB_AGG_BASE B
  ON B.MNTH_ID = G.MNTH_ID
 AND B.CIRCUIT = G.CIRCUIT
LEFT JOIN TEMP_HBB_BRAND_STATS BS
  ON BS.MNTH_ID      = G.MNTH_ID
 AND BS.CIRCUIT      = G.CIRCUIT
 AND BS.DEVICE_GROUP = G.DEVICE_GROUP
LEFT JOIN TEMP_HBB_BRAND_DEVICE_CNT BC
  ON BC.MNTH_ID      = G.MNTH_ID
 AND BC.CIRCUIT      = G.CIRCUIT
 AND BC.DEVICE_GROUP = G.DEVICE_GROUP
WHERE G.DEVICE_GROUP = 'TV'
GROUP BY
      G.MNTH_ID
    , G.CIRCUIT
    , G.CNT
    , B.TOTAL_DEVICE
    , BS.BRAND_CNT
    , BS.BRAND_MIX
DISTRIBUTE ON (MNTH_ID, CIRCUIT);




DROP TABLE TEMP_HBB_TVBOX IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_TVBOX AS
SELECT
      G.MNTH_ID
    , G.CIRCUIT
    , 1 AS TV_BOX_FLAG

    , G.CNT AS TV_BOX_CNT

    , CAST(G.CNT AS NUMERIC(20,6))
      / NULLIF(CAST(B.TOTAL_DEVICE AS NUMERIC(20,6)), 0) AS TV_BOX_PCT

    , COALESCE(BS.BRAND_CNT, 0) AS TV_BOX_BRAND_CNT
    , BS.BRAND_MIX              AS TV_BOX_BRAND_MIX

    /* === PER-BRAND DEVICE COUNTS FOR TV_BOX === */
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'APPLE TV'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BOX_BRAND_APPLE_TV_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'GOOGLE CHROMECAST'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BOX_BRAND_GOOGLE_CHROMECAST_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OPTV'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BOX_BRAND_OPTV_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'AIS PLAYBOX'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BOX_BRAND_AIS_PLAYBOX_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'NOKIA STREAMING BOX'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BOX_BRAND_NOKIA_STREAMING_BOX_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'X96 ANDROID BOX'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BOX_BRAND_X96_ANDROID_BOX_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'HISILICON-BASED BOX'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BOX_BRAND_HISILICON_BOX_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'MICROSOFT XBOX'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BOX_BRAND_MICROSOFT_XBOX_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OTHER/UNMAPPED'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS TV_BOX_BRAND_OTHER_UNMAPPED_CNT

FROM TEMP_HBB_GROUP_CNT G
JOIN TEMP_HBB_AGG_BASE B
  ON B.MNTH_ID = G.MNTH_ID
 AND B.CIRCUIT = G.CIRCUIT
LEFT JOIN TEMP_HBB_BRAND_STATS BS
  ON BS.MNTH_ID      = G.MNTH_ID
 AND BS.CIRCUIT      = G.CIRCUIT
 AND BS.DEVICE_GROUP = G.DEVICE_GROUP
LEFT JOIN TEMP_HBB_BRAND_DEVICE_CNT BC
  ON BC.MNTH_ID      = G.MNTH_ID
 AND BC.CIRCUIT      = G.CIRCUIT
 AND BC.DEVICE_GROUP = G.DEVICE_GROUP
WHERE G.DEVICE_GROUP = 'TV_BOX'
GROUP BY
      G.MNTH_ID
    , G.CIRCUIT
    , G.CNT
    , B.TOTAL_DEVICE
    , BS.BRAND_CNT
    , BS.BRAND_MIX
DISTRIBUTE ON (MNTH_ID, CIRCUIT);



DROP TABLE TEMP_HBB_CAMERA IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_CAMERA AS
SELECT
      G.MNTH_ID
    , G.CIRCUIT
    , 1 AS CAMERA_CCTV_FLAG
    , G.CNT AS CAMERA_CCTV_CNT
    , CAST(G.CNT AS NUMERIC(20,6))
      / NULLIF(CAST(B.TOTAL_DEVICE AS NUMERIC(20,6)), 0) AS CAMERA_CCTV_PCT
    , COALESCE(BS.BRAND_CNT, 0) AS CAMERA_CCTV_BRAND_CNT
    , BS.BRAND_MIX              AS CAMERA_CCTV_BRAND_MIX

    /* === Per-brand device counts for Camera_CCTV === */
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'BRAND_A'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS CAMERA_CCTV_BRAND_OPER_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'NOMI'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS CAMERA_CCTV_BRAND_NOMI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'EZVIZ'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS CAMERA_CCTV_BRAND_EZVIZ_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'XIAOMI'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS CAMERA_CCTV_BRAND_XIAOMI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'TP-LINK_TAPO'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS CAMERA_CCTV_BRAND_TP_LINK_TAPO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'GOOGLE_NEST'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS CAMERA_CCTV_BRAND_GOOGLE_NEST_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'WYZE'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS CAMERA_CCTV_BRAND_WYZE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = '360'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS CAMERA_CCTV_BRAND_360_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'MXIANG'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS CAMERA_CCTV_BRAND_MXIANG_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'JD_CAMERA'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS CAMERA_CCTV_BRAND_JD_CAMERA_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'QCAM'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS CAMERA_CCTV_BRAND_QCAM_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'IMOU'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS CAMERA_CCTV_BRAND_IMOU_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OTHER/UNMAPPED'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS CAMERA_CCTV_BRAND_OTHER_UNMAPPED_CNT

FROM TEMP_HBB_GROUP_CNT G
JOIN TEMP_HBB_AGG_BASE B
  ON B.MNTH_ID = G.MNTH_ID
 AND B.CIRCUIT = G.CIRCUIT
LEFT JOIN TEMP_HBB_BRAND_STATS BS
  ON BS.MNTH_ID      = G.MNTH_ID
 AND BS.CIRCUIT      = G.CIRCUIT
 AND BS.DEVICE_GROUP = G.DEVICE_GROUP
LEFT JOIN TEMP_HBB_BRAND_DEVICE_CNT BC
  ON BC.MNTH_ID      = G.MNTH_ID
 AND BC.CIRCUIT      = G.CIRCUIT
 AND BC.DEVICE_GROUP = G.DEVICE_GROUP
WHERE G.DEVICE_GROUP = 'Camera_CCTV'
GROUP BY
      G.MNTH_ID
    , G.CIRCUIT
    , G.CNT
    , B.TOTAL_DEVICE
    , BS.BRAND_CNT
    , BS.BRAND_MIX
DISTRIBUTE ON (MNTH_ID, CIRCUIT);



DROP TABLE TEMP_HBB_IOT IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_IOT AS
SELECT
      G.MNTH_ID
    , G.CIRCUIT
    , 1 AS IOT_SMARTHOME_FLAG
    , G.CNT AS IOT_SMARTHOME_CNT
    , CAST(G.CNT AS NUMERIC(20,6))
      / NULLIF(CAST(B.TOTAL_DEVICE AS NUMERIC(20,6)), 0) AS IOT_SMARTHOME_PCT
    , COALESCE(BS.BRAND_CNT, 0) AS IOT_SMARTHOME_BRAND_CNT
    , BS.BRAND_MIX              AS IOT_SMARTHOME_BRAND_MIX

    /* === PER-BRAND DEVICE COUNTS FOR IOT_SMARTHOME === */
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'MARSHALL'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_MARSHALL_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'XIAOMI'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_XIAOMI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ROBOROCK'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_ROBOROCK_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'DREAME'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_DREAME_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'IROBOT'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_IROBOT_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'NARWAL'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_NARWAL_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'PETKIT'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_PETKIT_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'BLACKVUE'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_BLACKVUE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'UBPET'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_UBPET_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'GOOGLE'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_GOOGLE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'APPLE_HOMEPOD'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_APPLE_HOMEPOD_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'SONOS'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_SONOS_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'BOSE_SMART'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_BOSE_SMART_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'JBL'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_JBL_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'AUDIOCAST'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_AUDIOCAST_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'TP-LINK_TAPO'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_TP_LINK_TAPO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'LG_SMARTAPPLIANCE'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_LG_SMARTAPPLIANCE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ELECTROLUX'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_ELECTROLUX_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'LEVOIT'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_LEVOIT_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'TESLA'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_TESLA_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'DBX_AUDIO'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_DBX_AUDIO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'K12_AUDIO'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_K12_AUDIO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'SKG_AUDIO'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_SKG_AUDIO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'RENAC'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_RENAC_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'HOMEMATE'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_HOMEMATE_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'ROCKCHIP_ROBOT'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_ROCKCHIP_ROBOT_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'EPSON'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_EPSON_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OTHER/UNMAPPED'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS IOT_SMARTHOME_BRAND_OTHER_UNMAPPED_CNT

FROM TEMP_HBB_GROUP_CNT G
JOIN TEMP_HBB_AGG_BASE B
  ON B.MNTH_ID = G.MNTH_ID
 AND B.CIRCUIT = G.CIRCUIT
LEFT JOIN TEMP_HBB_BRAND_STATS BS
  ON BS.MNTH_ID      = G.MNTH_ID
 AND BS.CIRCUIT      = G.CIRCUIT
 AND BS.DEVICE_GROUP = G.DEVICE_GROUP
LEFT JOIN TEMP_HBB_BRAND_DEVICE_CNT BC
  ON BC.MNTH_ID      = G.MNTH_ID
 AND BC.CIRCUIT      = G.CIRCUIT
 AND BC.DEVICE_GROUP = G.DEVICE_GROUP
WHERE G.DEVICE_GROUP = 'IoT_SmartHome'
GROUP BY
      G.MNTH_ID
    , G.CIRCUIT
    , G.CNT
    , B.TOTAL_DEVICE
    , BS.BRAND_CNT
    , BS.BRAND_MIX
DISTRIBUTE ON (MNTH_ID, CIRCUIT);



DROP TABLE TEMP_HBB_MESH IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_MESH AS
SELECT
      G.MNTH_ID
    , G.CIRCUIT
    , 1 AS MESH_WIFI_FLAG
    , G.CNT AS MESH_WIFI_CNT
    , CAST(G.CNT AS NUMERIC(20,6))
      / NULLIF(CAST(B.TOTAL_DEVICE AS NUMERIC(20,6)), 0) AS MESH_WIFI_PCT
    , COALESCE(BS.BRAND_CNT, 0) AS MESH_WIFI_BRAND_CNT
    , BS.BRAND_MIX              AS MESH_WIFI_BRAND_MIX

    /* === Per-brand device counts for MESH_WIFI === */
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'XIAOMI'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MESH_WIFI_BRAND_XIAOMI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'TP-LINK'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MESH_WIFI_BRAND_TP_LINK_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'TENDA'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MESH_WIFI_BRAND_TENDA_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'AVM FRITZ!REPEATER'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MESH_WIFI_BRAND_FRITZ_REPEATER_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'RASPBERRYPI'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MESH_WIFI_BRAND_RASPBERRYPI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OPMESH'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MESH_WIFI_BRAND_OPMESH_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OPX'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MESH_WIFI_BRAND_OPX_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'GWIPC'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MESH_WIFI_BRAND_GWIPC_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'SKYROUTER'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MESH_WIFI_BRAND_SKYROUTER_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OTHER/UNMAPPED'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS MESH_WIFI_BRAND_OTHER_UNMAPPED_CNT

FROM TEMP_HBB_GROUP_CNT G
JOIN TEMP_HBB_AGG_BASE B
  ON B.MNTH_ID = G.MNTH_ID
 AND B.CIRCUIT = G.CIRCUIT
LEFT JOIN TEMP_HBB_BRAND_STATS BS
  ON BS.MNTH_ID      = G.MNTH_ID
 AND BS.CIRCUIT      = G.CIRCUIT
 AND BS.DEVICE_GROUP = G.DEVICE_GROUP
LEFT JOIN TEMP_HBB_BRAND_DEVICE_CNT BC
  ON BC.MNTH_ID      = G.MNTH_ID
 AND BC.CIRCUIT      = G.CIRCUIT
 AND BC.DEVICE_GROUP = G.DEVICE_GROUP
WHERE G.DEVICE_GROUP = 'MESH_WIFI'
GROUP BY
      G.MNTH_ID
    , G.CIRCUIT
    , G.CNT
    , B.TOTAL_DEVICE
    , BS.BRAND_CNT
    , BS.BRAND_MIX
DISTRIBUTE ON (MNTH_ID, CIRCUIT);



DROP TABLE TEMP_HBB_WEARABLE IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_WEARABLE AS
SELECT
      G.MNTH_ID
    , G.CIRCUIT
    , 1 AS WEARABLE_FLAG
    , G.CNT AS WEARABLE_CNT
    , CAST(G.CNT AS NUMERIC(20,6))
      / NULLIF(CAST(B.TOTAL_DEVICE AS NUMERIC(20,6)), 0) AS WEARABLE_PCT
    , COALESCE(BS.BRAND_CNT, 0) AS WEARABLE_BRAND_CNT
    , BS.BRAND_MIX              AS WEARABLE_BRAND_MIX

    /* === Per-brand device counts for Wearable === */
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'APPLE WATCH'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS WEARABLE_BRAND_APPLE_WATCH_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'GOOGLE PIXEL WATCH'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS WEARABLE_BRAND_GOOGLE_PIXEL_WATCH_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'SAMSUNG GALAXY WATCH'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS WEARABLE_BRAND_SAMSUNG_GALAXY_WATCH_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'IMOO'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS WEARABLE_BRAND_IMOO_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'FITBIT'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS WEARABLE_BRAND_FITBIT_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'GARMIN'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS WEARABLE_BRAND_GARMIN_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'AMAZFIT'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS WEARABLE_BRAND_AMAZFIT_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'HUAWEI'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS WEARABLE_BRAND_HUAWEI_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'HONOR'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS WEARABLE_BRAND_HONOR_CNT
    , COALESCE(SUM(CASE WHEN BC.BRAND = 'OTHER/UNMAPPED'
                        THEN BC.BRAND_DEVICE_CNT ELSE 0 END), 0) AS WEARABLE_BRAND_OTHER_UNMAPPED_CNT

FROM TEMP_HBB_GROUP_CNT G
JOIN TEMP_HBB_AGG_BASE B
  ON B.MNTH_ID = G.MNTH_ID
 AND B.CIRCUIT = G.CIRCUIT
LEFT JOIN TEMP_HBB_BRAND_STATS BS
  ON BS.MNTH_ID      = G.MNTH_ID
 AND BS.CIRCUIT      = G.CIRCUIT
 AND BS.DEVICE_GROUP = G.DEVICE_GROUP
LEFT JOIN TEMP_HBB_BRAND_DEVICE_CNT BC
  ON BC.MNTH_ID      = G.MNTH_ID
 AND BC.CIRCUIT      = G.CIRCUIT
 AND BC.DEVICE_GROUP = G.DEVICE_GROUP
WHERE G.DEVICE_GROUP = 'Wearable'
GROUP BY
      G.MNTH_ID
    , G.CIRCUIT
    , G.CNT
    , B.TOTAL_DEVICE
    , BS.BRAND_CNT
    , BS.BRAND_MIX
DISTRIBUTE ON (MNTH_ID, CIRCUIT);


DROP TABLE TEMP_HBB_IOT_CAT_BASE IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_IOT_CAT_BASE AS
SELECT
      MNTH_ID
    , CIRCUIT
    , COALESCE(HN, '__NULL__') AS HOST_KEY
    , TRIM(DEVICE_CAT)         AS DEVICE_CAT
FROM TEMP_CURCUIT_DATA_DEVICE_CAT
WHERE DEVICE_GROUP = 'IoT_SmartHome'
  AND DEVICE_CAT IS NOT NULL
DISTRIBUTE ON (MNTH_ID, CIRCUIT);

DROP TABLE TEMP_HBB_IOT_CAT_CNT IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_IOT_CAT_CNT AS
SELECT
      MNTH_ID
    , CIRCUIT
    , COUNT(DISTINCT DEVICE_CAT) AS IOT_CAT_CNT

    , SUM(CASE WHEN DEVICE_CAT = 'IoT_Other'               THEN 1 ELSE 0 END) AS IOT_CAT_IOT_OTHER_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Printer'                 THEN 1 ELSE 0 END) AS IOT_CAT_PRINTER_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Air Purifier'            THEN 1 ELSE 0 END) AS IOT_CAT_AIR_PURIFIER_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Washing Machine'         THEN 1 ELSE 0 END) AS IOT_CAT_WASHING_MACHINE_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Robot'                   THEN 1 ELSE 0 END) AS IOT_CAT_ROBOT_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Voice Assistant Speaker' THEN 1 ELSE 0 END) AS IOT_CAT_VOICE_ASSISTANT_SPEAKER_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Air Conditioner'         THEN 1 ELSE 0 END) AS IOT_CAT_AIR_CONDITIONER_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Robot Vacuum'            THEN 1 ELSE 0 END) AS IOT_CAT_ROBOT_VACUUM_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Smart Speaker'           THEN 1 ELSE 0 END) AS IOT_CAT_SMART_SPEAKER_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Fan'                     THEN 1 ELSE 0 END) AS IOT_CAT_FAN_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'DriveRack'               THEN 1 ELSE 0 END) AS IOT_CAT_DRIVERACK_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Smart Bulb'              THEN 1 ELSE 0 END) AS IOT_CAT_SMART_BULB_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Fridge'                  THEN 1 ELSE 0 END) AS IOT_CAT_FRIDGE_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Water Purifier'          THEN 1 ELSE 0 END) AS IOT_CAT_WATER_PURIFIER_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Bluetooth Speaker'       THEN 1 ELSE 0 END) AS IOT_CAT_BLUETOOTH_SPEAKER_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Smart Plug'              THEN 1 ELSE 0 END) AS IOT_CAT_SMART_PLUG_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Pet Feeder'              THEN 1 ELSE 0 END) AS IOT_CAT_PET_FEEDER_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Dehumidifier'            THEN 1 ELSE 0 END) AS IOT_CAT_DEHUMIDIFIER_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Audio Streamer'          THEN 1 ELSE 0 END) AS IOT_CAT_AUDIO_STREAMER_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Stick Vacuum'            THEN 1 ELSE 0 END) AS IOT_CAT_STICK_VACUUM_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Airfryer'                THEN 1 ELSE 0 END) AS IOT_CAT_AIRFRYER_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Soundbar'                THEN 1 ELSE 0 END) AS IOT_CAT_SOUNDBAR_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Dryer'                   THEN 1 ELSE 0 END) AS IOT_CAT_DRYER_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Smart Hub/Gateway'       THEN 1 ELSE 0 END) AS IOT_CAT_SMART_HUB_GATEWAY_CNT
    , SUM(CASE WHEN DEVICE_CAT = 'Smart Scale'             THEN 1 ELSE 0 END) AS IOT_CAT_SMART_SCALE_CNT
FROM TEMP_HBB_IOT_CAT_BASE
GROUP BY
      MNTH_ID
    , CIRCUIT
DISTRIBUTE ON (MNTH_ID, CIRCUIT);


DROP TABLE TEMP_HBB_IOT_CAT_MIX IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_IOT_CAT_MIX AS
SELECT
     MNTH_ID
    ,CIRCUIT
    ,RTRIM(
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'IoT_Other'             THEN 1 ELSE 0 END) = 1 THEN 'IoT_Other+'             ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Printer'               THEN 1 ELSE 0 END) = 1 THEN 'Printer+'               ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Air Purifier'          THEN 1 ELSE 0 END) = 1 THEN 'Air Purifier+'          ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Washing Machine'       THEN 1 ELSE 0 END) = 1 THEN 'Washing Machine+'       ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Robot'                 THEN 1 ELSE 0 END) = 1 THEN 'Robot+'                 ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Voice Assistant Speaker' THEN 1 ELSE 0 END) = 1 THEN 'Voice Assistant Speaker+' ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Air Conditioner'       THEN 1 ELSE 0 END) = 1 THEN 'Air Conditioner+'       ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Robot Vacuum'          THEN 1 ELSE 0 END) = 1 THEN 'Robot Vacuum+'          ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Smart Speaker'         THEN 1 ELSE 0 END) = 1 THEN 'Smart Speaker+'         ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Fan'                   THEN 1 ELSE 0 END) = 1 THEN 'Fan+'                   ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'DriveRack'             THEN 1 ELSE 0 END) = 1 THEN 'DriveRack+'             ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Smart Bulb'            THEN 1 ELSE 0 END) = 1 THEN 'Smart Bulb+'            ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Fridge'                THEN 1 ELSE 0 END) = 1 THEN 'Fridge+'                ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Water Purifier'        THEN 1 ELSE 0 END) = 1 THEN 'Water Purifier+'        ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Bluetooth Speaker'     THEN 1 ELSE 0 END) = 1 THEN 'Bluetooth Speaker+'     ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Smart Plug'            THEN 1 ELSE 0 END) = 1 THEN 'Smart Plug+'            ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Pet Feeder'            THEN 1 ELSE 0 END) = 1 THEN 'Pet Feeder+'            ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Dehumidifier'          THEN 1 ELSE 0 END) = 1 THEN 'Dehumidifier+'          ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Audio Streamer'        THEN 1 ELSE 0 END) = 1 THEN 'Audio Streamer+'        ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Stick Vacuum'          THEN 1 ELSE 0 END) = 1 THEN 'Stick Vacuum+'          ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Airfryer'              THEN 1 ELSE 0 END) = 1 THEN 'Airfryer+'              ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Soundbar'              THEN 1 ELSE 0 END) = 1 THEN 'Soundbar+'              ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Dryer'                 THEN 1 ELSE 0 END) = 1 THEN 'Dryer+'                 ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Smart Hub/Gateway'     THEN 1 ELSE 0 END) = 1 THEN 'Smart Hub/Gateway+'     ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_CAT = 'Smart Scale'           THEN 1 ELSE 0 END) = 1 THEN 'Smart Scale+'           ELSE '' END),
        '+'
    ) AS IOT_CAT_MIX
FROM TEMP_HBB_IOT_CAT_BASE
GROUP BY MNTH_ID
		,CIRCUIT
DISTRIBUTE ON (MNTH_ID, CIRCUIT);

DROP TABLE TEMP_HBB_DEVICE_GRP_BASE IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_DEVICE_GRP_BASE AS
SELECT DISTINCT
     MNTH_ID
    ,CIRCUIT
    ,CASE 
        WHEN UPPER(DEVICE_GROUP) IN ('UNKNOWN', 'OTHER') THEN 'Other'
        ELSE DEVICE_GROUP
    END AS DEVICE_GROUP
FROM TEMP_CURCUIT_DATA_DEVICE_CAT
WHERE DEVICE_GROUP IS NOT NULL
DISTRIBUTE ON (MNTH_ID, CIRCUIT);



DROP TABLE TEMP_HBB_DEVICE_GRP_CNT IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_DEVICE_GRP_CNT AS
SELECT
     MNTH_ID
    ,CIRCUIT
    ,COUNT(DISTINCT DEVICE_GROUP) AS DEVICE_GRP_CNT
FROM TEMP_HBB_DEVICE_GRP_BASE
GROUP BY MNTH_ID, CIRCUIT
DISTRIBUTE ON (MNTH_ID, CIRCUIT);



DROP TABLE TEMP_HBB_DEVICE_GRP_MIX IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_DEVICE_GRP_MIX AS
SELECT
     MNTH_ID
    ,CIRCUIT
    ,RTRIM(
        (CASE WHEN MAX(CASE WHEN DEVICE_GROUP = 'Mobile_Smartphone' THEN 1 ELSE 0 END) = 1
              THEN 'Mobile_Smartphone+' ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_GROUP = 'Mobile_Tablet'     THEN 1 ELSE 0 END) = 1
              THEN 'Mobile_Tablet+'     ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_GROUP = 'PC_Laptop'         THEN 1 ELSE 0 END) = 1
              THEN 'PC_Laptop+'         ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_GROUP = 'TV'                THEN 1 ELSE 0 END) = 1
              THEN 'TV+'                ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_GROUP = 'TV_BOX'            THEN 1 ELSE 0 END) = 1
              THEN 'TV_BOX+'            ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_GROUP = 'Camera_CCTV'       THEN 1 ELSE 0 END) = 1
              THEN 'Camera_CCTV+'       ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_GROUP = 'IoT_SmartHome'     THEN 1 ELSE 0 END) = 1
              THEN 'IoT_SmartHome+'     ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_GROUP = 'MESH_WIFI'         THEN 1 ELSE 0 END) = 1
              THEN 'MESH_WIFI+'         ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_GROUP = 'Wearable'          THEN 1 ELSE 0 END) = 1
              THEN 'Wearable+'          ELSE '' END) ||
        (CASE WHEN MAX(CASE WHEN DEVICE_GROUP = 'Other'             THEN 1 ELSE 0 END) = 1
              THEN 'Other+'             ELSE '' END),
        '+'
    ) AS DEVICE_GRP_MIX
FROM TEMP_HBB_DEVICE_GRP_BASE
GROUP BY MNTH_ID
		,CIRCUIT
DISTRIBUTE ON (MNTH_ID, CIRCUIT);


DROP TABLE TEMP_HBB_OTHER_GRP IF EXISTS;

CREATE TEMP TABLE TEMP_HBB_OTHER_GRP AS
WITH BASE AS (
    SELECT
          MNTH_ID
        , CIRCUIT
        , COALESCE(HN, '__NULL__') AS HOST_KEY
        , CASE 
              WHEN UPPER(DEVICE_GROUP) IN ('UNKNOWN','OTHER') THEN 'Other'
              ELSE DEVICE_GROUP
          END AS DEVICE_GROUP
    FROM TEMP_CURCUIT_DATA_DEVICE_CAT
)
, OTHER_CNT AS (
    SELECT
          MNTH_ID
        , CIRCUIT
        , COUNT(DISTINCT CASE WHEN DEVICE_GROUP = 'Other' THEN HOST_KEY END) AS OTHER_GROUP_CNT
    FROM BASE
    GROUP BY
          MNTH_ID
        , CIRCUIT
)
SELECT
      O.MNTH_ID
    , O.CIRCUIT
    , CASE WHEN O.OTHER_GROUP_CNT > 0 THEN 1 ELSE 0 END AS OTHER_GROUP_FLAG
    , O.OTHER_GROUP_CNT
    , CAST(O.OTHER_GROUP_CNT AS NUMERIC(20,6))
      / NULLIF(CAST(B.TOTAL_DEVICE AS NUMERIC(20,6)), 0) AS OTHER_GROUP_PCT
FROM OTHER_CNT O
LEFT JOIN TEMP_HBB_AGG_BASE B
  ON B.MNTH_ID = O.MNTH_ID
 AND B.CIRCUIT = O.CIRCUIT
DISTRIBUTE ON (MNTH_ID, CIRCUIT);



-- CREATE THE FINAL AGGREGATE TABLE

DROP TABLE SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE_EXTENDED IF EXISTS;

CREATE TABLE SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE_EXTENDED AS
SELECT
     B.MNTH_ID
    ,B.CIRCUIT
    ,B.TOTAL_DEVICE
    ,COALESCE(dgc.DEVICE_GRP_CNT, 0) AS DEVICE_GRP_CNT
    ,dgm.DEVICE_GRP_MIX
    /* ============================
       Mobile_Smartphone
       ============================ */
  , COALESCE(m.MOBILE_FLAG,      0) AS MOBILE_FLAG
  , COALESCE(m.MOBILE_CNT,       0) AS MOBILE_CNT
  , COALESCE(m.MOBILE_PCT,       0) AS MOBILE_PCT
  , COALESCE(m.MOBILE_BRAND_CNT, 0) AS MOBILE_BRAND_CNT
  , m.MOBILE_BRAND_MIX

  , COALESCE(m.MOBILE_BRAND_APPLE_CNT,          0) AS MOBILE_BRAND_APPLE_CNT
  , COALESCE(m.MOBILE_BRAND_SAMSUNG_CNT,        0) AS MOBILE_BRAND_SAMSUNG_CNT
  , COALESCE(m.MOBILE_BRAND_OPPO_CNT,           0) AS MOBILE_BRAND_OPPO_CNT
  , COALESCE(m.MOBILE_BRAND_VIVO_CNT,           0) AS MOBILE_BRAND_VIVO_CNT
  , COALESCE(m.MOBILE_BRAND_REALME_CNT,         0) AS MOBILE_BRAND_REALME_CNT
  , COALESCE(m.MOBILE_BRAND_XIAOMI_CNT,         0) AS MOBILE_BRAND_XIAOMI_CNT
  , COALESCE(m.MOBILE_BRAND_HUAWEI_CNT,         0) AS MOBILE_BRAND_HUAWEI_CNT
  , COALESCE(m.MOBILE_BRAND_HONOR_CNT,          0) AS MOBILE_BRAND_HONOR_CNT
  , COALESCE(m.MOBILE_BRAND_ONEPLUS_CNT,        0) AS MOBILE_BRAND_ONEPLUS_CNT
  , COALESCE(m.MOBILE_BRAND_INFINIX_CNT,        0) AS MOBILE_BRAND_INFINIX_CNT
  , COALESCE(m.MOBILE_BRAND_TECNO_CNT,          0) AS MOBILE_BRAND_TECNO_CNT
  , COALESCE(m.MOBILE_BRAND_NOKIA_CNT,          0) AS MOBILE_BRAND_NOKIA_CNT
  , COALESCE(m.MOBILE_BRAND_ASUS_CNT,           0) AS MOBILE_BRAND_ASUS_CNT
  , COALESCE(m.MOBILE_BRAND_LENOVO_CNT,         0) AS MOBILE_BRAND_LENOVO_CNT
  , COALESCE(m.MOBILE_BRAND_MOTOROLA_CNT,       0) AS MOBILE_BRAND_MOTOROLA_CNT
  , COALESCE(m.MOBILE_BRAND_MEIZU_CNT,          0) AS MOBILE_BRAND_MEIZU_CNT
  , COALESCE(m.MOBILE_BRAND_ZTE_CNT,            0) AS MOBILE_BRAND_ZTE_CNT
  , COALESCE(m.MOBILE_BRAND_GOOGLE_CNT,         0) AS MOBILE_BRAND_GOOGLE_CNT
  , COALESCE(m.MOBILE_BRAND_NOTHING_CNT,        0) AS MOBILE_BRAND_NOTHING_CNT
  , COALESCE(m.MOBILE_BRAND_BENCO_CNT,          0) AS MOBILE_BRAND_BENCO_CNT
  , COALESCE(m.MOBILE_BRAND_IQOO_CNT,           0) AS MOBILE_BRAND_IQOO_CNT
  , COALESCE(m.MOBILE_BRAND_ITEL_CNT,           0) AS MOBILE_BRAND_ITEL_CNT
  , COALESCE(m.MOBILE_BRAND_ALTRON_CNT,         0) AS MOBILE_BRAND_ALTRON_CNT
  , COALESCE(m.MOBILE_BRAND_WIKO_CNT,           0) AS MOBILE_BRAND_WIKO_CNT
  , COALESCE(m.MOBILE_BRAND_OPER_CNT,           0) AS MOBILE_BRAND_OPER_CNT
  , COALESCE(m.MOBILE_BRAND_AIS_CNT,            0) AS MOBILE_BRAND_AIS_CNT
  , COALESCE(m.MOBILE_BRAND_ANDROID_CNT,        0) AS MOBILE_BRAND_ANDROID_CNT
  , COALESCE(m.MOBILE_BRAND_TCL_CNT,            0) AS MOBILE_BRAND_TCL_CNT
  , COALESCE(m.MOBILE_BRAND_NINETOLOGY_CNT,     0) AS MOBILE_BRAND_NINETOLOGY_CNT
  , COALESCE(m.MOBILE_BRAND_YIJIA_CNT,          0) AS MOBILE_BRAND_YIJIA_CNT
  , COALESCE(m.MOBILE_BRAND_HMD_CNT,            0) AS MOBILE_BRAND_HMD_CNT
  , COALESCE(m.MOBILE_BRAND_DOOGEE_CNT,         0) AS MOBILE_BRAND_DOOGEE_CNT
  , COALESCE(m.MOBILE_BRAND_YUNOS_CNT,          0) AS MOBILE_BRAND_YUNOS_CNT
  , COALESCE(m.MOBILE_BRAND_OTHER_UNMAPPED_CNT, 0) AS MOBILE_BRAND_OTHER_UNMAPPED_CNT

    /* ============================
       Mobile_Tablet
       ============================ */
  , COALESCE(t.TABLET_FLAG,      0) AS TABLET_FLAG
  , COALESCE(t.TABLET_CNT,       0) AS TABLET_CNT
  , COALESCE(t.TABLET_PCT,       0) AS TABLET_PCT
  , COALESCE(t.TABLET_BRAND_CNT, 0) AS TABLET_BRAND_CNT
  , t.TABLET_BRAND_MIX

  , COALESCE(t.TABLET_BRAND_APPLE_CNT,          0) AS TABLET_BRAND_APPLE_CNT
  , COALESCE(t.TABLET_BRAND_SAMSUNG_CNT,        0) AS TABLET_BRAND_SAMSUNG_CNT
  , COALESCE(t.TABLET_BRAND_OPPO_CNT,           0) AS TABLET_BRAND_OPPO_CNT
  , COALESCE(t.TABLET_BRAND_VIVO_CNT,           0) AS TABLET_BRAND_VIVO_CNT
  , COALESCE(t.TABLET_BRAND_REALME_CNT,         0) AS TABLET_BRAND_REALME_CNT
  , COALESCE(t.TABLET_BRAND_XIAOMI_CNT,         0) AS TABLET_BRAND_XIAOMI_CNT
  , COALESCE(t.TABLET_BRAND_HUAWEI_CNT,         0) AS TABLET_BRAND_HUAWEI_CNT
  , COALESCE(t.TABLET_BRAND_HONOR_CNT,          0) AS TABLET_BRAND_HONOR_CNT
  , COALESCE(t.TABLET_BRAND_ONEPLUS_CNT,        0) AS TABLET_BRAND_ONEPLUS_CNT
  , COALESCE(t.TABLET_BRAND_INFINIX_CNT,        0) AS TABLET_BRAND_INFINIX_CNT
  , COALESCE(t.TABLET_BRAND_LENOVO_CNT,         0) AS TABLET_BRAND_LENOVO_CNT

  , COALESCE(t.TABLET_BRAND_TCL_CNT,            0) AS TABLET_BRAND_TCL_CNT

  , COALESCE(t.TABLET_BRAND_ALLDOCUBE_CNT,      0) AS TABLET_BRAND_ALLDOCUBE_CNT
  , COALESCE(t.TABLET_BRAND_GIANTPAD_CNT,       0) AS TABLET_BRAND_GIANTPAD_CNT
  , COALESCE(t.TABLET_BRAND_ORVIBO_CNT,         0) AS TABLET_BRAND_ORVIBO_CNT
  , COALESCE(t.TABLET_BRAND_VALVE_CNT,          0) AS TABLET_BRAND_VALVE_CNT
  , COALESCE(t.TABLET_BRAND_CHUWI_CNT,          0) AS TABLET_BRAND_CHUWI_CNT
  , COALESCE(t.TABLET_BRAND_BMAX_CNT,           0) AS TABLET_BRAND_BMAX_CNT
  , COALESCE(t.TABLET_BRAND_DENGO_CNT,          0) AS TABLET_BRAND_DENGO_CNT
  , COALESCE(t.TABLET_BRAND_WEALTHY_CNT,        0) AS TABLET_BRAND_WEALTHY_CNT

  , COALESCE(t.TABLET_BRAND_OTHER_UNMAPPED_CNT, 0) AS TABLET_BRAND_OTHER_UNMAPPED_CNT

    /* ============================
       PC_Laptop
       ============================ */
  , COALESCE(pc.PC_LAPTOP_FLAG,      0) AS PC_LAPTOP_FLAG
  , COALESCE(pc.PC_LAPTOP_CNT,       0) AS PC_LAPTOP_CNT
  , COALESCE(pc.PC_LAPTOP_PCT,       0) AS PC_LAPTOP_PCT
  , COALESCE(pc.PC_LAPTOP_BRAND_CNT, 0) AS PC_LAPTOP_BRAND_CNT
  , pc.PC_LAPTOP_BRAND_MIX

  , COALESCE(pc.PC_LAPTOP_BRAND_APPLE_CNT,         0) AS PC_BRAND_APPLE_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_SAMSUNG_CNT,       0) AS PC_BRAND_SAMSUNG_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_DELL_CNT,          0) AS PC_BRAND_DELL_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_HP_CNT,            0) AS PC_BRAND_HP_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_LENOVO_CNT,        0) AS PC_BRAND_LENOVO_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_ASUS_CNT,          0) AS PC_BRAND_ASUS_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_ACER_CNT,          0) AS PC_BRAND_ACER_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_MSI_CNT,           0) AS PC_BRAND_MSI_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_FUJITSU_CNT,       0) AS PC_BRAND_FUJITSU_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_NEC_CNT,           0) AS PC_BRAND_NEC_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_SONY_CNT,          0) AS PC_BRAND_SONY_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_COMPAQ_CNT,        0) AS PC_BRAND_COMPAQ_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_GIGABYTE_CNT,      0) AS PC_BRAND_GIGABYTE_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_EMACHINES_CNT,     0) AS PC_BRAND_EMACHINES_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_MICROSOFT_SURFACE_CNT, 0) AS PC_BRAND_MICROSOFT_SURFACE_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_INFINIX_INBOOK_CNT,    0) AS PC_BRAND_INFINIX_INBOOK_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_TOSHIBA_CNT,       0) AS PC_BRAND_TOSHIBA_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_HUAWEI_CNT,        0) AS PC_BRAND_HUAWEI_CNT
  , COALESCE(pc.PC_LAPTOP_BRAND_OTHER_UNMAPPED_CNT,0) AS PC_BRAND_OTHER_UNMAPPED_CNT

    /* ============================
       TV
       ============================ */
  , COALESCE(tv.TV_FLAG,      0) AS TV_FLAG
  , COALESCE(tv.TV_CNT,       0) AS TV_CNT
  , COALESCE(tv.TV_PCT,       0) AS TV_PCT
  , COALESCE(tv.TV_BRAND_CNT, 0) AS TV_BRAND_CNT
  , tv.TV_BRAND_MIX

  , COALESCE(tv.TV_BRAND_LG_CNT,            0) AS TV_BRAND_LG_CNT
  , COALESCE(tv.TV_BRAND_SAMSUNG_CNT,       0) AS TV_BRAND_SAMSUNG_CNT
  , COALESCE(tv.TV_BRAND_TCL_CNT,           0) AS TV_BRAND_TCL_CNT
  , COALESCE(tv.TV_BRAND_TOSHIBA_CNT,       0) AS TV_BRAND_TOSHIBA_CNT
  , COALESCE(tv.TV_BRAND_COOLITA_CNT,       0) AS TV_BRAND_COOLITA_CNT
  , COALESCE(tv.TV_BRAND_GOOGLE_TV_CNT,     0) AS TV_BRAND_GOOGLE_TV_CNT
  , COALESCE(tv.TV_BRAND_BEYONDTV_CNT,      0) AS TV_BRAND_BEYONDTV_CNT
  , COALESCE(tv.TV_BRAND_XIAOMI_CNT,        0) AS TV_BRAND_XIAOMI_CNT
  , COALESCE(tv.TV_BRAND_SONY_CNT,          0) AS TV_BRAND_SONY_CNT
  , COALESCE(tv.TV_BRAND_OTHER_UNMAPPED_CNT,0) AS TV_BRAND_OTHER_UNMAPPED_CNT

    /* ============================
       TV_BOX
       ============================ */
  , COALESCE(tb.TV_BOX_FLAG,      0) AS TV_BOX_FLAG
  , COALESCE(tb.TV_BOX_CNT,       0) AS TV_BOX_CNT
  , COALESCE(tb.TV_BOX_PCT,       0) AS TV_BOX_PCT
  , COALESCE(tb.TV_BOX_BRAND_CNT, 0) AS TV_BOX_BRAND_CNT
  , tb.TV_BOX_BRAND_MIX

  , COALESCE(tb.TV_BOX_BRAND_APPLE_TV_CNT,         0) AS TV_BOX_BRAND_APPLE_TV_CNT
  , COALESCE(tb.TV_BOX_BRAND_GOOGLE_CHROMECAST_CNT,       0) AS TV_BOX_BRAND_CHROMECAST_CNT
  , COALESCE(tb.TV_BOX_BRAND_OPTV_CNT,         0) AS TV_BOX_BRAND_OPTV_CNT
  , COALESCE(tb.TV_BOX_BRAND_AIS_PLAYBOX_CNT,      0) AS TV_BOX_BRAND_AIS_PLAYBOX_CNT
  , COALESCE(tb.TV_BOX_BRAND_NOKIA_STREAMING_BOX_CNT, 0) AS TV_BOX_BRAND_NOKIA_STREAMING_BOX_CNT
  , COALESCE(tb.TV_BOX_BRAND_X96_ANDROID_BOX_CNT,          0) AS TV_BOX_BRAND_X96_BOX_CNT
  , COALESCE(tb.TV_BOX_BRAND_HISILICON_BOX_CNT,    0) AS TV_BOX_BRAND_HISILICON_BOX_CNT
  , COALESCE(tb.TV_BOX_BRAND_MICROSOFT_XBOX_CNT,             0) AS TV_BOX_BRAND_XBOX_CNT
  , COALESCE(tb.TV_BOX_BRAND_OTHER_UNMAPPED_CNT,   0) AS TV_BOX_BRAND_OTHER_UNMAPPED_CNT

    /* ============================
       Camera_CCTV
       ============================ */
  , COALESCE(cam.CAMERA_CCTV_FLAG,      0) AS CAMERA_CCTV_FLAG
  , COALESCE(cam.CAMERA_CCTV_CNT,       0) AS CAMERA_CCTV_CNT
  , COALESCE(cam.CAMERA_CCTV_PCT,       0) AS CAMERA_CCTV_PCT
  , COALESCE(cam.CAMERA_CCTV_BRAND_CNT, 0) AS CAMERA_CCTV_BRAND_CNT
  , cam.CAMERA_CCTV_BRAND_MIX

  , COALESCE(cam.CAMERA_CCTV_BRAND_OPER_CNT,          0) AS CAMERA_BRAND_OPER_CNT
  , COALESCE(cam.CAMERA_CCTV_BRAND_NOMI_CNT,          0) AS CAMERA_BRAND_NOMI_CNT
  , COALESCE(cam.CAMERA_CCTV_BRAND_EZVIZ_CNT,         0) AS CAMERA_BRAND_EZVIZ_CNT
  , COALESCE(cam.CAMERA_CCTV_BRAND_XIAOMI_CNT,        0) AS CAMERA_BRAND_XIAOMI_CNT
  , COALESCE(cam.CAMERA_CCTV_BRAND_TP_LINK_TAPO_CNT,  0) AS CAMERA_BRAND_TP_LINK_TAPO_CNT
  , COALESCE(cam.CAMERA_CCTV_BRAND_GOOGLE_NEST_CNT,   0) AS CAMERA_BRAND_GOOGLE_NEST_CNT
  , COALESCE(cam.CAMERA_CCTV_BRAND_WYZE_CNT,          0) AS CAMERA_BRAND_WYZE_CNT
  , COALESCE(cam.CAMERA_CCTV_BRAND_360_CNT,           0) AS CAMERA_BRAND_360_CNT
  , COALESCE(cam.CAMERA_CCTV_BRAND_MXIANG_CNT,        0) AS CAMERA_BRAND_MXIANG_CNT
  , COALESCE(cam.CAMERA_CCTV_BRAND_JD_CAMERA_CNT,     0) AS CAMERA_BRAND_JD_CAMERA_CNT
  , COALESCE(cam.CAMERA_CCTV_BRAND_QCAM_CNT,          0) AS CAMERA_BRAND_QCAM_CNT
  , COALESCE(cam.CAMERA_CCTV_BRAND_IMOU_CNT,          0) AS CAMERA_BRAND_IMOU_CNT
  , COALESCE(cam.CAMERA_CCTV_BRAND_OTHER_UNMAPPED_CNT,0) AS CAMERA_BRAND_OTHER_UNMAPPED_CNT

    /* ============================
       IoT_SmartHome
       ============================ */
  , COALESCE(iot.IOT_SMARTHOME_FLAG,      0) AS IOT_SMARTHOME_FLAG
  , COALESCE(iot.IOT_SMARTHOME_CNT,       0) AS IOT_SMARTHOME_CNT
  , COALESCE(iot.IOT_SMARTHOME_PCT,       0) AS IOT_SMARTHOME_PCT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_CNT, 0) AS IOT_SMARTHOME_BRAND_CNT
  , iot.IOT_SMARTHOME_BRAND_MIX

  , COALESCE(iot.IOT_SMARTHOME_BRAND_MARSHALL_CNT,         0) AS IOT_BRAND_MARSHALL_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_XIAOMI_CNT,           0) AS IOT_BRAND_XIAOMI_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_ROBOROCK_CNT,         0) AS IOT_BRAND_ROBOROCK_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_DREAME_CNT,           0) AS IOT_BRAND_DREAME_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_IROBOT_CNT,           0) AS IOT_BRAND_IROBOT_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_NARWAL_CNT,           0) AS IOT_BRAND_NARWAL_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_PETKIT_CNT,           0) AS IOT_BRAND_PETKIT_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_BLACKVUE_CNT,         0) AS IOT_BRAND_BLACKVUE_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_UBPET_CNT,            0) AS IOT_BRAND_UBPET_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_GOOGLE_CNT,           0) AS IOT_BRAND_GOOGLE_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_APPLE_HOMEPOD_CNT,    0) AS IOT_BRAND_APPLE_HOMEPOD_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_SONOS_CNT,            0) AS IOT_BRAND_SONOS_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_BOSE_SMART_CNT,       0) AS IOT_BRAND_BOSE_SMART_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_JBL_CNT,              0) AS IOT_BRAND_JBL_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_AUDIOCAST_CNT,        0) AS IOT_BRAND_AUDIOCAST_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_TP_LINK_TAPO_CNT,     0) AS IOT_BRAND_TP_LINK_TAPO_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_LG_SMARTAPPLIANCE_CNT,0) AS IOT_BRAND_LG_SMARTAPPLIANCE_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_ELECTROLUX_CNT,       0) AS IOT_BRAND_ELECTROLUX_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_LEVOIT_CNT,           0) AS IOT_BRAND_LEVOIT_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_TESLA_CNT,            0) AS IOT_BRAND_TESLA_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_DBX_AUDIO_CNT,        0) AS IOT_BRAND_DBX_AUDIO_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_K12_AUDIO_CNT,        0) AS IOT_BRAND_K12_AUDIO_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_SKG_AUDIO_CNT,        0) AS IOT_BRAND_SKG_AUDIO_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_RENAC_CNT,            0) AS IOT_BRAND_RENAC_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_HOMEMATE_CNT,         0) AS IOT_BRAND_HOMEMATE_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_ROCKCHIP_ROBOT_CNT,   0) AS IOT_BRAND_ROCKCHIP_ROBOT_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_EPSON_CNT,            0) AS IOT_BRAND_EPSON_CNT
  , COALESCE(iot.IOT_SMARTHOME_BRAND_OTHER_UNMAPPED_CNT,   0) AS IOT_BRAND_OTHER_UNMAPPED_CNT

      /* IoT categories */
  , COALESCE(iotc.IOT_CAT_CNT, 0) AS IOT_CAT_CNT
  , iotm.IOT_CAT_MIX

  , COALESCE(iotc.IOT_CAT_IOT_OTHER_CNT,             0) AS IOT_CAT_IOT_OTHER_CNT
  , COALESCE(iotc.IOT_CAT_PRINTER_CNT,               0) AS IOT_CAT_PRINTER_CNT
  , COALESCE(iotc.IOT_CAT_AIR_PURIFIER_CNT,          0) AS IOT_CAT_AIR_PURIFIER_CNT
  , COALESCE(iotc.IOT_CAT_WASHING_MACHINE_CNT,       0) AS IOT_CAT_WASHING_MACHINE_CNT
  , COALESCE(iotc.IOT_CAT_ROBOT_CNT,                 0) AS IOT_CAT_ROBOT_CNT
  , COALESCE(iotc.IOT_CAT_VOICE_ASSISTANT_SPEAKER_CNT,0) AS IOT_CAT_VOICE_ASSISTANT_SPEAKER_CNT
  , COALESCE(iotc.IOT_CAT_AIR_CONDITIONER_CNT,       0) AS IOT_CAT_AIR_CONDITIONER_CNT
  , COALESCE(iotc.IOT_CAT_ROBOT_VACUUM_CNT,          0) AS IOT_CAT_ROBOT_VACUUM_CNT
  , COALESCE(iotc.IOT_CAT_SMART_SPEAKER_CNT,         0) AS IOT_CAT_SMART_SPEAKER_CNT
  , COALESCE(iotc.IOT_CAT_FAN_CNT,                   0) AS IOT_CAT_FAN_CNT
  , COALESCE(iotc.IOT_CAT_DRIVERACK_CNT,             0) AS IOT_CAT_DRIVERACK_CNT
  , COALESCE(iotc.IOT_CAT_SMART_BULB_CNT,            0) AS IOT_CAT_SMART_BULB_CNT
  , COALESCE(iotc.IOT_CAT_FRIDGE_CNT,                0) AS IOT_CAT_FRIDGE_CNT
  , COALESCE(iotc.IOT_CAT_WATER_PURIFIER_CNT,        0) AS IOT_CAT_WATER_PURIFIER_CNT
  , COALESCE(iotc.IOT_CAT_BLUETOOTH_SPEAKER_CNT,     0) AS IOT_CAT_BLUETOOTH_SPEAKER_CNT
  , COALESCE(iotc.IOT_CAT_SMART_PLUG_CNT,            0) AS IOT_CAT_SMART_PLUG_CNT
  , COALESCE(iotc.IOT_CAT_PET_FEEDER_CNT,            0) AS IOT_CAT_PET_FEEDER_CNT
  , COALESCE(iotc.IOT_CAT_DEHUMIDIFIER_CNT,          0) AS IOT_CAT_DEHUMIDIFIER_CNT
  , COALESCE(iotc.IOT_CAT_AUDIO_STREAMER_CNT,        0) AS IOT_CAT_AUDIO_STREAMER_CNT
  , COALESCE(iotc.IOT_CAT_STICK_VACUUM_CNT,          0) AS IOT_CAT_STICK_VACUUM_CNT
  , COALESCE(iotc.IOT_CAT_AIRFRYER_CNT,              0) AS IOT_CAT_AIRFRYER_CNT
  , COALESCE(iotc.IOT_CAT_SOUNDBAR_CNT,              0) AS IOT_CAT_SOUNDBAR_CNT
  , COALESCE(iotc.IOT_CAT_DRYER_CNT,                 0) AS IOT_CAT_DRYER_CNT
  , COALESCE(iotc.IOT_CAT_SMART_HUB_GATEWAY_CNT,     0) AS IOT_CAT_SMART_HUB_GATEWAY_CNT
  , COALESCE(iotc.IOT_CAT_SMART_SCALE_CNT,           0) AS IOT_CAT_SMART_SCALE_CNT

    /* ============================
       MESH_WIFI
       ============================ */
  , COALESCE(mw.MESH_WIFI_FLAG,      0) AS MESH_WIFI_FLAG
  , COALESCE(mw.MESH_WIFI_CNT,       0) AS MESH_WIFI_CNT
  , COALESCE(mw.MESH_WIFI_PCT,       0) AS MESH_WIFI_PCT
  , COALESCE(mw.MESH_WIFI_BRAND_CNT, 0) AS MESH_WIFI_BRAND_CNT
  , mw.MESH_WIFI_BRAND_MIX

  , COALESCE(mw.MESH_WIFI_BRAND_XIAOMI_CNT,          0) AS MESH_BRAND_XIAOMI_CNT
  , COALESCE(mw.MESH_WIFI_BRAND_TP_LINK_CNT,         0) AS MESH_BRAND_TP_LINK_CNT
  , COALESCE(mw.MESH_WIFI_BRAND_TENDA_CNT,           0) AS MESH_BRAND_TENDA_CNT
  , COALESCE(mw.MESH_WIFI_BRAND_FRITZ_REPEATER_CNT,  0) AS MESH_BRAND_FRITZ_REPEATER_CNT
  , COALESCE(mw.MESH_WIFI_BRAND_RASPBERRYPI_CNT,     0) AS MESH_BRAND_RASPBERRYPI_CNT
  , COALESCE(mw.MESH_WIFI_BRAND_OPMESH_CNT,        0) AS MESH_BRAND_OPMESH_CNT
  , COALESCE(mw.MESH_WIFI_BRAND_OPX_CNT,           0) AS MESH_BRAND_OPX_CNT
  , COALESCE(mw.MESH_WIFI_BRAND_GWIPC_CNT,           0) AS MESH_BRAND_GWIPC_CNT
  , COALESCE(mw.MESH_WIFI_BRAND_SKYROUTER_CNT,       0) AS MESH_BRAND_SKYROUTER_CNT
  , COALESCE(mw.MESH_WIFI_BRAND_OTHER_UNMAPPED_CNT,  0) AS MESH_BRAND_OTHER_UNMAPPED_CNT

    /* ============================
       Wearable
       ============================ */
  , COALESCE(w.WEARABLE_FLAG,      0) AS WEARABLE_FLAG
  , COALESCE(w.WEARABLE_CNT,       0) AS WEARABLE_CNT
  , COALESCE(w.WEARABLE_PCT,       0) AS WEARABLE_PCT
  , COALESCE(w.WEARABLE_BRAND_CNT, 0) AS WEARABLE_BRAND_CNT
  , w.WEARABLE_BRAND_MIX

  , COALESCE(w.WEARABLE_BRAND_APPLE_WATCH_CNT,       0) AS WEARABLE_BRAND_APPLE_WATCH_CNT
  , COALESCE(w.WEARABLE_BRAND_GOOGLE_PIXEL_WATCH_CNT,0) AS WEARABLE_BRAND_GOOGLE_PIXEL_WATCH_CNT
  , COALESCE(w.WEARABLE_BRAND_SAMSUNG_GALAXY_WATCH_CNT,      0) AS WEARABLE_BRAND_GALAXY_WATCH_CNT
  , COALESCE(w.WEARABLE_BRAND_IMOO_CNT,              0) AS WEARABLE_BRAND_IMOO_CNT
  , COALESCE(w.WEARABLE_BRAND_FITBIT_CNT,            0) AS WEARABLE_BRAND_FITBIT_CNT
  , COALESCE(w.WEARABLE_BRAND_GARMIN_CNT,            0) AS WEARABLE_BRAND_GARMIN_CNT
  , COALESCE(w.WEARABLE_BRAND_AMAZFIT_CNT,           0) AS WEARABLE_BRAND_AMAZFIT_CNT
  , COALESCE(w.WEARABLE_BRAND_HUAWEI_CNT,            0) AS WEARABLE_BRAND_HUAWEI_CNT
  , COALESCE(w.WEARABLE_BRAND_HONOR_CNT,             0) AS WEARABLE_BRAND_HONOR_CNT
  , COALESCE(w.WEARABLE_BRAND_OTHER_UNMAPPED_CNT,    0) AS WEARABLE_BRAND_OTHER_UNMAPPED_CNT
  
  
      -- NEW: Other group summary
    ,COALESCE(og.OTHER_GROUP_FLAG, 0) AS OTHER_GROUP_FLAG
    ,COALESCE(og.OTHER_GROUP_CNT,  0) AS OTHER_GROUP_CNT
    ,COALESCE(og.OTHER_GROUP_PCT,  0) AS OTHER_GROUP_PCT

FROM TEMP_HBB_AGG_BASE    b
LEFT JOIN TEMP_HBB_MOBILE   m   ON m.MNTH_ID = b.MNTH_ID AND m.CIRCUIT = b.CIRCUIT
LEFT JOIN TEMP_HBB_TABLET   t   ON t.MNTH_ID = b.MNTH_ID AND t.CIRCUIT = b.CIRCUIT
LEFT JOIN TEMP_HBB_PC       pc  ON pc.MNTH_ID = b.MNTH_ID AND pc.CIRCUIT = b.CIRCUIT
LEFT JOIN TEMP_HBB_TV       tv  ON tv.MNTH_ID = b.MNTH_ID AND tv.CIRCUIT = b.CIRCUIT
LEFT JOIN TEMP_HBB_TVBOX    tb  ON tb.MNTH_ID = b.MNTH_ID AND tb.CIRCUIT = b.CIRCUIT
LEFT JOIN TEMP_HBB_CAMERA   cam ON cam.MNTH_ID = b.MNTH_ID AND cam.CIRCUIT = b.CIRCUIT
LEFT JOIN TEMP_HBB_IOT      iot ON iot.MNTH_ID = b.MNTH_ID AND iot.CIRCUIT = b.CIRCUIT
LEFT JOIN TEMP_HBB_MESH     mw  ON mw.MNTH_ID = b.MNTH_ID AND mw.CIRCUIT = b.CIRCUIT
LEFT JOIN TEMP_HBB_WEARABLE w   ON w.MNTH_ID  = b.MNTH_ID AND w.CIRCUIT  = b.CIRCUIT
LEFT JOIN TEMP_HBB_IOT_CAT_CNT  iotc ON iotc.MNTH_ID = b.MNTH_ID AND iotc.CIRCUIT = b.CIRCUIT
LEFT JOIN TEMP_HBB_IOT_CAT_MIX  iotm ON iotm.MNTH_ID = b.MNTH_ID AND iotm.CIRCUIT = b.CIRCUIT
LEFT JOIN TEMP_HBB_DEVICE_GRP_CNT dgc ON dgc.MNTH_ID = b.MNTH_ID AND dgc.CIRCUIT = b.CIRCUIT
LEFT JOIN TEMP_HBB_DEVICE_GRP_MIX dgm ON dgm.MNTH_ID = b.MNTH_ID AND dgm.CIRCUIT = b.CIRCUIT
LEFT JOIN TEMP_HBB_OTHER_GRP og ON og.MNTH_ID = b.MNTH_ID AND og.CIRCUIT = b.CIRCUIT
DISTRIBUTE ON (MNTH_ID, CIRCUIT);





/* ============================================================
   UPDATE THE INSTALL DATE AND ARPU INTO AGG TABLE
   ============================================================ */

-- 1) Add INSTALL_DT as a timestamp
ALTER TABLE SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL
ADD COLUMN INSTALL_DT TIMESTAMP;

-- 2) Add TOTAL_BILL_AMNT as a numeric amount
ALTER TABLE SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL
ADD COLUMN TOTAL_BILL_AMNT NUMERIC(12,2);


-- UPDATE THE INSTALL_DT
UPDATE SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL T
SET INSTALL_DT = S.INSTALL_DT
FROM (
    SELECT
          A.REF_RESRE_NBR AS ASSET_NUM
        , A.INSTALL_DT
    FROM SANDBOX_NZ.ADMIN.DIM_PROD AS A
    WHERE A.PROD_TYP_CD = 2   -- HBB
      AND A.PROD_SUB_TYP IN ('I', 'IF', 'INF', 'Q', 'FT')
      AND A.DWH_PROD_STAT = 'A'
) S
WHERE T.ASSET_NUM = S.ASSET_NUM;


-- UPDATE THE TOTAL_BILL_AMNT
UPDATE SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL T
SET TOTAL_BILL_AMNT = B.TOTAL_BILL_AMNT
FROM (
    SELECT
          ASSET_NUM
        , COALESCE(TOTAL_BILL_AMNT,0) AS TOTAL_BILL_AMNT
    FROM SANDBOX_NZ.ADMIN.FCT_INVC_PROD_HBB
    WHERE MNTH_ID = 202508
) B
WHERE T.ASSET_NUM = B.ASSET_NUM;



/* ============================================================
   EXPORT THE NUMBER OF DISTRIBUTION ARPU AND AOU
   ============================================================ */
SELECT
      AOU_BAND
    , ARPU_BAND
    , COUNT(DISTINCT ASSET_NUM)      AS ASSET_CNT           -- # OF ASSETS
    , SUM(DVC_TOTAL_DEVICE)          AS TOTAL_DEVICE_CNT    -- TOTAL # OF DEVICES
    , SUM(DVC_DEVICE_GRP_CNT)        AS TOTAL_DEVICE_GRP_CNT -- TOTAL # OF DEVICE GROUPS
FROM (
    SELECT
          T.ASSET_NUM
        , T.DVC_TOTAL_DEVICE
        , T.DVC_DEVICE_GRP_CNT

        -- AOU IN DAYS: 31/08/2568 (THAI) = 2025-08-31 (GREGORIAN) MINUS INSTALL_DT
        , (DATE '2025-08-31' - DATE(T.INSTALL_DT)) AS AOU

        /* ARPU BAND (USE YOUR ARPU COLUMN HERE: TOTAL_BILL_AMNT OR ANALYSIS_REVN_AMT) */
        , CASE 
              WHEN COALESCE(T.TOTAL_BILL_AMNT,0) <=    0 THEN '01) 0 B'
              WHEN COALESCE(T.TOTAL_BILL_AMNT,0) <=   50 THEN '02) 1 - 50 B'
              WHEN COALESCE(T.TOTAL_BILL_AMNT,0) <=  100 THEN '03) 51 - 100 B'
              WHEN COALESCE(T.TOTAL_BILL_AMNT,0) <=  150 THEN '04) 101 - 150 B'
              WHEN COALESCE(T.TOTAL_BILL_AMNT,0) <=  250 THEN '05) 151 - 250 B'
              WHEN COALESCE(T.TOTAL_BILL_AMNT,0) <=  300 THEN '06) 251 - 300 B'
              WHEN COALESCE(T.TOTAL_BILL_AMNT,0) <=  500 THEN '07) 301 - 500 B'
              WHEN COALESCE(T.TOTAL_BILL_AMNT,0) <= 1000 THEN '08) 501 - 1000 B'
              WHEN COALESCE(T.TOTAL_BILL_AMNT,0) <= 1949 THEN '09) 1000 - 1949 B'
              ELSE                                       '10) > 1949 B'
          END AS ARPU_BAND

        /* AOU BAND (AOU IN DAYS FROM ABOVE EXPRESSION) */
        , CASE
              WHEN (DATE '2025-08-31' - DATE(T.INSTALL_DT)) <=  30*1 THEN 'A) 0M-1M'
              WHEN (DATE '2025-08-31' - DATE(T.INSTALL_DT)) <=  30*3 THEN 'B) 1M-3M'
              WHEN (DATE '2025-08-31' - DATE(T.INSTALL_DT)) <=  30*6 THEN 'C) 3M-6M'
              WHEN (DATE '2025-08-31' - DATE(T.INSTALL_DT)) <= 365*1 THEN 'D) 6M-1Y'
              WHEN (DATE '2025-08-31' - DATE(T.INSTALL_DT)) <= 365*2 THEN 'E) 1Y-2Y'
              WHEN (DATE '2025-08-31' - DATE(T.INSTALL_DT)) <= 365*3 THEN 'F) 2Y-3Y'
              WHEN (DATE '2025-08-31' - DATE(T.INSTALL_DT)) <= 365*4 THEN 'G) 3Y-4Y'
              WHEN (DATE '2025-08-31' - DATE(T.INSTALL_DT)) <= 365*5 THEN 'H) 4Y-5Y'
              ELSE                                                   'I) >5Y'
          END AS AOU_BAND

    FROM SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL T
) X
GROUP BY
      AOU_BAND
    , ARPU_BAND
ORDER BY
      AOU_BAND
    , ARPU_BAND;


/* ========================================================================================= BACKUP FOR GETTING NUMBER IN SLIDE (SINZING AND DISTRIBUTION) ================================================================================================== */


/* ============================================================
   EXPORT THE RESULT BY NUMBER OF DEVICE
   ============================================================ */

-- 2) Circuit universe = all circuits with any FLAG in (1..4)
WITH circuits AS (
  SELECT DISTINCT CIRCUIT
  FROM TEMP_CURCUIT_DATA_AGG_FLAG_INDI
  WHERE FLAG IN (1,2,3,4,5) AND mnth_id = 202509
),

-- 3) Filtered base rows (only flags from FILTER_FLAGS),
--    with NULL sentinel and effective device group
base AS (
  SELECT
      t.CIRCUIT,
      COALESCE(t.WIFI_STA_INFORMATION_HOSTNAME, '__NULL__') AS HOSTNAME_KEY,
      CASE
        WHEN t.WIFI_STA_INFORMATION_HOSTNAME IS NULL THEN 'NULL'
        ELSE t.DEVICE_GROUP
      END AS DEVICE_GROUP_EFF
  FROM TEMP_CURCUIT_DATA_AGG_FLAG_INDI t
  WHERE t.FLAG IN (5) AND mnth_id = 202509
),

-- 4) Aggregate only the filtered rows
agg AS (
  SELECT
      CIRCUIT,
      COUNT(DISTINCT HOSTNAME_KEY) AS touch_nsubr,          -- counts NULL distinctly
      COUNT(*)                    AS touch_nsubr_not_distinct,

      COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'Mobile_Smartphone' THEN HOSTNAME_KEY END) AS touch_nsubr_mobile,
      COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'Mobile_Tablet'     THEN HOSTNAME_KEY END) AS touch_nsubr_tablet,
      COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'PC_Laptop'         THEN HOSTNAME_KEY END) AS touch_nsubr_pc,
      COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'TV'                THEN HOSTNAME_KEY END) AS touch_nsubr_tv,
      COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'TV_BOX'            THEN HOSTNAME_KEY END) AS touch_nsubr_tvbox,
      COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'MESH_WIFI'         THEN HOSTNAME_KEY END) AS touch_nsubr_Mesh_Wifi,
      COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'Camera_CCTV'       THEN HOSTNAME_KEY END) AS touch_nsubr_cctv,
      COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'IoT_SmartHome'     THEN HOSTNAME_KEY END) AS touch_nsubr_iot,
      COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'Wearable'          THEN HOSTNAME_KEY END) AS touch_nsubr_wearable,
      COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF IN ('Unknown','Other') THEN HOSTNAME_KEY END) AS touch_nsubr_other,
      COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'NULL'              THEN HOSTNAME_KEY END) AS touch_nsubr_null
  FROM base
  GROUP BY CIRCUIT
),

-- 5) Left join circuit universe to filtered agg (fills zeros)
per_circuit AS (
  SELECT
      c.CIRCUIT,
      COALESCE(a.touch_nsubr,                 0) AS touch_nsubr,
      COALESCE(a.touch_nsubr_not_distinct,    0) AS touch_nsubr_not_distinct,

      COALESCE(a.touch_nsubr_mobile,          0) AS touch_nsubr_mobile,
      COALESCE(a.touch_nsubr_tablet,          0) AS touch_nsubr_tablet,
      COALESCE(a.touch_nsubr_pc,              0) AS touch_nsubr_pc,
      COALESCE(a.touch_nsubr_tv,              0) AS touch_nsubr_tv,
      COALESCE(a.touch_nsubr_tvbox,           0) AS touch_nsubr_tvbox,
      COALESCE(a.touch_nsubr_Mesh_Wifi,       0) AS touch_nsubr_Mesh_Wifi,
      COALESCE(a.touch_nsubr_cctv,            0) AS touch_nsubr_cctv,
      COALESCE(a.touch_nsubr_iot,             0) AS touch_nsubr_iot,
      COALESCE(a.touch_nsubr_wearable,        0) AS touch_nsubr_wearable,
      COALESCE(a.touch_nsubr_other,           0) AS touch_nsubr_other,
      COALESCE(a.touch_nsubr_null,            0) AS touch_nsubr_null
  FROM circuits c
  LEFT JOIN agg a
    ON a.CIRCUIT = c.CIRCUIT
),

-- 6) Build buckets; includes 0, 1..10, 11+
bucketed AS (
  SELECT
      *,
      CASE
        WHEN touch_nsubr >= 11 THEN '11+'
        ELSE CAST(touch_nsubr AS VARCHAR(3))     -- includes '0'
      END AS device_per_circuit_bucket,
      CASE
        WHEN touch_nsubr >= 11 THEN 11
        ELSE touch_nsubr
      END AS device_per_circuit_bucket_ord
  FROM per_circuit
)

-- 7) Final distribution
SELECT
    device_per_circuit_bucket                           AS device_per_circuit,   -- '0','1'..'10','11+'
    COUNT(*)                                            AS no_circuit,
    SUM(touch_nsubr)                                    AS total_touch_nsubr,
    SUM(touch_nsubr_not_distinct)                       AS total_touch_nsubr_not_distinct,

    SUM(touch_nsubr_mobile)                             AS total_touch_nsubr_mobile,
    SUM(touch_nsubr_tablet)                             AS total_touch_nsubr_tablet,
    SUM(touch_nsubr_pc)                                 AS total_touch_nsubr_pc,
    SUM(touch_nsubr_tv)                                 AS total_touch_nsubr_tv,
    SUM(touch_nsubr_tvbox)                              AS total_touch_nsubr_tvbox,
    SUM(touch_nsubr_Mesh_Wifi)                          AS total_touch_nsubr_Mesh_Wifi,
    SUM(touch_nsubr_cctv)                               AS total_touch_nsubr_cctv,
    SUM(touch_nsubr_iot)                                AS total_touch_nsubr_iot,
    SUM(touch_nsubr_wearable)                           AS total_touch_nsubr_wearable,
    SUM(touch_nsubr_other)                              AS total_touch_nsubr_other,
    SUM(touch_nsubr_null)                               AS total_touch_nsubr_null
FROM bucketed
GROUP BY device_per_circuit_bucket, device_per_circuit_bucket_ord
ORDER BY device_per_circuit_bucket_ord;


/* ============================================================
   FIND THE CUTTING CRITERIA FOR HOUSE DEVICE
   ============================================================ */

-- FIND THE DISTRIBUTION OF ACTIVE DAY
SELECT ACTIVE_DAYS, count(*) 
FROM TEMP_CURCUIT_DATA_AGG_FLAG_INDI
WHERE FLAG <> 1 
AND DEVICE_GROUP NOT IN ('CPE_Router', 'IoT_SmartHome', 'Camera_CCTV', 'TV_STB')
GROUP BY 1 ORDER BY 1


-- FIND THE DISTRIBUTION ON CONNECTTIME
WITH
params AS (
  SELECT 30            AS nbins_int,
         30.0::DOUBLE  AS nbins_dbl
),

base AS (  -- ms → minutes, keep feasible range (0..31 days)
  SELECT (CONNECTTIME::DOUBLE / 60000.0) AS connect_min
  FROM TEMP_CURCUIT_DEVICE_DETAIL_INDI
  WHERE flag IN (2,3,4,5) AND mnth_id = 202507 AND DEVICE_GROUP NOT IN ('CPE_Router', 'IoT_SmartHome', 'Camera_CCTV', 'TV_STB')
),

b AS (      -- log transform to tame skew
  SELECT LN(connect_min + 1.0) AS lx
  FROM base
),

mm AS (     -- min/max on log scale
  SELECT MIN(lx) AS lx_min, MAX(lx) AS lx_max FROM b
),

hist AS (   -- assign bin_id 1..30 on log scale (clamped via CASE)
  SELECT
    CAST(
      CASE
        WHEN m.lx_max = m.lx_min THEN 1
        ELSE
          CASE
            WHEN 1 + FLOOR( ((b.lx - m.lx_min) / NULLIF(m.lx_max - m.lx_min, 0)) * p.nbins_dbl ) < 1
              THEN 1
            WHEN 1 + FLOOR( ((b.lx - m.lx_min) / NULLIF(m.lx_max - m.lx_min, 0)) * p.nbins_dbl ) > p.nbins_int
              THEN p.nbins_int
            ELSE 1 + FLOOR( ((b.lx - m.lx_min) / NULLIF(m.lx_max - m.lx_min, 0)) * p.nbins_dbl )
          END
      END
    AS INTEGER) AS bin_id,
    COUNT(*) AS cnt
  FROM b
  CROSS JOIN mm m
  CROSS JOIN params p
  GROUP BY 1
),

edges AS (  -- map bins back to minutes (min/max/mid)
  SELECT
    h.bin_id,
    h.cnt,
    m.lx_min,
    m.lx_max,
    (m.lx_max - m.lx_min) / p.nbins_dbl AS w,
    EXP(m.lx_min + (h.bin_id - 1) * ((m.lx_max - m.lx_min)/p.nbins_dbl)) - 1.0 AS min_minutes,
    EXP(m.lx_min +  h.bin_id     * ((m.lx_max - m.lx_min)/p.nbins_dbl)) - 1.0 AS max_minutes,
    EXP(m.lx_min + (h.bin_id - 0.5) * ((m.lx_max - m.lx_min)/p.nbins_dbl)) - 1.0 AS mid_minutes
  FROM hist h
  CROSS JOIN mm m
  CROSS JOIN params p
),

tot AS (SELECT SUM(cnt) AS total_cnt FROM edges)

SELECT
  bin_id,
  cnt,
  min_minutes,
  max_minutes,
  mid_minutes,
  (cnt::DOUBLE / t.total_cnt) * 100.0                                    AS pct,
  (SUM(cnt) OVER (ORDER BY bin_id)::DOUBLE / t.total_cnt) * 100.0         AS cum_pct
FROM edges CROSS JOIN tot t
ORDER BY bin_id;



/* ============================================================
   OPTIMIZE OTHER GROUP
   ============================================================ */

-- FIND THE PERCENT HN IN OTHER GROUP
SELECT 
    SUM(CASE WHEN DEVICE_GROUP IN ('Unknown','Other') OR DEVICE_GROUP IS NULL THEN 1 ELSE 0 END)       AS unk_other_cnt
  , COUNT(*)                                                                                           AS total_cnt
  , 100.0 * SUM(CASE WHEN DEVICE_GROUP IN ('Unknown','Other') OR DEVICE_GROUP IS NULL THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0)                                                                          AS pct_unknown_other
FROM TEMP_CURCUIT_DEVICE_DETAIL_INDI;

--FIND THE IST OF HN THAT IN OTHER GROUP
SELECT 
    hn,
    COUNT(*) AS rec_cnt
FROM TEMP_CURCUIT_DEVICE_DETAIL_INDI
WHERE DEVICE_GROUP IN ('Unknown','Other')
  AND hn IS NOT NULL              -- exclude the dedicated NULL bucket
GROUP BY hn
ORDER BY rec_cnt DESC
LIMIT 200;  


/* ============================================================
   Build Permanent Aggregate table
   ============================================================ */

/* Build mnth_id + circuit device counts (distinct hostnames) */
DROP TABLE SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE IF EXISTS;
 
CREATE TABLE SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE AS
WITH base AS (
  SELECT
      MNTH_ID,
      CIRCUIT,
      -- sentinel so DISTINCT works even when hostname is NULL
      COALESCE(HN, '__NULL__') AS HOSTNAME_KEY,
      -- force NULL hostnames into their own bucket
      CASE
        WHEN HN IS NULL THEN 'NULL'
        ELSE DEVICE_GROUP
      END AS DEVICE_GROUP_EFF
  FROM TEMP_CURCUIT_DATA_DEVICE_BRAND
)
SELECT
    MNTH_ID,
    CIRCUIT,

    /* distinct device counts by group */
    COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'Mobile_Smartphone' THEN HOSTNAME_KEY END) AS COUNT_MOBILE_DEVICE,
    COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'Mobile_Tablet'     THEN HOSTNAME_KEY END) AS COUNT_TABLET_DEVICE,
    COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'PC_Laptop'         THEN HOSTNAME_KEY END) AS COUNT_PC_DEVICE,
    COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'TV'                THEN HOSTNAME_KEY END) AS COUNT_TV_DEVICE,
	COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'TV_BOX'            THEN HOSTNAME_KEY END) AS COUNT_TV_BOX_DEVICE,
    COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'Camera_CCTV'       THEN HOSTNAME_KEY END) AS COUNT_CCTV_DEVICE,
    COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'IoT_SmartHome'     THEN HOSTNAME_KEY END) AS COUNT_IOT_DEVICE,
    COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'MESH_WIFI'        THEN HOSTNAME_KEY END)  AS COUNT_MESH_WIFI_DEVICE,
    COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'Wearable'          THEN HOSTNAME_KEY END) AS COUNT_WEARABLE_DEVICE,
    /* "Other" = Unknown/Other only (NULL hostnames are excluded) */
    COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF IN ('Unknown','Other') THEN HOSTNAME_KEY END) AS COUNT_OTHER_DEVICE,
    /* NULL bucket = true NULL hostnames only */
    COUNT(DISTINCT CASE WHEN DEVICE_GROUP_EFF = 'NULL'              THEN HOSTNAME_KEY END) AS COUNT_NULL_DEVICE

FROM base
GROUP BY MNTH_ID, CIRCUIT
DISTRIBUTE ON (MNTH_ID, CIRCUIT);




/* ============================================================
   Build Permanent Aggregate table COMBINE WITH TEAM USAGE TABLE
   ============================================================ */

DROP TABLE SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE_MERGE IF EXISTS;
 
CREATE TABLE SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE_MERGE AS
SELECT A.*
	,B.COUNT_MOBILE_DEVICE
	,B.COUNT_TABLET_DEVICE
	,B.COUNT_PC_DEVICE
	,B.COUNT_TV_DEVICE
	,B.COUNT_CCTV_DEVICE
	,B.COUNT_IOT_DEVICE
	,B.COUNT_ROUTER_DEVICE
	,B.COUNT_WEARABLE_DEVICE
	,B.COUNT_OTHER_DEVICE
	,B.COUNT_NULL_DEVICE
FROM SANDBOX_NZ.ADMIN.TEAM_HBB_INDI_MNTH A
LEFT JOIN SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE B
	ON A.MNTH_ID = B.MNTH_ID
	AND A.CIRCUIT_ID = B.CIRCUIT
WHERE A.MNTH_ID BETWEEN 202507 AND 202508
DISTRIBUTE ON (MNTH_ID, CIRCUIT_ID);



/* ============================================================
   FIND THE SIZING OF THE USE CASE (OLD)
   ============================================================ */

WITH base AS (
  SELECT
      t.MNTH_ID,
      t.CIRCUIT_ID,
      SUM(CASE WHEN t.MAIN_CATEGORY = 'Digital Entertainment' THEN t.DATA_MB ELSE 0 END) AS entertainment_mb,
      MAX(COUNT_MOBILE_DEVICE)    AS cnt_mobile,
      MAX(COUNT_TABLET_DEVICE)    AS cnt_tablet,
      MAX(COUNT_PC_DEVICE)        AS cnt_pc,
      MAX(COUNT_TV_DEVICE)        AS cnt_tv,
      MAX(COUNT_CCTV_DEVICE)      AS cnt_cctv,
      MAX(COUNT_IOT_DEVICE)       AS cnt_iot,
      MAX(COUNT_ROUTER_DEVICE)    AS cnt_router,
      MAX(COUNT_WEARABLE_DEVICE)  AS cnt_wearable,
      MAX(COUNT_OTHER_DEVICE)     AS cnt_other,
      MAX(COUNT_NULL_DEVICE)      AS cnt_null
  FROM SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE_MERGE t
  GROUP BY 1,2
),
agg AS (
  SELECT
      MNTH_ID,
      CIRCUIT_ID,
      (cnt_mobile + cnt_tablet + cnt_pc + cnt_tv + cnt_cctv
       + cnt_iot + cnt_router + cnt_wearable + cnt_other + cnt_null) AS device_total,
      entertainment_mb
  FROM base
),
ranked AS (
  SELECT
      a.*,
      NTILE(100) OVER (PARTITION BY MNTH_ID ORDER BY device_total)     AS device_ntile,
      NTILE(100) OVER (PARTITION BY MNTH_ID ORDER BY entertainment_mb) AS ent_ntile
  FROM agg a
)
SELECT
    MNTH_ID
	,COUNT(*)
FROM ranked
-- "strictly greater than P75/P80" → tiles 76..100 and 81..100 respectively
WHERE device_ntile >= 76
  AND ent_ntile   >= 81
GROUP BY 1
;





WITH base AS (
  SELECT
      t.MNTH_ID,
      t.CIRCUIT_ID,
      -- Adjust the label here if your dictionary uses a different name
      SUM(CASE WHEN t.SUB_CATEGORY = 'Video & Live Streaming' THEN t.DATA_MB ELSE 0 END) AS streaming_mb,
      MAX(COALESCE(t.COUNT_MOBILE_DEVICE,0)) AS mobile_cnt
  FROM SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE_MERGE t
  GROUP BY 1,2
),
ranked AS (
  SELECT
      b.*,
      NTILE(100) OVER (PARTITION BY MNTH_ID ORDER BY streaming_mb) AS stream_ntile
  FROM base b
)
SELECT
    MNTH_ID,
    COUNT(DISTINCT CIRCUIT_ID) AS circuits_passing
FROM ranked
WHERE stream_ntile >= 71   -- strictly > P70 → tiles 71..100
  AND mobile_cnt   >= 1    -- Mobile_Device ≥ 1
GROUP BY MNTH_ID
ORDER BY MNTH_ID;






WITH base AS (
  SELECT
      t.MNTH_ID,
      t.CIRCUIT_ID,
      -- adjust the label if needed
      SUM(CASE WHEN t.SUB_CATEGORY = 'Video & Live Streaming' THEN COALESCE(t.DATA_MB,0) ELSE 0 END) AS streaming_mb,
      MAX(COALESCE(t.COUNT_TV_DEVICE,0)) AS tvstb_cnt
  FROM SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE_MERGE t
  GROUP BY 1,2
),
ranked AS (
  SELECT
      b.*,
      NTILE(100) OVER (PARTITION BY MNTH_ID ORDER BY streaming_mb) AS stream_ntile
  FROM base b
)
SELECT
    MNTH_ID,
    COUNT(DISTINCT CIRCUIT_ID) AS circuits_passing
FROM ranked
WHERE stream_ntile >= 71   -- strictly > P70 → tiles 71..100
  AND tvstb_cnt   >= 1     -- TV/STB ≥ 1
GROUP BY MNTH_ID
ORDER BY MNTH_ID;




/* ============================================================
   FIND THE DEVICE/CIRCUIT FOR EACH DEVICE GROUP
   ============================================================ */

WITH base AS (
  SELECT
      t.MNTH_ID,
      t.CIRCUIT,
      /* sentinel so DISTINCT works even when hostname is NULL */
      COALESCE(t.WIFI_STA_INFORMATION_HOSTNAME, '__NULL__') AS HOST_KEY,
      /* force NULL hostnames into their own bucket */
      CASE
        WHEN t.WIFI_STA_INFORMATION_HOSTNAME IS NULL THEN 'NULL'
		WHEN T.DEVICE_GROUP = 'Unknown' THEN 'Other'
		WHEN T.DEVICE_GROUP = 'NULL' THEN 'Other'
        ELSE t.DEVICE_GROUP
      END AS DEVICE_GROUP_EFF
  FROM TEMP_CURCUIT_DATA_AGG_FLAG_INDI t
  WHERE t.MNTH_ID = 202507
    AND t.FLAG = 5
),

/* how many real (non-NULL) groups exist on each circuit? */
circuit_group_stats AS (
  SELECT
      b.CIRCUIT,
      COUNT(DISTINCT CASE WHEN b.DEVICE_GROUP_EFF <> 'NULL' THEN b.DEVICE_GROUP_EFF END)
        AS distinct_real_groups
  FROM base b
  GROUP BY b.CIRCUIT
),

/* collapse to ONE row per (group, circuit) with its per-circuit distinct device count */
per_circuit_counts AS (
  SELECT
      b.DEVICE_GROUP_EFF,
      b.CIRCUIT,
      COUNT(DISTINCT b.HOST_KEY) AS dev_cnt_circuit
  FROM base b
  GROUP BY b.DEVICE_GROUP_EFF, b.CIRCUIT
),

/* bring in the "is this circuit mixed?" (once per circuit) */
per_circuit_with_mixed AS (
  SELECT
      p.DEVICE_GROUP_EFF,
      p.CIRCUIT,
      p.dev_cnt_circuit,
      CASE WHEN cgs.distinct_real_groups >= 2 THEN 1 ELSE 0 END AS is_mixed
  FROM per_circuit_counts p
  JOIN circuit_group_stats cgs
    ON cgs.CIRCUIT = p.CIRCUIT
),

/* aggregate to the group level correctly */
group_agg AS (
  SELECT
      DEVICE_GROUP_EFF,
      SUM(dev_cnt_circuit)             AS device_cnt,          -- sum of per-circuit distinct devices
      COUNT(*)                         AS circuit_cnt,         -- circuits that have this group
      SUM(is_mixed)                    AS mixed_circuit_cnt    -- circuits with this group that are mixed
  FROM per_circuit_with_mixed
  GROUP BY DEVICE_GROUP_EFF
)

SELECT
  CASE ga.DEVICE_GROUP_EFF
    WHEN 'Mobile_Smartphone' THEN 'Sum of TOTAL_TOUCH_NSUBR_MOBILE'
    WHEN 'Mobile_Tablet'     THEN 'Sum of TOTAL_TOUCH_NSUBR_TABLET'
    WHEN 'PC_Laptop'         THEN 'Sum of TOTAL_TOUCH_NSUBR_PC'
    WHEN 'TV'                THEN 'Sum of TOTAL_TOUCH_NSUBR_TV'
	WHEN 'TV_BOX'            THEN 'Sum of TOTAL_TOUCH_NSUBR_TV_BOX'
    WHEN 'MESH_WIFI'         THEN 'Sum of TOTAL_TOUCH_NSUBR_MESH_WIFI'
    WHEN 'Camera_CCTV'       THEN 'Sum of TOTAL_TOUCH_NSUBR_CCTV'
    WHEN 'IoT_SmartHome'     THEN 'Sum of TOTAL_TOUCH_NSUBR_IOT'
    WHEN 'Wearable'          THEN 'Sum of TOTAL_TOUCH_NSUBR_WEARABLE'
    WHEN 'NULL'              THEN 'Sum of TOTAL_TOUCH_NSUBR_NULL'
    ELSE                         'Sum of TOTAL_TOUCH_NSUBR_OTHER'
  END AS "Values",
  ga.device_cnt                                        AS "#Device",
  ga.circuit_cnt                                       AS "#Circuit",
  ga.device_cnt::NUMERIC(20,6) / NULLIF(ga.circuit_cnt, 0) AS "Device/circuit",
  (ga.mixed_circuit_cnt::NUMERIC(20,6) / NULLIF(ga.circuit_cnt, 0)) * 100.0 AS "%Mixed"
FROM group_agg ga
ORDER BY "Values";



/* ============================================================
   FIND THE CCTV WITH MESH FOR CROSS SELL MESH
   ============================================================ */

WITH buck AS (
  SELECT
      CASE
        WHEN COUNT_CCTV_DEVICE >= 9 THEN '9+'
        ELSE CAST(COUNT_CCTV_DEVICE AS VARCHAR(10))
      END AS cctv_bucket,
      CASE WHEN COUNT_ROUTER_DEVICE >= 1 THEN 1 ELSE 0 END AS has_mesh
  FROM TEMP_CURCUIT_DATA_AGG_DEVICE
  WHERE COUNT_CCTV_DEVICE >= 1
),
agg AS (
  SELECT
      cctv_bucket,
      COUNT(*) AS circuits_have_cctv,
      SUM(has_mesh) AS circuits_have_cctv_and_mesh
  FROM buck
  GROUP BY cctv_bucket
),
rollup_ AS (   -- renamed from ROWS (reserved)
  SELECT
      cctv_bucket,
      circuits_have_cctv,
      circuits_have_cctv_and_mesh
  FROM agg
  UNION ALL
  SELECT
      'TOTAL',
      SUM(circuits_have_cctv),
      SUM(circuits_have_cctv_and_mesh)
  FROM agg
)
SELECT
  cctv_bucket AS "COUNT_CCTV_DEVICE",
  circuits_have_cctv AS "CIRCUIT HAVE CCTV",
  circuits_have_cctv_and_mesh AS "CIRCUIT HAVE CCTV&MESH",
  circuits_have_cctv_and_mesh * 1.0 / NULLIF(circuits_have_cctv,0) AS "%  HAVE CCTV&MESH / HAVE CCTV"
FROM rollup_
ORDER BY
  CASE cctv_bucket
    WHEN '1' THEN 1 WHEN '2' THEN 2 WHEN '3' THEN 3 WHEN '4' THEN 4
    WHEN '5' THEN 5 WHEN '6' THEN 6 WHEN '7' THEN 7 WHEN '8' THEN 8
    WHEN '9+' THEN 9 WHEN 'TOTAL' THEN 10 ELSE 11
  END;


/* ============================================================
   FIND OVERALL BRAND SHARING 
   ============================================================ */

WITH base AS (
  SELECT
      MNTH_ID,
      CIRCUIT,
      UPPER(TRIM(DEVICE_BRAND)) AS BRAND
  FROM TEMP_CURCUIT_DATA_DEVICE_BRAND
),

-- Brand families (LIKE patterns are case-insensitive due to UPPER)
brand_family AS (
  SELECT 'Apple'          AS FAMILY, '%APPLE%'   AS PATTERN UNION ALL
  SELECT 'Samsung',                      '%SAMSUNG%'        UNION ALL
  -- Xiaomi ecosystem grouped
  SELECT 'Xiaomi',                '%XIAOMI%'         UNION ALL
  SELECT 'Xiaomi',                '%REDMI%'          UNION ALL
  SELECT 'Xiaomi',                '%POCO%'           UNION ALL
  -- Newly requested:
  SELECT 'OPPO',                         '%OPPO%'           UNION ALL
  SELECT 'vivo',                         '%VIVO%'           UNION ALL
  SELECT 'realme',                       '%REALME%'         UNION ALL
  SELECT 'HUAWEI',                       '%HUAWEI%'         UNION ALL
  -- Keep existing ones you used
  SELECT 'HONOR',                        '%HONOR%'          UNION ALL
  SELECT 'LG',                       '%LG%'         UNION ALL
  SELECT 'BRAND_A',                         '%BRAND_A%'           -- OPER, OPTV, OPMESH, etc.
),

tagged AS (
  SELECT b.MNTH_ID, 
  b.CIRCUIT,
  f.FAMILY
  FROM base b
  JOIN brand_family f
    ON b.BRAND LIKE f.PATTERN
),

family_totals AS (
  SELECT
      MNTH_ID,
      FAMILY  AS BRAND_FAMILY,
      COUNT(*) AS DEVICES_IN_BRAND,
      COUNT(DISTINCT CIRCUIT) AS CIRCUITS_IN_BRAND
  FROM tagged
  GROUP BY MNTH_ID, FAMILY
),

all_totals AS (
  SELECT
      MNTH_ID,
      COUNT(*) AS DEVICES_ALL
  FROM TEMP_CURCUIT_DATA_DEVICE_BRAND
  GROUP BY MNTH_ID
)

SELECT
  f.MNTH_ID,
  f.BRAND_FAMILY,
  f.CIRCUITS_IN_BRAND,
  f.DEVICES_IN_BRAND,
  (f.DEVICES_IN_BRAND * 1.0) / NULLIF(a.DEVICES_ALL,0) AS PCT_MIXED
FROM family_totals f
JOIN all_totals   a
  ON a.MNTH_ID = f.MNTH_ID
ORDER BY f.MNTH_ID, f.DEVICES_IN_BRAND DESC, f.BRAND_FAMILY;



-- ONLY THE DEIVCE THAT HAVE BRAND
WITH base AS (
  SELECT
      MNTH_ID,
      CIRCUIT,
      UPPER(TRIM(DEVICE_BRAND)) AS BRAND
  FROM TEMP_CURCUIT_DATA_DEVICE_BRAND
  WHERE DEVICE_BRAND IS NOT NULL
    AND TRIM(DEVICE_BRAND) <> ''
    AND UPPER(TRIM(DEVICE_BRAND)) NOT IN ('UNKNOWN','OTHER/UNMAPPED')
),

-- Brand families (LIKE patterns are case-insensitive due to UPPER)
brand_family AS (
  SELECT 'Apple'          AS FAMILY, '%APPLE%'   AS PATTERN UNION ALL
  SELECT 'Samsung',                      '%SAMSUNG%'        UNION ALL
  -- Xiaomi ecosystem grouped
  SELECT 'Xiaomi',                '%XIAOMI%'         UNION ALL
  SELECT 'Xiaomi',                '%REDMI%'          UNION ALL
  SELECT 'Xiaomi',                '%POCO%'           UNION ALL
  -- Newly requested:
  SELECT 'OPPO',                         '%OPPO%'           UNION ALL
  SELECT 'vivo',                         '%VIVO%'           UNION ALL
  SELECT 'realme',                       '%REALME%'         UNION ALL
  SELECT 'HUAWEI',                       '%HUAWEI%'         UNION ALL
  -- Keep existing ones you used
  SELECT 'HONOR',                        '%HONOR%'          UNION ALL
  SELECT 'LG',                       '%LG%'         UNION ALL
  SELECT 'BRAND_A',                         '%BRAND_A%'           -- OPER, OPTV, OPMESH, etc.
),

tagged AS (
  SELECT b.MNTH_ID, 
  b.CIRCUIT,
  f.FAMILY
  FROM base b
  JOIN brand_family f
    ON b.BRAND LIKE f.PATTERN
),

family_totals AS (
  SELECT
      MNTH_ID,
      FAMILY  AS BRAND_FAMILY,
      COUNT(*) AS DEVICES_IN_BRAND,
      COUNT(DISTINCT CIRCUIT) AS CIRCUITS_IN_BRAND
  FROM tagged
  GROUP BY MNTH_ID, FAMILY
),

-- 🔹 Count only rows that have a real brand (exclude null/blank/Unknown/Other/Unmapped)
all_totals AS (
  SELECT
      MNTH_ID,
      COUNT(*) AS DEVICES_ALL
  FROM TEMP_CURCUIT_DATA_DEVICE_BRAND
  WHERE DEVICE_BRAND IS NOT NULL
    AND TRIM(DEVICE_BRAND) <> ''
    AND UPPER(TRIM(DEVICE_BRAND)) NOT IN ('UNKNOWN','OTHER/UNMAPPED')
  GROUP BY MNTH_ID
)

SELECT
  f.MNTH_ID,
  f.BRAND_FAMILY,
  f.CIRCUITS_IN_BRAND,
  f.DEVICES_IN_BRAND,
  (f.DEVICES_IN_BRAND * 1.0) / NULLIF(a.DEVICES_ALL,0) AS PCT_MIXED
FROM family_totals f
JOIN all_totals   a
  ON a.MNTH_ID = f.MNTH_ID
ORDER BY f.MNTH_ID, f.DEVICES_IN_BRAND DESC, f.BRAND_FAMILY;



/* ============================================================
   Brand family mix + Other Brand + No_Brand + No_Group
   Level: all data (no MNTH_ID)
   Source: TEMP_CURCUIT_DATA_DEVICE_BRAND
   # DEVICES = COUNT(DISTINCT CIRCUIT||'|'||HN)
   ============================================================ */

WITH main_raw AS (
  SELECT
      CIRCUIT,
      HN,
      DEVICE_GROUP,
      UPPER(TRIM(DEVICE_BRAND)) AS BRAND
  FROM TEMP_CURCUIT_DATA_DEVICE_BRAND
),

/* Only rows that have a "real" brand (exclude Unknown/Other/Unmapped/blank) */
base AS (
  SELECT
      CIRCUIT,
      HN,
      BRAND
  FROM main_raw
  WHERE BRAND IS NOT NULL
    AND BRAND <> ''
    AND BRAND NOT IN ('UNKNOWN','OTHER/UNMAPPED')
),

/* Brand families (use same logic you used for the main brands) */
brand_family AS (
  SELECT 'Apple'    AS FAMILY, '%APPLE%'    AS PATTERN UNION ALL
  SELECT 'Samsung'              , '%SAMSUNG%'           UNION ALL
  -- Xiaomi ecosystem grouped
  SELECT 'Xiaomi'              , '%XIAOMI%'            UNION ALL
  SELECT 'Xiaomi'              , '%REDMI%'             UNION ALL
  SELECT 'Xiaomi'              , '%POCO%'              UNION ALL
  -- Newly requested families
  SELECT 'OPPO'                , '%OPPO%'              UNION ALL
  SELECT 'vivo'                , '%VIVO%'              UNION ALL
  SELECT 'realme'              , '%REALME%'            UNION ALL
  SELECT 'HUAWEI'              , '%HUAWEI%'            UNION ALL
  -- Keep existing ones you used
  SELECT 'HONOR'               , '%HONOR%'             UNION ALL
  SELECT 'LG'                  , '%LG%'                UNION ALL
  SELECT 'BRAND_A'                , '%BRAND_A%'              -- OPER, OPTV, OPMESH, etc.
),

/* Devices that match at least one brand family */
tagged AS (
  SELECT
      b.CIRCUIT,
      b.HN,
      f.FAMILY
  FROM base b
  JOIN brand_family f
    ON b.BRAND LIKE f.PATTERN
),

/* Main family totals: per FAMILY, count circuits & DISTINCT devices */
family_totals AS (
  SELECT
      FAMILY AS BRAND,
      COUNT(DISTINCT CIRCUIT)                     AS CIRCUITS,
      COUNT(DISTINCT CIRCUIT || '|' || HN)        AS DEVICES
  FROM tagged
  GROUP BY FAMILY
),

/* Other Brand: real brand, but doesn't fall into any FAMILY above */
other_brand AS (
  SELECT
      COUNT(DISTINCT b.CIRCUIT)                  AS CIRCUITS_OTHER_BRAND,
      COUNT(DISTINCT b.CIRCUIT || '|' || b.HN)   AS DEVICES_OTHER_BRAND
  FROM base b
  WHERE NOT EXISTS (
    SELECT 1
    FROM brand_family f
    WHERE b.BRAND LIKE f.PATTERN
  )
),

/* No_Brand + No_Group:
   - brand is null/blank/Unknown/Other/Unmapped
   OR
   - device_group is null/blank/Unknown/Other
*/
no_brand_group AS (
  SELECT
      COUNT(DISTINCT CIRCUIT)                  AS CIRCUITS_NB_NG,
      COUNT(DISTINCT CIRCUIT || '|' || HN)     AS DEVICES_NB_NG
  FROM main_raw
  WHERE
        BRAND IS NULL
     OR BRAND = ''
     OR BRAND IN ('UNKNOWN','OTHER/UNMAPPED')
     OR DEVICE_GROUP IS NULL
     OR TRIM(DEVICE_GROUP) = ''
     OR UPPER(TRIM(DEVICE_GROUP)) IN ('UNKNOWN','OTHER')
),

/* Overall totals: all devices (including no brand / no group) */
all_totals AS (
  SELECT
      COUNT(DISTINCT CIRCUIT)                  AS CIRCUITS_ALL,
      COUNT(DISTINCT CIRCUIT || '|' || HN)     AS DEVICES_ALL
  FROM main_raw
),

/* Union all rows to one summary set */
summary AS (
  SELECT
      BRAND,
      CIRCUITS,
      DEVICES
  FROM family_totals

  UNION ALL
  SELECT
      'Other Brand' AS BRAND,
      CIRCUITS_OTHER_BRAND,
      DEVICES_OTHER_BRAND
  FROM other_brand

  UNION ALL
  SELECT
      'No_Brand + No_Group' AS BRAND,
      CIRCUITS_NB_NG,
      DEVICES_NB_NG
  FROM no_brand_group

  UNION ALL
  SELECT
      'Total' AS BRAND,
      CIRCUITS_ALL,
      DEVICES_ALL
  FROM all_totals
)

SELECT
    s.BRAND                                      AS BRAND,
    s.CIRCUITS                                   AS "# CIRCUIT",
    s.DEVICES                                    AS "# DEVICES",
    CASE WHEN s.CIRCUITS = 0
         THEN NULL
         ELSE (s.DEVICES * 1.0) / s.CIRCUITS
    END                                          AS DEVICES_PER_CIRCUIT,
    (s.DEVICES * 1.0) / NULLIF(a.DEVICES_ALL, 0) AS PCT_MIXED
FROM summary s
CROSS JOIN all_totals a
ORDER BY
    CASE WHEN s.BRAND = 'Total' THEN 0 ELSE 1 END,
    s.DEVICES DESC,
    s.BRAND;






/* ============================================================
   FIND THE DISTRIBUTION OF #DEVICE GROUP COMBINATION
   ============================================================ */
-- Distribution of #device groups per circuit, counting ALL devices (incl. Other/NULL)
WITH base AS (
  SELECT
      MNTH_ID,
      CIRCUIT,
      COUNT_MOBILE_DEVICE    AS c_mobile,
      COUNT_TABLET_DEVICE    AS c_tablet,
      COUNT_PC_DEVICE        AS c_pc,
      COUNT_TV_DEVICE        AS c_tv,
      COUNT_TV_BOX_DEVICE    AS c_tv_box,
      COUNT_CCTV_DEVICE      AS c_cctv,
      COUNT_IOT_DEVICE       AS c_iot,
      COUNT_MESH_WIFI_DEVICE AS c_mesh_wifi,
      COUNT_WEARABLE_DEVICE  AS c_wearable,
      COUNT_OTHER_DEVICE     AS c_other,     -- ungrouped/Unknown/Other
      COUNT_NULL_DEVICE      AS c_null       -- true NULL-hostname bucket
  FROM TEMP_CURCUIT_DATA_AGG_DEVICE
),
per_circuit AS (
  SELECT
      MNTH_ID,
      CIRCUIT,

      -- how many of the 8 recognized groups appear (0..8)
      (CASE WHEN c_mobile   > 0 THEN 1 ELSE 0 END +
       CASE WHEN c_tablet   > 0 THEN 1 ELSE 0 END +
       CASE WHEN c_pc       > 0 THEN 1 ELSE 0 END +
       CASE WHEN c_tv       > 0 THEN 1 ELSE 0 END +
       CASE WHEN c_tv_box   > 0 THEN 1 ELSE 0 END +
       CASE WHEN c_cctv     > 0 THEN 1 ELSE 0 END +
       CASE WHEN c_iot      > 0 THEN 1 ELSE 0 END +
       CASE WHEN c_mesh_wifi > 0 THEN 1 ELSE 0 END +
       CASE WHEN c_wearable > 0 THEN 1 ELSE 0 END) AS group_count,

      -- total devices across ALL buckets, including Other/NULL
      (c_mobile + c_tablet + c_pc + c_tv + c_tv_box + c_cctv + c_iot + c_mesh_wifi + c_wearable
       + c_other + c_null) AS device_total_all
  FROM base
)
SELECT
    group_count                               AS Device_group,
    COUNT(DISTINCT CIRCUIT)                   AS CIRCUITS,
    COUNT(DISTINCT CIRCUIT) * 1.0
      / SUM(COUNT(DISTINCT CIRCUIT)) OVER ()  AS Mixed,
    SUM(device_total_all)                     AS Device
FROM per_circuit
GROUP BY group_count
ORDER BY group_count;


/* ============================================================
   FIND THE COMBINATION DEVICE CROSS SELL
   ============================================================ */

-- Build a canonical combination key like:
-- "CPE_Router+Smartphone+Laptop" (sorted by fixed order below)
WITH flags AS (
  SELECT
      MNTH_ID,
      CIRCUIT,
      CASE WHEN COUNT_MOBILE_DEVICE   > 0 THEN 1 ELSE 0 END AS f_mobile,
      CASE WHEN COUNT_TABLET_DEVICE   > 0 THEN 1 ELSE 0 END AS f_tablet,
      CASE WHEN COUNT_PC_DEVICE       > 0 THEN 1 ELSE 0 END AS f_pc,
      CASE WHEN COUNT_TV_DEVICE       > 0 THEN 1 ELSE 0 END AS f_tv,
      CASE WHEN COUNT_TV_BOX_DEVICE   > 0 THEN 1 ELSE 0 END AS f_tv_box,
      CASE WHEN COUNT_CCTV_DEVICE     > 0 THEN 1 ELSE 0 END AS f_cctv,
      CASE WHEN COUNT_IOT_DEVICE      > 0 THEN 1 ELSE 0 END AS f_iot,
      CASE WHEN COUNT_MESH_WIFI_DEVICE   > 0 THEN 1 ELSE 0 END AS f_mesh,
      CASE WHEN COUNT_WEARABLE_DEVICE > 0 THEN 1 ELSE 0 END AS f_wearable
  FROM TEMP_CURCUIT_DATA_AGG_DEVICE
  -- Optional: WHERE MNTH_ID = 202507
),
combo AS (
  SELECT
      MNTH_ID,
      CIRCUIT,

      /* number of groups present in the combo */
      (f_mobile + f_tablet + f_pc + f_tv + f_tv_box + f_cctv + f_iot + f_mesh + f_wearable) AS group_count,

      /* human-readable combination key in fixed order */
      TRIM(BOTH '+' FROM
          CASE WHEN f_mesh     = 1 THEN 'Mesh_wifi+'    ELSE '' END ||
          CASE WHEN f_mobile   = 1 THEN 'Smartphone+'   ELSE '' END ||
          CASE WHEN f_tablet   = 1 THEN 'Tablet+'       ELSE '' END ||
          CASE WHEN f_pc       = 1 THEN 'Laptop+'       ELSE '' END ||
          CASE WHEN f_tv       = 1 THEN 'TV+'           ELSE '' END ||
          CASE WHEN f_tv_box   = 1 THEN 'TV_Box+'       ELSE '' END ||
          CASE WHEN f_cctv     = 1 THEN 'CCTV+'         ELSE '' END ||
          CASE WHEN f_iot      = 1 THEN 'IoT+'          ELSE '' END ||
          CASE WHEN f_wearable = 1 THEN 'Wearable+'     ELSE '' END
      ) AS combo_key
  FROM flags
)
SELECT
    MNTH_ID,
    CASE WHEN combo_key = '' THEN '(No Group Present)' ELSE combo_key END AS combo_key,
    group_count,
    COUNT(DISTINCT CIRCUIT) AS circuits,
    COUNT(DISTINCT CIRCUIT) * 1.0
      / SUM(COUNT(DISTINCT CIRCUIT)) OVER (PARTITION BY MNTH_ID) AS share
FROM combo
GROUP BY MNTH_ID, combo_key, group_count
ORDER BY MNTH_ID, group_count DESC, circuits DESC, combo_key;


/* ============================================================
   FIND THE COMBINATION OF OPER DEVICE 
   ============================================================ */  
-- CREATE THE AGGREGATE TABLE
DROP TABLE TEMP_CURCUIT_DATA_OPER_DEVICE IF EXISTS;

CREATE TEMP TABLE TEMP_CURCUIT_DATA_OPER_DEVICE AS
SELECT
      MNTH_ID
    , CIRCUIT

    , SUM(CASE 
              WHEN DEVICE_GROUP = 'TV_BOX'
               AND DEVICE_BRAND = 'OpTV'
              THEN 1 ELSE 0 
          END) AS OPER_TV_BOX_CNT

    , SUM(CASE 
              WHEN DEVICE_GROUP = 'Camera_CCTV'
               AND DEVICE_BRAND = 'BRAND_A'
              THEN 1 ELSE 0 
          END) AS OPER_CCTV_CNT

    , SUM(CASE 
              WHEN DEVICE_GROUP = 'MESH_WIFI'
               AND DEVICE_BRAND = 'OpMesh'
              THEN 1 ELSE 0 
          END) AS OPER_MESH_WIFI_CNT

    , SUM(CASE 
              WHEN DEVICE_GROUP = 'Mobile_Smartphone'
               AND DEVICE_BRAND = 'BRAND_A'
              THEN 1 ELSE 0 
          END) AS OPER_MOBILE_CNT

    , SUM(CASE 
              WHEN (DEVICE_GROUP = 'TV_BOX'          AND DEVICE_BRAND = 'OpTV')
                 OR (DEVICE_GROUP = 'Camera_CCTV'    AND DEVICE_BRAND = 'BRAND_A')
                 OR (DEVICE_GROUP = 'MESH_WIFI'      AND DEVICE_BRAND = 'OpMesh')
                 OR (DEVICE_GROUP = 'Mobile_Smartphone' AND DEVICE_BRAND = 'BRAND_A')
              THEN 1 ELSE 0
          END) AS OPER_DEVICE_TOTAL_CNT
FROM TEMP_CURCUIT_DATA_DEVICE_BRAND
GROUP BY
      MNTH_ID
    , CIRCUIT
DISTRIBUTE ON (MNTH_ID, CIRCUIT);

-- FIND THE COMBINATION BETWEEN OPER DEVICE

WITH flags AS (
  SELECT
        MNTH_ID
      , CIRCUIT

      , OPER_TV_BOX_CNT
      , OPER_CCTV_CNT
      , OPER_MESH_WIFI_CNT
      , OPER_MOBILE_CNT
      , OPER_DEVICE_TOTAL_CNT   -- total Oper devices in this circuit

      , CASE WHEN OPER_TV_BOX_CNT    > 0 THEN 1 ELSE 0 END AS f_oper_tv_box
      , CASE WHEN OPER_CCTV_CNT      > 0 THEN 1 ELSE 0 END AS f_oper_cctv
      , CASE WHEN OPER_MESH_WIFI_CNT > 0 THEN 1 ELSE 0 END AS f_oper_mesh
      , CASE WHEN OPER_MOBILE_CNT    > 0 THEN 1 ELSE 0 END AS f_oper_mobile
  FROM TEMP_CURCUIT_DATA_OPER_DEVICE
),

combo AS (
  SELECT
        MNTH_ID
      , CIRCUIT

      , OPER_DEVICE_TOTAL_CNT

      /* number of Oper product types present in the circuit */
      , ( f_oper_tv_box
        + f_oper_cctv
        + f_oper_mesh
        + f_oper_mobile )              AS oper_product_type_cnt

      /* human-readable combination key in fixed order */
      , TRIM(BOTH '+' FROM
            CASE WHEN f_oper_mesh      = 1 THEN 'OpMesh+'      ELSE '' END ||
            CASE WHEN f_oper_mobile    = 1 THEN 'Oper_Mobile+'   ELSE '' END ||
            CASE WHEN f_oper_tv_box    = 1 THEN 'OpTV+'      ELSE '' END ||
            CASE WHEN f_oper_cctv      = 1 THEN 'Oper_CCTV+'     ELSE '' END
        ) AS combo_key
  FROM flags
)

SELECT
      MNTH_ID
    , CASE 
          WHEN combo_key = '' THEN '(No Oper Product)'
          ELSE combo_key
      END                                   AS combo_key
    , oper_product_type_cnt                 AS product_type_cnt    -- same as first version
    , COUNT(DISTINCT CIRCUIT)               AS circuits            -- same as first version

    -- NEW: total number of Oper devices in this combination segment
    , SUM(OPER_DEVICE_TOTAL_CNT)            AS oper_device_cnt

    -- same share column as the first version
    , COUNT(DISTINCT CIRCUIT) * 1.0
        / SUM(COUNT(DISTINCT CIRCUIT)) OVER (PARTITION BY MNTH_ID) AS share
FROM combo
GROUP BY
      MNTH_ID
    , combo_key
    , oper_product_type_cnt
ORDER BY
      MNTH_ID
    , oper_product_type_cnt DESC
    , circuits DESC
    , combo_key;




/* ============================================================
   FIND THE NUMBER OF TV WITH NON OPTVBOX TO CROSS SELL
   ============================================================ */
WITH norm AS (
  SELECT
      MNTH_ID,
      CIRCUIT,
      DEVICE_GROUP,
      UPPER(TRIM(DEVICE_BRAND)) AS BRAND_N
  FROM TEMP_CURCUIT_DATA_DEVICE_BRAND
),
flags AS (
  SELECT
      MNTH_ID,
      CIRCUIT,
      MAX(CASE WHEN DEVICE_GROUP = 'TV' THEN 1 ELSE 0 END) AS has_tv,
      MAX(CASE WHEN DEVICE_GROUP = 'TV_BOX' THEN 1 ELSE 0 END) AS has_tv_box,

      /* OpTV TV_BOX (brand normalized) */
      MAX(
        CASE 
          WHEN DEVICE_GROUP = 'TV_BOX'
           AND BRAND_N = 'OPTV'
          THEN 1 ELSE 0 
        END
      ) AS has_opidtv_box,

      /* Non-OpTV TV_BOX (includes null/other brands) */
      MAX(
        CASE 
          WHEN DEVICE_GROUP = 'TV_BOX'
           AND (BRAND_N IS NULL OR BRAND_N <> 'OPTV')
          THEN 1 ELSE 0 
        END
      ) AS has_non_opidtv_box
  FROM norm
  GROUP BY MNTH_ID, CIRCUIT
)
SELECT
    MNTH_ID,

    /* 1) circuits that have TV */
    SUM(CASE WHEN has_tv = 1 THEN 1 ELSE 0 END) AS circuits_have_tv,

    /* 2) circuits that have TV AND any TV_BOX (OpTV or not) */
    SUM(CASE WHEN has_tv = 1 AND has_tv_box = 1 THEN 1 ELSE 0 END) AS circuits_have_tv_and_tv_box,
    
    /* 3) circuits that have TV but NO TV_BOX at all */
    SUM(CASE WHEN has_tv = 1 AND has_tv_box = 0 THEN 1 ELSE 0 END) AS circuits_have_tv_no_tv_box,

    /* 4) circuits that have TV AND at least one OpTV box 
          (may also have non-OpTV box) */
    SUM(CASE WHEN has_tv = 1 AND has_opidtv_box = 1 THEN 1 ELSE 0 END) AS circuits_have_tv_with_opidtv_box,

    /* 5) OPTIONAL: circuits that have TV + TV_BOX and NONE are OpTV */
    SUM(
      CASE 
        WHEN has_tv = 1 
         AND has_tv_box = 1 
         AND has_opidtv_box = 0 
        THEN 1 ELSE 0 
      END
    ) AS circuits_have_tv_and_only_non_opidtv_box,

    /* 6) OPTIONAL: circuits that have TV + both OpTV and non-OpTV box */
    SUM(
      CASE 
        WHEN has_tv = 1 
         AND has_opidtv_box = 1 
         AND has_non_opidtv_box = 1
        THEN 1 ELSE 0 
      END
    ) AS circuits_have_tv_with_opidtv_and_other_box

FROM flags
GROUP BY MNTH_ID
ORDER BY MNTH_ID;

/* ============================================================
   CREATE THE IOT CAT AGGREGATE TEMP TABLE FOR FIND COMBINATION
   ============================================================ */

DROP TABLE TEMP_CURCUIT_DATA_AGG_CAT IF EXISTS;

CREATE TEMP TABLE TEMP_CURCUIT_DATA_AGG_CAT AS
WITH iot AS (
  SELECT
      MNTH_ID,
      CIRCUIT,
      COALESCE(HN, '__NULL__') AS HOST_KEY,
      /* Keep only IoT_SmartHome; normalize categories; else → IoT_Other */
      CASE
        WHEN DEVICE_GROUP <> 'IoT_SmartHome' THEN NULL
        WHEN LOWER(DEVICE_CAT) IN (
          'air purifier','printer','robot vacuum','washing machine','smart bulb',
          'voice assistant speaker','fan','pet feeder','driverack','iot_other',
          'air conditioner','smart plug','robot','smart speaker','fridge',
          'bluetooth speaker','audio streamer','dryer','stick vacuum','dehumidifier',
          'airfryer','soundbar','water purifier','smart scale','smart hub/gateway',
          'microwave'
        ) THEN DEVICE_CAT
        ELSE 'IoT_Other'
      END AS IOT_CAT
  FROM TEMP_CURCUIT_DATA_DEVICE_CAT
  WHERE DEVICE_GROUP = 'IoT_SmartHome'
)
SELECT
    MNTH_ID,
    CIRCUIT,

    /* Distinct hostname counts by IoT category */
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Air Purifier'            THEN HOST_KEY END) AS CNT_AIR_PURIFIER,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Printer'                 THEN HOST_KEY END) AS CNT_PRINTER,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Robot Vacuum'            THEN HOST_KEY END) AS CNT_ROBOT_VACUUM,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Washing Machine'         THEN HOST_KEY END) AS CNT_WASHING_MACHINE,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Smart Bulb'              THEN HOST_KEY END) AS CNT_SMART_BULB,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Voice Assistant Speaker' THEN HOST_KEY END) AS CNT_VOICE_ASSISTANT_SPK,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Fan'                     THEN HOST_KEY END) AS CNT_FAN,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Pet Feeder'              THEN HOST_KEY END) AS CNT_PET_FEEDER,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'DriveRack'               THEN HOST_KEY END) AS CNT_DRIVERACK,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'IoT_Other'               THEN HOST_KEY END) AS CNT_IOT_OTHER,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Air Conditioner'         THEN HOST_KEY END) AS CNT_AIR_COND,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Smart Plug'              THEN HOST_KEY END) AS CNT_SMART_PLUG,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Robot'                   THEN HOST_KEY END) AS CNT_ROBOT,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Smart Speaker'           THEN HOST_KEY END) AS CNT_SMART_SPEAKER,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Fridge'                  THEN HOST_KEY END) AS CNT_FRIDGE,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Bluetooth Speaker'       THEN HOST_KEY END) AS CNT_BLUETOOTH_SPEAKER,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Audio Streamer'          THEN HOST_KEY END) AS CNT_AUDIO_STREAMER,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Dryer'                   THEN HOST_KEY END) AS CNT_DRYER,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Stick Vacuum'            THEN HOST_KEY END) AS CNT_STICK_VACUUM,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Dehumidifier'            THEN HOST_KEY END) AS CNT_DEHUMIDIFIER,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Airfryer'                THEN HOST_KEY END) AS CNT_AIRFRYER,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Soundbar'                THEN HOST_KEY END) AS CNT_SOUNDBAR,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Water Purifier'          THEN HOST_KEY END) AS CNT_WATER_PURIFIER,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Smart Scale'             THEN HOST_KEY END) AS CNT_SMART_SCALE,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Smart Hub/Gateway'       THEN HOST_KEY END) AS CNT_SMART_HUB,
    COUNT(DISTINCT CASE WHEN IOT_CAT = 'Microwave'               THEN HOST_KEY END) AS CNT_MICROWAVE,

    /* Distinct IoT categories per circuit (exclude IoT_Other from the tally) */
    COUNT(DISTINCT CASE
      WHEN IOT_CAT IS NOT NULL AND IOT_CAT <> 'IoT_Other' THEN IOT_CAT END
    ) AS DISTINCT_IOT_CATS,

    /* Total IoT devices (include IoT_Other) */
    COUNT(DISTINCT CASE WHEN IOT_CAT IS NOT NULL THEN HOST_KEY END) AS TOTAL_IOT_DEVICES
FROM iot
GROUP BY MNTH_ID, CIRCUIT
DISTRIBUTE ON (MNTH_ID, CIRCUIT);



/* ============================================================
   FIND THE DISTRIBUTION OF THE #IOT CAT
   ============================================================ */
WITH per_circuit AS (
  SELECT
      MNTH_ID,
      CIRCUIT,
      /* Count of present categories (exclude IoT_Other) */
      (CASE WHEN CNT_AIR_PURIFIER         > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_PRINTER              > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_ROBOT_VACUUM         > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_WASHING_MACHINE      > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_SMART_BULB           > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_VOICE_ASSISTANT_SPK  > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_FAN                  > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_PET_FEEDER           > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_DRIVERACK            > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_AIR_COND             > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_SMART_PLUG           > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_ROBOT                > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_SMART_SPEAKER        > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_FRIDGE               > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_BLUETOOTH_SPEAKER    > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_AUDIO_STREAMER       > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_DRYER                > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_STICK_VACUUM         > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_DEHUMIDIFIER         > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_AIRFRYER             > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_SOUNDBAR             > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_WATER_PURIFIER       > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_SMART_SCALE          > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_SMART_HUB            > 0 THEN 1 ELSE 0 END +
       CASE WHEN CNT_MICROWAVE            > 0 THEN 1 ELSE 0 END
      ) AS iot_cat_count,

      /* Total IoT device instances (include IoT_Other) */
      (CNT_AIR_PURIFIER + CNT_PRINTER + CNT_ROBOT_VACUUM + CNT_WASHING_MACHINE +
       CNT_SMART_BULB + CNT_VOICE_ASSISTANT_SPK + CNT_FAN + CNT_PET_FEEDER +
       CNT_DRIVERACK + CNT_AIR_COND + CNT_SMART_PLUG + CNT_ROBOT + CNT_SMART_SPEAKER +
       CNT_FRIDGE + CNT_BLUETOOTH_SPEAKER + CNT_AUDIO_STREAMER + CNT_DRYER +
       CNT_STICK_VACUUM + CNT_DEHUMIDIFIER + CNT_AIRFRYER + CNT_SOUNDBAR +
       CNT_WATER_PURIFIER + CNT_SMART_SCALE + CNT_SMART_HUB + CNT_MICROWAVE +
       CNT_IOT_OTHER) AS device_total_iot
  FROM TEMP_CURCUIT_DATA_AGG_CAT
)
SELECT
    MNTH_ID,
    iot_cat_count                              AS IOT_Categories_in_Circuit,
    COUNT(DISTINCT CIRCUIT)                    AS CIRCUITS,
    COUNT(DISTINCT CIRCUIT) * 1.0
      / SUM(COUNT(DISTINCT CIRCUIT)) OVER (PARTITION BY MNTH_ID) AS SHARE_OF_CIRCUITS,
    SUM(device_total_iot)                      AS DEVICES
FROM per_circuit
GROUP BY MNTH_ID, iot_cat_count
ORDER BY MNTH_ID, iot_cat_count;



/* ============================================================
   CREATE THE COMBINATION BETWEEEN THE IOT CAT
   ============================================================ */

WITH flags AS (
  SELECT
      MNTH_ID,
      CIRCUIT,
      CASE WHEN CNT_AIR_PURIFIER         > 0 THEN 1 ELSE 0 END AS f_air_purifier,
      CASE WHEN CNT_AIR_COND             > 0 THEN 1 ELSE 0 END AS f_air_conditioner,
      CASE WHEN CNT_ROBOT_VACUUM         > 0 THEN 1 ELSE 0 END AS f_robot_vacuum,
      CASE WHEN CNT_WASHING_MACHINE      > 0 THEN 1 ELSE 0 END AS f_washing_machine,
      CASE WHEN CNT_DRYER                > 0 THEN 1 ELSE 0 END AS f_dryer,
      CASE WHEN CNT_STICK_VACUUM         > 0 THEN 1 ELSE 0 END AS f_stick_vacuum,
      CASE WHEN CNT_DEHUMIDIFIER         > 0 THEN 1 ELSE 0 END AS f_dehumidifier,
      CASE WHEN CNT_AIRFRYER             > 0 THEN 1 ELSE 0 END AS f_airfryer,
      CASE WHEN CNT_FRIDGE               > 0 THEN 1 ELSE 0 END AS f_fridge,
      CASE WHEN CNT_MICROWAVE            > 0 THEN 1 ELSE 0 END AS f_microwave,
      CASE WHEN CNT_WATER_PURIFIER       > 0 THEN 1 ELSE 0 END AS f_water_purifier,
      CASE WHEN CNT_SMART_PLUG           > 0 THEN 1 ELSE 0 END AS f_smart_plug,
      CASE WHEN CNT_SMART_BULB           > 0 THEN 1 ELSE 0 END AS f_smart_bulb,
      CASE WHEN CNT_SMART_SPEAKER        > 0 THEN 1 ELSE 0 END AS f_smart_speaker,
      CASE WHEN CNT_VOICE_ASSISTANT_SPK  > 0 THEN 1 ELSE 0 END AS f_voice_assistant_speaker,
      CASE WHEN CNT_BLUETOOTH_SPEAKER    > 0 THEN 1 ELSE 0 END AS f_bluetooth_speaker,
      CASE WHEN CNT_AUDIO_STREAMER       > 0 THEN 1 ELSE 0 END AS f_audio_streamer,
      CASE WHEN CNT_SOUNDBAR             > 0 THEN 1 ELSE 0 END AS f_soundbar,
      CASE WHEN CNT_PET_FEEDER           > 0 THEN 1 ELSE 0 END AS f_pet_feeder,
      CASE WHEN CNT_ROBOT                > 0 THEN 1 ELSE 0 END AS f_robot,
      CASE WHEN CNT_SMART_SCALE          > 0 THEN 1 ELSE 0 END AS f_smart_scale,
      CASE WHEN CNT_SMART_HUB            > 0 THEN 1 ELSE 0 END AS f_smart_hub,
      CASE WHEN CNT_PRINTER              > 0 THEN 1 ELSE 0 END AS f_printer,
      CASE WHEN CNT_DRIVERACK            > 0 THEN 1 ELSE 0 END AS f_driverack,
      CASE WHEN CNT_FAN                  > 0 THEN 1 ELSE 0 END AS f_fan
  FROM TEMP_CURCUIT_DATA_AGG_CAT
),
combo AS (
  SELECT
      MNTH_ID,
      CIRCUIT,
      /* number of categories present in combo (exclude IoT_Other) */
      (f_air_purifier + f_air_conditioner + f_robot_vacuum + f_washing_machine +
       f_dryer + f_stick_vacuum + f_dehumidifier + f_airfryer + f_fridge + f_microwave +
       f_water_purifier + f_smart_plug + f_smart_bulb + f_smart_speaker +
       f_voice_assistant_speaker + f_bluetooth_speaker + f_audio_streamer + f_soundbar +
       f_pet_feeder + f_robot + f_smart_scale + f_smart_hub + f_printer + f_driverack +
       f_fan) AS cat_count,

      /* human-readable combo key (fixed order for stable grouping) */
      TRIM(BOTH '+' FROM
        CASE WHEN f_air_purifier            = 1 THEN 'Air Purifier+'            ELSE '' END ||
        CASE WHEN f_air_conditioner         = 1 THEN 'Air Conditioner+'         ELSE '' END ||
        CASE WHEN f_dehumidifier            = 1 THEN 'Dehumidifier+'            ELSE '' END ||
        CASE WHEN f_water_purifier          = 1 THEN 'Water Purifier+'          ELSE '' END ||
        CASE WHEN f_smart_hub               = 1 THEN 'Smart Hub/Gateway+'       ELSE '' END ||
        CASE WHEN f_smart_plug              = 1 THEN 'Smart Plug+'              ELSE '' END ||
        CASE WHEN f_smart_bulb              = 1 THEN 'Smart Bulb+'              ELSE '' END ||
        CASE WHEN f_smart_speaker           = 1 THEN 'Smart Speaker+'           ELSE '' END ||
        CASE WHEN f_voice_assistant_speaker = 1 THEN 'Voice Assistant Speaker+' ELSE '' END ||
        CASE WHEN f_bluetooth_speaker       = 1 THEN 'Bluetooth Speaker+'       ELSE '' END ||
        CASE WHEN f_audio_streamer          = 1 THEN 'Audio Streamer+'          ELSE '' END ||
        CASE WHEN f_soundbar                = 1 THEN 'Soundbar+'                ELSE '' END ||
        CASE WHEN f_robot_vacuum            = 1 THEN 'Robot Vacuum+'            ELSE '' END ||
        CASE WHEN f_stick_vacuum            = 1 THEN 'Stick Vacuum+'            ELSE '' END ||
        CASE WHEN f_washing_machine         = 1 THEN 'Washing Machine+'         ELSE '' END ||
        CASE WHEN f_dryer                   = 1 THEN 'Dryer+'                   ELSE '' END ||
        CASE WHEN f_fridge                  = 1 THEN 'Fridge+'                  ELSE '' END ||
        CASE WHEN f_microwave               = 1 THEN 'Microwave+'               ELSE '' END ||
        CASE WHEN f_airfryer                = 1 THEN 'Airfryer+'                ELSE '' END ||
        CASE WHEN f_pet_feeder              = 1 THEN 'Pet Feeder+'              ELSE '' END ||
        CASE WHEN f_robot                   = 1 THEN 'Robot+'                   ELSE '' END ||
        CASE WHEN f_smart_scale             = 1 THEN 'Smart Scale+'             ELSE '' END ||
        CASE WHEN f_printer                 = 1 THEN 'Printer+'                 ELSE '' END ||
        CASE WHEN f_driverack               = 1 THEN 'DriveRack+'               ELSE '' END ||
        CASE WHEN f_fan                     = 1 THEN 'Fan+'                     ELSE '' END
      ) AS combo_key
  FROM flags
)
SELECT
    MNTH_ID,
    CASE WHEN combo_key = '' THEN '(No IoT Category Present)' ELSE combo_key END AS combo_key,
    cat_count,
    COUNT(DISTINCT CIRCUIT) AS circuits,
    COUNT(DISTINCT CIRCUIT) * 1.0
      / SUM(COUNT(DISTINCT CIRCUIT)) OVER (PARTITION BY MNTH_ID) AS share
FROM combo
GROUP BY MNTH_ID, combo_key, cat_count
ORDER BY MNTH_ID, cat_count DESC, circuits DESC, combo_key;



/* ============================================================
   FIND THE LOVER OF THE BRAND (#DEVICE BRNAD/CIRCUIT)
   ============================================================ */

WITH circuits AS (
  SELECT DISTINCT MNTH_ID, CIRCUIT
  FROM TEMP_CURCUIT_DATA_DEVICE_BRAND
),
apple_counts AS (
  SELECT
      MNTH_ID,
      CIRCUIT,
      COUNT(DISTINCT HN) AS apple_cnt
  FROM TEMP_CURCUIT_DATA_DEVICE_BRAND
WHERE UPPER(TRIM(DEVICE_BRAND)) LIKE 'APPLE%'
  GROUP BY 1,2
),
joined AS (
  SELECT
      c.MNTH_ID,
      c.CIRCUIT,
      COALESCE(a.apple_cnt, 0) AS apple_cnt
  FROM circuits c
  LEFT JOIN apple_counts a
    ON a.MNTH_ID = c.MNTH_ID
   AND a.CIRCUIT = c.CIRCUIT
),
hist AS (
  SELECT
      MNTH_ID,
      apple_cnt,
      COUNT(DISTINCT CIRCUIT) AS circuits
  FROM joined
  GROUP BY 1,2
)
SELECT
  MNTH_ID,
  apple_cnt,
  circuits,
  circuits::NUMERIC / SUM(circuits) OVER (PARTITION BY MNTH_ID)                         AS share,
  SUM(circuits) OVER (PARTITION BY MNTH_ID ORDER BY apple_cnt
                      ROWS UNBOUNDED PRECEDING)
    ::NUMERIC / SUM(circuits) OVER (PARTITION BY MNTH_ID)                                AS cum_share
FROM hist
ORDER BY MNTH_ID, apple_cnt;


   
/* ============================================================
   FIND THE NUMBER FOR A USE CASE FROM NEW AGG TABLE
   ============================================================ */ 
   
SELECT
	COUNT(*)
    ,AVG(APP_TOTAL_DATA_MB)
FROM SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL
WHERE
    -- multi-device, heavy households
    DVC_TOTAL_DEVICE >= 8

    -- no Mesh Wi-Fi installed
    AND COALESCE(DVC_MESH_WIFI_FLAG, 0) = 0    
    ;

    
SELECT COUNT(*),AVG(APP_TOTAL_DATA_MB)
FROM SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL
WHERE DVC_MOBILE_BRAND_APPLE_CNT + DVC_TABLET_BRAND_APPLE_CNT + DVC_PC_BRAND_APPLE_CNT + DVC_TV_BOX_BRAND_APPLE_TV_CNT + DVC_WEARABLE_BRAND_APPLE_WATCH_CNT >=4;


SELECT COUNT(*),AVG(APP_TOTAL_DATA_MB)
FROM SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL
WHERE (DVC_TV_FLAG = 1 OR DVC_TV_BOX_FLAG = 1)
AND DVC_TV_BOX_BRAND_OPTV_CNT = 0;


SELECT COUNT(*)
FROM SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL
WHERE DVC_DEVICE_GRP_CNT >= 3;


SELECT 
TOTAL_BILL_AMNT
FROM SANDBOX_NZ.ADMIN.FCT_INVC_PROD_HBB
WHERE MNTH_ID = 202508;


SELECT COUNT(*) FROM SANDBOX_NZ.ADMIN.DIM_PROD
WHERE PROD_TYP_CD = 2 /* HBB */
AND PROD_SUB_TYP IN ('I', 'IF', 'INF', 'Q', 'FT')
AND DWH_PROD_STAT = 'A';


-- CCTV CIRCUIT    
SELECT count(*), AVG(APP_TOTAL_DATA_MB)
FROM SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL 
WHERE DVC_CAMERA_CCTV_CNT >= 1
OR APP_SMART_HOME_IOT_SMARTTV_PCT >= 0.01;
    
    
    
-- DISTRIBUTION OF THE CCTV WITH %OPER AND %CLOUD    
WITH base AS (
    SELECT
          ASSET_NUM
        , COALESCE(DVC_CAMERA_CCTV_CNT,0)            AS CCTV_CNT
        , CASE 
              WHEN COALESCE(DVC_CAMERA_BRAND_OPER_CNT,0) > 0 
                   THEN 1 ELSE 0 
          END                                        AS HAS_OPER_CCTV
        , CASE 
              WHEN COALESCE(APP_CLOUD_STORAGE_FLAG,0) = 1 
                   THEN 1 ELSE 0 
          END                                        AS HAS_CLOUD_STORAGE
        , COALESCE(APP_CLOUD_STORAGE_DATA_MB,0)      AS CLOUD_DATA_MB
        , COALESCE(APP_SMART_HOME_IOT_SMARTTV_PCT,0) AS SMARTTV_PCT
    FROM SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL
),

segment_base AS (
    -- keep circuits that have CCTV OR SmartTV IoT usage ≥ 1%
    SELECT
          ASSET_NUM
        , CCTV_CNT
        , HAS_OPER_CCTV
        , HAS_CLOUD_STORAGE
        , CLOUD_DATA_MB
        , SMARTTV_PCT
    FROM base
    WHERE CCTV_CNT > 0
       OR SMARTTV_PCT >= 0.01
),

avg_cloud AS (
    -- average cloud usage among circuits that actually have cloud storage
    SELECT
        AVG(CLOUD_DATA_MB) AS AVG_CLOUD_MB
    FROM segment_base
    WHERE HAS_CLOUD_STORAGE = 1
)

SELECT
      s.CCTV_CNT                                           AS CCTV_PER_CIRCUIT      -- #CCTV
    , COUNT(*)                                             AS CIRCUIT_CNT           -- #Circuit
    , 100.0 * COUNT(*) 
        / SUM(COUNT(*)) OVER ()                            AS MIX_PCT               -- %Mix
    , 100.0 * SUM(s.HAS_OPER_CCTV) 
        / COUNT(*)                                         AS OPER_PCT              -- %Oper

    , 100.0 * SUM(
          CASE 
              WHEN s.HAS_CLOUD_STORAGE = 1
               AND s.CLOUD_DATA_MB >= a.AVG_CLOUD_MB
              THEN 1 ELSE 0
          END
      ) / COUNT(*)                                         AS CLOUD_PCT             -- %Cloud (>= avg)

FROM segment_base s
CROSS JOIN avg_cloud a
GROUP BY
    s.CCTV_CNT,
    a.AVG_CLOUD_MB
ORDER BY
    s.CCTV_CNT;

-- FIND THE DISTRIBUTION OF THE APPLE LOVER CIRCUIT
WITH base AS (
    SELECT
          ASSET_NUM
        , COALESCE(DVC_MOBILE_BRAND_APPLE_CNT,0)         AS APPLE_MOBILE_CNT
        , COALESCE(DVC_TABLET_BRAND_APPLE_CNT,0)         AS APPLE_TABLET_CNT
        , COALESCE(DVC_PC_BRAND_APPLE_CNT,0)             AS APPLE_PC_CNT
        , COALESCE(DVC_TV_BOX_BRAND_APPLE_TV_CNT,0)      AS APPLE_TV_BOX_CNT
        , COALESCE(DVC_WEARABLE_BRAND_APPLE_WATCH_CNT,0) AS APPLE_WEARABLE_CNT
    FROM SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL
),

apple_circuits AS (
    SELECT
          ASSET_NUM
        , APPLE_MOBILE_CNT
        , APPLE_TABLET_CNT
        , APPLE_PC_CNT
        , APPLE_TV_BOX_CNT
        , APPLE_WEARABLE_CNT
        , ( APPLE_MOBILE_CNT
          + APPLE_TABLET_CNT
          + APPLE_PC_CNT
          + APPLE_TV_BOX_CNT
          + APPLE_WEARABLE_CNT ) AS APPLE_DEVICE_CNT   -- total # Apple devices in circuit
    FROM base
    WHERE ( APPLE_MOBILE_CNT
          + APPLE_TABLET_CNT
          + APPLE_PC_CNT
          + APPLE_TV_BOX_CNT
          + APPLE_WEARABLE_CNT ) > 0       -- keep only circuits with Apple
)

SELECT
      APPLE_DEVICE_CNT                                   AS APPLE_DEVICE_COUNT  -- #APPLE / circuit
    , COUNT(*)                                           AS CIRCUIT_CNT         -- #CIRCUIT in this bucket
    , SUM(APPLE_MOBILE_CNT)                              AS MOBILE_DEVICE_CNT
    , SUM(APPLE_TABLET_CNT)                              AS TABLET_DEVICE_CNT
    , SUM(APPLE_PC_CNT)                                  AS PC_DEVICE_CNT
    , SUM(APPLE_TV_BOX_CNT)                              AS TV_BOX_DEVICE_CNT
    , SUM(APPLE_WEARABLE_CNT)                            AS WEARABLE_DEVICE_CNT
FROM apple_circuits
GROUP BY
    APPLE_DEVICE_CNT
ORDER BY
    APPLE_DEVICE_CNT;



-- FIND THE UPGRADE TRU ID BOX 3 GAMER
SELECT COUNT(*),AVG(APP_TOTAL_DATA_MB)
FROM SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL
WHERE APP_GAMING_AND_STREAMING_PLATFORMS_PCT >= 0.1
AND DVC_TV_BOX_BRAND_OPTV_CNT > 0;




