/* ============================================================================
   BUSINESS LOAN APPROVAL AUTOMATION — COMPLETE SQL CODE
   Central Bank Project | SBA Historical Borrower Dataset
   Author: Priyanka Giri
   Database: PostgreSQL (banking_db) | Table: sba_loans_raw
   ============================================================================ */


/* ============================================================================
   SECTION 1 — TABLE CREATION & DATA IMPORT (DDL)
   ============================================================================ */

CREATE TABLE sba_loans_raw (
    loannr_chkdgt TEXT, name TEXT, city TEXT, state TEXT, zip TEXT, bank TEXT, bankstate TEXT, naics TEXT,
    approvaldate TEXT, approvalfy TEXT, term INTEGER, noemp INTEGER, newexist INTEGER, createjob INTEGER,
    retainedjob INTEGER, franchisecode TEXT, urbanrural INTEGER, revlinecr TEXT, lowdoc TEXT,
    chgoffdate TEXT, disbursementdate TEXT, disbursementgross TEXT, balancegross TEXT, mis_status TEXT,
    chgoffprin_gr TEXT, gr_appv TEXT, sba_appv TEXT
);

-- Bulk-load the raw CSV (psql client-side command)
\copy sba_loans_raw FROM 'C:/Users/91626/Desktop/SBAnational.csv' DELIMITER ',' CSV HEADER;


/* ============================================================================
   SECTION 2 — DATA CLEANING (DDL + DML)
   ============================================================================ */

-- 2.1  Add numeric columns to hold cleaned currency values
ALTER TABLE sba_loans_raw
  ADD COLUMN disbursementgross_num NUMERIC,
  ADD COLUMN balancegross_num NUMERIC,
  ADD COLUMN gr_appv_num NUMERIC,
  ADD COLUMN sba_appv_num NUMERIC,
  ADD COLUMN chgoffprin_gr_num NUMERIC;

-- 2.2  Strip '$' and ',' from currency text fields and cast to NUMERIC
UPDATE sba_loans_raw SET
  disbursementgross_num = NULLIF(REPLACE(REPLACE(TRIM(disbursementgross), '$', ''), ',', ''), '')::NUMERIC,
  balancegross_num      = NULLIF(REPLACE(REPLACE(TRIM(balancegross), '$', ''), ',', ''), '')::NUMERIC,
  gr_appv_num            = NULLIF(REPLACE(REPLACE(TRIM(gr_appv), '$', ''), ',', ''), '')::NUMERIC,
  sba_appv_num           = NULLIF(REPLACE(REPLACE(TRIM(sba_appv), '$', ''), ',', ''), '')::NUMERIC,
  chgoffprin_gr_num      = NULLIF(REPLACE(REPLACE(TRIM(chgoffprin_gr), '$', ''), ',', ''), '')::NUMERIC;

-- 2.3  Add DATE columns and parse the raw text dates
ALTER TABLE sba_loans_raw
  ADD COLUMN approvaldate_d DATE,
  ADD COLUMN disbursementdate_d DATE,
  ADD COLUMN chgoffdate_d DATE;

UPDATE sba_loans_raw SET
  approvaldate_d      = NULLIF(TRIM(approvaldate), '')::DATE,
  disbursementdate_d  = NULLIF(TRIM(disbursementdate), '')::DATE,
  chgoffdate_d         = NULLIF(TRIM(chgoffdate), '')::DATE;

-- 2.4  Verify cleaned values
SELECT name, disbursementgross, disbursementgross_num, gr_appv, gr_appv_num
FROM sba_loans_raw LIMIT 10;

SELECT name, approvaldate, approvaldate_d
FROM sba_loans_raw WHERE approvaldate LIKE '%-80' LIMIT 5;

-- 2.5  Drop the old messy TEXT columns and rename the clean ones into place
ALTER TABLE sba_loans_raw
  DROP COLUMN disbursementgross, DROP COLUMN balancegross, DROP COLUMN gr_appv,
  DROP COLUMN sba_appv, DROP COLUMN chgoffprin_gr, DROP COLUMN approvaldate,
  DROP COLUMN disbursementdate, DROP COLUMN chgoffdate;

ALTER TABLE sba_loans_raw RENAME COLUMN disbursementgross_num TO disbursementgross;
ALTER TABLE sba_loans_raw RENAME COLUMN gr_appv_num TO gr_appv;

-- 2.6  Final structure check
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'sba_loans_raw'
ORDER BY ordinal_position;


/* ============================================================================
   SECTION 3 — JOINS
   ============================================================================ */

-- 3.1  Build a subset table of high-value loans (DDL: CREATE TABLE AS SELECT)
CREATE TABLE high_risk_loans AS
SELECT loannr_chkdgt, name, bank, gr_appv
FROM sba_loans_raw
WHERE gr_appv > 500000;

-- 3.2  INNER JOIN the subset back to the full table for enriched detail
SELECT a.name, a.city, a.state, a.bank, a.gr_appv
FROM sba_loans_raw a
INNER JOIN high_risk_loans b ON a.loannr_chkdgt = b.loannr_chkdgt
LIMIT 10;


/* ============================================================================
   SECTION 4 — EXPLORING APPROVAL METRICS
   Comparing historical default (CHGOFF) rate across candidate signals
   ============================================================================ */

-- 4.1  New vs Existing Business
SELECT newexist, mis_status, COUNT(*)
FROM sba_loans_raw GROUP BY newexist, mis_status ORDER BY newexist;

-- 4.2  Low Documentation Flag
SELECT lowdoc, mis_status, COUNT(*)
FROM sba_loans_raw GROUP BY lowdoc, mis_status ORDER BY lowdoc;

-- 4.3  Loan Term (bucketed)
SELECT
  CASE
    WHEN term < 60 THEN 'Short (<5yr)'
    WHEN term BETWEEN 60 AND 120 THEN 'Medium (5-10yr)'
    ELSE 'Long (>10yr)'
  END AS term_bucket,
  mis_status, COUNT(*)
FROM sba_loans_raw
GROUP BY term_bucket, mis_status
ORDER BY term_bucket;

-- 4.4  SBA Guarantee Ratio
SELECT
  CASE
    WHEN (sba_appv / NULLIF(gr_appv, 0)) >= 0.8 THEN 'High Guarantee (>=80%)'
    WHEN (sba_appv / NULLIF(gr_appv, 0)) >= 0.5 THEN 'Medium (50-80%)'
    ELSE 'Low (<50%)'
  END AS guarantee_bucket,
  mis_status, COUNT(*)
FROM sba_loans_raw
GROUP BY guarantee_bucket, mis_status;

-- 4.5  Revolving Line of Credit
SELECT revlinecr, mis_status, COUNT(*)
FROM sba_loans_raw GROUP BY revlinecr, mis_status ORDER BY revlinecr;


/* ============================================================================
   SECTION 5 — WINDOW FUNCTIONS
   Exploring "ideal applicant" profiles among non-defaulted borrowers
   ============================================================================ */

-- 5.1  Top 5 highest-value successful loans overall (RANK)
SELECT name, bank, state, gr_appv, term,
       RANK() OVER (ORDER BY gr_appv DESC) AS rank_by_amount
FROM sba_loans_raw
WHERE mis_status = 'P I F'
ORDER BY rank_by_amount
LIMIT 5;

-- 5.2  Top 3 successful loans PER STATE (ROW_NUMBER + PARTITION BY)
SELECT *
FROM (
  SELECT name, state, bank, gr_appv,
         ROW_NUMBER() OVER (PARTITION BY state ORDER BY gr_appv DESC) AS state_rank
  FROM sba_loans_raw
  WHERE mis_status = 'P I F'
) ranked
WHERE state_rank <= 3
ORDER BY state, state_rank
LIMIT 30;


/* ============================================================================
   SECTION 6 — FINAL QUERY: LOAN ELIGIBILITY (APPROVED / DECLINED COHORTS)
   Decision rule: Approve if at least 2 of 3 conditions are true:
     1) term >= 60 months
     2) lowdoc = 'Y'
     3) revlinecr = 'N'
   ============================================================================ */

-- 6.1  Add the eligibility column
ALTER TABLE sba_loans_raw ADD COLUMN loan_eligibility TEXT;

-- 6.2  Populate it using the 3-metric decision rule
UPDATE sba_loans_raw
SET loan_eligibility = CASE
  WHEN (
    (CASE WHEN term >= 60 THEN 1 ELSE 0 END) +
    (CASE WHEN lowdoc = 'Y' THEN 1 ELSE 0 END) +
    (CASE WHEN revlinecr = 'N' THEN 1 ELSE 0 END)
  ) >= 2
  THEN 'Approved'
  ELSE 'Declined'
END;

-- 6.3  Cohort sizes (uses a window function: SUM(...) OVER () for the % of total)
SELECT loan_eligibility, COUNT(*),
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM sba_loans_raw
GROUP BY loan_eligibility;

-- 6.4  Validation — confirm the Approved cohort actually defaults less often
SELECT loan_eligibility, mis_status, COUNT(*)
FROM sba_loans_raw
GROUP BY loan_eligibility, mis_status
ORDER BY loan_eligibility;

/* Result: Approved cohort defaults at 8.2% vs 25.5% for Declined —
   confirming the automated rule meaningfully separates risk. */
