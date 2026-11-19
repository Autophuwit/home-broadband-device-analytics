/* ============================================================
   ONE-OFF SETUP - RUN ONCE, NOT EVERY MONTH
   ------------------------------------------------------------
   Adds the two columns that household_device_classification.sql fills every month
   (section "UPDATE THE INSTALL DATE AND ARPU INTO AGG TABLE").
   Kept out of the monthly script: Netezza has no ADD COLUMN IF NOT EXISTS, so with
   ON_ERROR_STOP a re-run of the month would stop on "column already exists".
       nzsql -v ON_ERROR_STOP=1 -f 00_setup_once.sql
   ============================================================ */

-- 1) Add INSTALL_DT as a timestamp
ALTER TABLE SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL
ADD COLUMN INSTALL_DT TIMESTAMP;

-- 2) Add TOTAL_BILL_AMNT as a numeric amount
ALTER TABLE SANDBOX_NZ.ADMIN.TEAM_HBB_SUBR_USAGE_ALL
ADD COLUMN TOTAL_BILL_AMNT NUMERIC(12,2);
