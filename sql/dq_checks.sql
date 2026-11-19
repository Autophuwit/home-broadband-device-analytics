/* ============================================================
   DATA QUALITY CHECKS - HOUSEHOLD DEVICE TABLES
   ------------------------------------------------------------
   Run right after household_device_classification.sql for the same month:
       nzsql -v RUN_MNTH=202507 -f dq_checks.sql
   The rebuild keeps the previous run as *_OLD, so drift is checked against last month.
   One row per check (ACTUAL vs EXPECTED -> PASS / FAIL) + a summary row.
   Any FAIL = hold the use-case target lists until it is explained.

   A. Source -> target       circuits vs product dimension, cleaning keep-ratio vs the raw Wi-Fi log
   B. Keys                   one row per home, one classification per hostname
   C. Classification health  share classified, share of NULL hostnames
   D. Drift vs last month    homes, devices per home, smartphone share
   ============================================================ */


/* ============================================================
   0. RAW SOURCE FOR THE MONTH (INDIVIDUAL HOMES ONLY, SAME FILTER AS THE PIPELINE)
   ============================================================ */
DROP TABLE TEMP_DQ_HOME IF EXISTS;

CREATE TEMP TABLE TEMP_DQ_HOME AS
SELECT DISTINCT REF_RESRE_NBR AS CIRCUIT
FROM SANDBOX_NZ.ADMIN.DIM_PROD
WHERE PROD_TYP_CD = 2
  AND PROD_SUB_TYP IN ('I','IF','INF','Q','FT')
  AND SUBSTR(REF_RESRE_NBR, 1, 2) IN ('88','NF','91','96')
DISTRIBUTE ON (CIRCUIT);

DROP TABLE TEMP_DQ_RAW IF EXISTS;

CREATE TEMP TABLE TEMP_DQ_RAW AS
SELECT
     COUNT(DISTINCT A.CIRCUIT)                                              AS RAW_CIRCUIT
    ,COUNT(DISTINCT A.CIRCUIT || '|' || COALESCE(A.WIFI_STA_INFORMATION_HOSTNAME, '__NULL__')) AS RAW_DEVICE
FROM NZ_MART.admin.ROUTER_AGENT_WIFI_STA_INFO A
JOIN TEMP_DQ_HOME H
  ON H.CIRCUIT = A.CIRCUIT
WHERE CAST(SUBSTR(CAST(A.DATE_ID AS VARCHAR(8)), 1, 6) AS INT) = :RUN_MNTH;


/* ============================================================
   1. HOME-LEVEL TOTALS - THIS RUN AND LAST RUN (_OLD)
   ============================================================ */
DROP TABLE TEMP_DQ_HOME_TOT IF EXISTS;

CREATE TEMP TABLE TEMP_DQ_HOME_TOT AS
SELECT
     'NEW' AS RUN
    ,COUNT(*)                                                               AS N_HOME
    ,COUNT(DISTINCT MNTH_ID || '|' || CIRCUIT)                              AS N_HOME_DISTINCT
    ,SUM(COUNT_MOBILE_DEVICE + COUNT_TABLET_DEVICE + COUNT_PC_DEVICE + COUNT_TV_DEVICE + COUNT_TV_BOX_DEVICE
       + COUNT_CCTV_DEVICE + COUNT_IOT_DEVICE + COUNT_MESH_WIFI_DEVICE + COUNT_WEARABLE_DEVICE
       + COUNT_OTHER_DEVICE + COUNT_NULL_DEVICE)                            AS N_DEVICE
    ,SUM(COUNT_MOBILE_DEVICE)                                               AS N_MOBILE
    ,SUM(COUNT_OTHER_DEVICE + COUNT_NULL_DEVICE)                            AS N_UNCLASSIFIED
    ,SUM(COUNT_NULL_DEVICE)                                                 AS N_NULL_HOSTNAME
FROM SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE
WHERE MNTH_ID = :RUN_MNTH

UNION ALL

SELECT
     'OLD'
    ,COUNT(*)
    ,COUNT(DISTINCT MNTH_ID || '|' || CIRCUIT)
    ,SUM(COUNT_MOBILE_DEVICE + COUNT_TABLET_DEVICE + COUNT_PC_DEVICE + COUNT_TV_DEVICE + COUNT_TV_BOX_DEVICE
       + COUNT_CCTV_DEVICE + COUNT_IOT_DEVICE + COUNT_MESH_WIFI_DEVICE + COUNT_WEARABLE_DEVICE
       + COUNT_OTHER_DEVICE + COUNT_NULL_DEVICE)
    ,SUM(COUNT_MOBILE_DEVICE)
    ,SUM(COUNT_OTHER_DEVICE + COUNT_NULL_DEVICE)
    ,SUM(COUNT_NULL_DEVICE)
FROM SANDBOX_NZ.ADMIN.AUTO_HBB_SUBR_USAGE_DEVICE_OLD;


/* ============================================================
   2. RUN ALL CHECKS
   ============================================================ */
DROP TABLE TEMP_DQ_RESULT IF EXISTS;

CREATE TEMP TABLE TEMP_DQ_RESULT AS
-- A1. homes in the device table must be individual home-broadband circuits
SELECT
     'A1' AS CHECK_NO
    ,'Homes in device table <= individual circuits in product dimension' AS CHECK_NAME
    ,N.N_HOME AS ACTUAL
    ,(SELECT COUNT(*) FROM TEMP_DQ_HOME) AS EXPECTED
    ,CASE WHEN N.N_HOME > 0 AND N.N_HOME <= (SELECT COUNT(*) FROM TEMP_DQ_HOME) THEN 'PASS' ELSE 'FAIL' END AS STATUS
FROM TEMP_DQ_HOME_TOT N WHERE N.RUN = 'NEW'

UNION ALL
-- A2. cleaning keep-ratio: real devices / raw device records (baseline ~65%; outside 50-80% = filter or feed change)
SELECT
     'A2', '% raw device records kept after cleaning (50-80%)'
    ,ROUND(100.0 * N.N_DEVICE / NULLIF(R.RAW_DEVICE, 0), 2), 65
    ,CASE WHEN 100.0 * N.N_DEVICE / NULLIF(R.RAW_DEVICE, 0) BETWEEN 50 AND 80 THEN 'PASS' ELSE 'FAIL' END
FROM TEMP_DQ_HOME_TOT N CROSS JOIN TEMP_DQ_RAW R WHERE N.RUN = 'NEW'

UNION ALL
-- A3. homes seen in the raw log that keep at least one device (>= 80%)
SELECT
     'A3', '% raw homes with at least one device after cleaning (>= 80%)'
    ,ROUND(100.0 * N.N_HOME / NULLIF(R.RAW_CIRCUIT, 0), 2), 80
    ,CASE WHEN 100.0 * N.N_HOME / NULLIF(R.RAW_CIRCUIT, 0) >= 80 THEN 'PASS' ELSE 'FAIL' END
FROM TEMP_DQ_HOME_TOT N CROSS JOIN TEMP_DQ_RAW R WHERE N.RUN = 'NEW'

UNION ALL
-- B1. one row per home per month
SELECT
     'B1', 'Duplicate homes in device table'
    ,N.N_HOME - N.N_HOME_DISTINCT, 0
    ,CASE WHEN N.N_HOME = N.N_HOME_DISTINCT THEN 'PASS' ELSE 'FAIL' END
FROM TEMP_DQ_HOME_TOT N WHERE N.RUN = 'NEW'

UNION ALL
-- B2. the rule engine is deterministic: one group / brand / category per hostname
SELECT
     'B2', 'Hostnames with more than one classification in the master dictionary'
    ,COUNT(*), 0
    ,CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (
    SELECT HN FROM SANDBOX_NZ.ADMIN.AUTO_HBB_MASTER_DEVICE
    GROUP BY HN HAVING COUNT(*) > 1
) X

UNION ALL
-- C1. classification coverage (baseline ~77% classified)
SELECT
     'C1', '% devices classified into a device group (>= 75%)'
    ,ROUND(100.0 - 100.0 * N.N_UNCLASSIFIED / NULLIF(N.N_DEVICE, 0), 2), 75
    ,CASE WHEN 100.0 - 100.0 * N.N_UNCLASSIFIED / NULLIF(N.N_DEVICE, 0) >= 75 THEN 'PASS' ELSE 'FAIL' END
FROM TEMP_DQ_HOME_TOT N WHERE N.RUN = 'NEW'

UNION ALL
-- C2. NULL hostnames (a jump means the router feed stopped sending names)
SELECT
     'C2', '% devices with a NULL hostname (<= 1%)'
    ,ROUND(100.0 * N.N_NULL_HOSTNAME / NULLIF(N.N_DEVICE, 0), 2), 1
    ,CASE WHEN 100.0 * N.N_NULL_HOSTNAME / NULLIF(N.N_DEVICE, 0) <= 1 THEN 'PASS' ELSE 'FAIL' END
FROM TEMP_DQ_HOME_TOT N WHERE N.RUN = 'NEW'

UNION ALL
-- D1. homes vs last run (+/-5%)
SELECT
     'D1', 'Homes: % change vs last run (+/-5%)'
    ,ROUND(100.0 * (N.N_HOME - O.N_HOME) / NULLIF(O.N_HOME, 0), 2), 5
    ,CASE WHEN O.N_HOME > 0 AND ABS(100.0 * (N.N_HOME - O.N_HOME) / O.N_HOME) <= 5 THEN 'PASS' ELSE 'FAIL' END
FROM TEMP_DQ_HOME_TOT N CROSS JOIN TEMP_DQ_HOME_TOT O WHERE N.RUN = 'NEW' AND O.RUN = 'OLD'

UNION ALL
-- D2. devices per home vs last run (+/-10%) - catches a change in the activity filter or the feed
SELECT
     'D2', 'Devices per home: % change vs last run (+/-10%)'
    ,ROUND(100.0 * (1.0 * N.N_DEVICE / N.N_HOME - 1.0 * O.N_DEVICE / O.N_HOME) / NULLIF(1.0 * O.N_DEVICE / O.N_HOME, 0), 2), 10
    ,CASE WHEN O.N_HOME > 0 AND N.N_HOME > 0
           AND ABS(100.0 * (1.0 * N.N_DEVICE / N.N_HOME - 1.0 * O.N_DEVICE / O.N_HOME) / (1.0 * O.N_DEVICE / O.N_HOME)) <= 10
          THEN 'PASS' ELSE 'FAIL' END
FROM TEMP_DQ_HOME_TOT N CROSS JOIN TEMP_DQ_HOME_TOT O WHERE N.RUN = 'NEW' AND O.RUN = 'OLD'

UNION ALL
-- D3. smartphone share of devices vs last run (+/-3pp) - catches a rule change that moved a big group
SELECT
     'D3', 'Smartphone share of devices: change vs last run in pp (+/-3)'
    ,ROUND(100.0 * N.N_MOBILE / NULLIF(N.N_DEVICE, 0) - 100.0 * O.N_MOBILE / NULLIF(O.N_DEVICE, 0), 2), 3
    ,CASE WHEN ABS(100.0 * N.N_MOBILE / NULLIF(N.N_DEVICE, 0) - 100.0 * O.N_MOBILE / NULLIF(O.N_DEVICE, 0)) <= 3 THEN 'PASS' ELSE 'FAIL' END
FROM TEMP_DQ_HOME_TOT N CROSS JOIN TEMP_DQ_HOME_TOT O WHERE N.RUN = 'NEW' AND O.RUN = 'OLD';


/* ============================================================
   3. RESULT
   ============================================================ */
SELECT * FROM TEMP_DQ_RESULT ORDER BY CHECK_NO;

SELECT
     :RUN_MNTH AS MNTH_ID
    ,COUNT(*) AS CHECKS
    ,SUM(CASE WHEN STATUS = 'FAIL' THEN 1 ELSE 0 END) AS FAILED
    ,CASE WHEN SUM(CASE WHEN STATUS = 'FAIL' THEN 1 ELSE 0 END) = 0 THEN 'OK TO PUBLISH' ELSE 'HOLD - CHECK FAILED ROWS' END AS RESULT
FROM TEMP_DQ_RESULT;
