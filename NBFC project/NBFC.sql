Use NBFC;

--  SCHEMA DEFINITION & DECLARATIVE RANGE PARTITIONING

DROP SCHEMA IF EXISTS finease CASCADE;
CREATE SCHEMA finease;
SET search_path TO finease, public;

CREATE TABLE branches (
    branch_id        VARCHAR(10) PRIMARY KEY,
    branch_name      VARCHAR(100) NOT NULL,
    city             VARCHAR(50)  NOT NULL,
    state            VARCHAR(50)  NOT NULL,
    region           VARCHAR(30)  NOT NULL,
    parent_branch_id VARCHAR(10)  REFERENCES branches(branch_id)
);

CREATE TABLE agents (
    agent_id         VARCHAR(10) PRIMARY KEY,
    branch_id        VARCHAR(10) NOT NULL REFERENCES branches(branch_id),
    join_date        DATE        NOT NULL,
    manager_agent_id VARCHAR(10) REFERENCES agents(agent_id)
);

CREATE TABLE customers (
    customer_id      VARCHAR(12) PRIMARY KEY,
    age              INT         NOT NULL CHECK (age BETWEEN 18 AND 100),
    gender           VARCHAR(10) NOT NULL,
    city             VARCHAR(50) NOT NULL,
    income_band      VARCHAR(20) NOT NULL,
    cibil_score      INT,
    employment_type  VARCHAR(30) NOT NULL DEFAULT 'Unknown'
);

CREATE TABLE loans (
    loan_id          VARCHAR(12) PRIMARY KEY,
    customer_id      VARCHAR(12)    NOT NULL REFERENCES customers(customer_id),
    branch_id        VARCHAR(10)    NOT NULL REFERENCES branches(branch_id),
    product          VARCHAR(30)    NOT NULL CHECK (product IN ('Two-Wheeler', 'Personal', 'Gold')),
    disbursal_date   DATE           NOT NULL,
    principal        NUMERIC(14,2)  NOT NULL CHECK (principal > 0),
    rate_pct         NUMERIC(5,2)   NOT NULL CHECK (rate_pct > 0),
    tenure_months    INT            NOT NULL CHECK (tenure_months > 0),
    emi              NUMERIC(12,2)  NOT NULL CHECK (emi > 0)
);

-- RANGE-partitioned emi_schedule by year 
CREATE TABLE emi_schedule (
    loan_id          VARCHAR(12)    NOT NULL REFERENCES loans(loan_id),
    emi_no           INT            NOT NULL CHECK (emi_no > 0),
    due_date         DATE           NOT NULL,
    emi_amount       NUMERIC(12,2)  NOT NULL CHECK (emi_amount > 0),
    principal_part   NUMERIC(12,2)  NOT NULL CHECK (principal_part >= 0),
    interest_part    NUMERIC(12,2)  NOT NULL CHECK (interest_part >= 0),
    PRIMARY KEY (loan_id, emi_no, due_date)
) PARTITION BY RANGE (due_date);

CREATE TABLE emi_schedule_2024 PARTITION OF emi_schedule FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE emi_schedule_2025 PARTITION OF emi_schedule FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE emi_schedule_2026 PARTITION OF emi_schedule FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE emi_schedule_2027 PARTITION OF emi_schedule FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');
CREATE TABLE emi_schedule_2028 PARTITION OF emi_schedule FOR VALUES FROM ('2028-01-01') TO ('2029-01-01');
CREATE TABLE emi_schedule_2029 PARTITION OF emi_schedule FOR VALUES FROM ('2029-01-01') TO ('2030-01-01');
CREATE TABLE emi_schedule_default PARTITION OF emi_schedule DEFAULT;

-- RANGE-partitioned payments by year
CREATE TABLE payments (
    payment_id       VARCHAR(15)    NOT NULL,
    loan_id          VARCHAR(12)    NOT NULL REFERENCES loans(loan_id),
    emi_no           INT            NOT NULL CHECK (emi_no > 0),
    paid_date        DATE           NOT NULL,
    amount           NUMERIC(12,2)  NOT NULL CHECK (amount > 0),
    mode             VARCHAR(30)    NOT NULL,
    agent_id         VARCHAR(10)    NOT NULL REFERENCES agents(agent_id),
    is_reversed      BOOLEAN        NOT NULL DEFAULT FALSE,
    PRIMARY KEY (payment_id, paid_date)
) PARTITION BY RANGE (paid_date);

CREATE TABLE payments_2024 PARTITION OF payments FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE payments_2025 PARTITION OF payments FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE payments_2026 PARTITION OF payments FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE payments_default PARTITION OF payments DEFAULT;

CREATE TABLE monthly_balance_snapshot (
    month_end        DATE           NOT NULL,
    loan_id          VARCHAR(12)    NOT NULL REFERENCES loans(loan_id),
    outstanding      NUMERIC(14,2)  NOT NULL CHECK (outstanding >= 0),
    dpd              INT            NOT NULL CHECK (dpd >= 0),
    bucket           VARCHAR(15)    NOT NULL CHECK (bucket IN ('Current', '1-30', '31-60', '61-90', '90+')),
    PRIMARY KEY (month_end, loan_id)
);

-- Audit & Quarantine tables for ETL hygiene and month-end logging
CREATE TABLE payments_quarantine (
    quarantine_id    SERIAL PRIMARY KEY,
    payment_id       VARCHAR(15),
    loan_id          VARCHAR(12),
    emi_no           INT,
    paid_date        DATE,
    amount           NUMERIC(12,2),
    mode             VARCHAR(30),
    agent_id         VARCHAR(10),
    reject_reason    TEXT NOT NULL,
    logged_at        TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE month_end_close_log (
    close_id         SERIAL PRIMARY KEY,
    target_month_end DATE NOT NULL,
    status           VARCHAR(20) NOT NULL,
    loans_processed  INT DEFAULT 0,
    error_message    TEXT,
    executed_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

--  COMPOSITE INDEXES & QUERY PLAN VERIFICATION 

CREATE INDEX idx_mbs_month_bucket_loan ON monthly_balance_snapshot (month_end, bucket) INCLUDE (outstanding, dpd);
CREATE INDEX idx_mbs_loan_month        ON monthly_balance_snapshot (loan_id, month_end) INCLUDE (bucket, outstanding);
CREATE INDEX idx_loans_prod_branch     ON loans (product, branch_id, disbursal_date) INCLUDE (customer_id, principal);
CREATE INDEX idx_emi_due_loan          ON emi_schedule (due_date, loan_id, emi_no) INCLUDE (emi_amount);
CREATE INDEX idx_pay_agent_date        ON payments (agent_id, paid_date) INCLUDE (loan_id, emi_no, amount) WHERE is_reversed = FALSE;
CREATE INDEX idx_pay_loan_emi          ON payments (loan_id, emi_no) INCLUDE (paid_date, amount) WHERE is_reversed = FALSE;

-- Verify partition pruning and Index-Only Scan efficiency
EXPLAIN (ANALYZE, BUFFERS)
SELECT due_date, COUNT(*) AS emi_cnt, SUM(emi_amount) AS total_due
FROM emi_schedule
WHERE due_date BETWEEN '2025-01-01' AND '2025-12-31'
GROUP BY due_date;

--  MONTH-END OUTSTANDING BY DPD BUCKET & GROSS NPA % TREND

CREATE OR REPLACE VIEW vw_month_end_dpd_npa_trend AS
WITH monthly_buckets AS (
    SELECT
        month_end,
        COUNT(DISTINCT loan_id) AS active_loans,
        SUM(outstanding) AS total_outstanding,
        SUM(CASE WHEN bucket = 'Current' THEN outstanding ELSE 0 END) AS current_pos,
        SUM(CASE WHEN bucket = '1-30'    THEN outstanding ELSE 0 END) AS dpd_1_30_pos,
        SUM(CASE WHEN bucket = '31-60'   THEN outstanding ELSE 0 END) AS dpd_31_60_pos,
        SUM(CASE WHEN bucket = '61-90'   THEN outstanding ELSE 0 END) AS dpd_61_90_pos,
        SUM(CASE WHEN bucket = '90+'     THEN outstanding ELSE 0 END) AS gnpa_90_plus_pos,
        COUNT(CASE WHEN bucket = '90+'   THEN 1 END)                  AS gnpa_loan_count
    FROM monthly_balance_snapshot
    GROUP BY month_end
)
SELECT
    month_end,
    active_loans,
    ROUND(total_outstanding / 10000000.0, 2) AS total_aum_cr,
    ROUND(current_pos / 10000000.0, 2)       AS current_aum_cr,
    ROUND(dpd_1_30_pos / 10000000.0, 2)      AS dpd_1_30_aum_cr,
    ROUND(dpd_31_60_pos / 10000000.0, 2)     AS dpd_31_60_aum_cr,
    ROUND(dpd_61_90_pos / 10000000.0, 2)     AS dpd_61_90_aum_cr,
    ROUND(gnpa_90_plus_pos / 10000000.0, 2)  AS gnpa_aum_cr,
    ROUND(100.0 * gnpa_90_plus_pos / NULLIF(total_outstanding, 0), 2) AS gross_npa_pct,
    ROUND(100.0 * (dpd_1_30_pos + dpd_31_60_pos + dpd_61_90_pos + gnpa_90_plus_pos)
          / NULLIF(total_outstanding, 0), 2) AS par_1_plus_pct,
    gnpa_loan_count
FROM monthly_buckets
ORDER BY month_end;

-- Segment & Product Slippage Breakdown 
CREATE OR REPLACE VIEW vw_segment_slippage_summary AS
WITH latest_month AS (
    SELECT MAX(month_end) AS max_me FROM monthly_balance_snapshot
)
SELECT
    l.product,
    b.state,
    c.income_band,
    c.employment_type,
    CASE
        WHEN c.cibil_score IS NULL THEN 'Invalid/Missing'
        WHEN c.cibil_score < 650   THEN '<650 (Subprime)'
        WHEN c.cibil_score < 720   THEN '650-719 (Near-Prime)'
        ELSE '720+ (Prime)'
    END AS cibil_tier,
    COUNT(*) AS loan_count,
    ROUND(SUM(m.outstanding) / 100000.0, 2) AS total_pos_lakhs,
    ROUND(SUM(CASE WHEN m.bucket = '90+' THEN m.outstanding ELSE 0 END) / 100000.0, 2) AS gnpa_pos_lakhs,
    ROUND(100.0 * SUM(CASE WHEN m.bucket = '90+' THEN m.outstanding ELSE 0 END)
          / NULLIF(SUM(m.outstanding), 0), 2) AS gross_npa_pct
FROM monthly_balance_snapshot m
JOIN latest_month lm ON m.month_end = lm.max_me
JOIN loans l         ON m.loan_id = l.loan_id
JOIN branches b      ON l.branch_id = b.branch_id
JOIN customers c     ON l.customer_id = c.customer_id
GROUP BY 1, 2, 3, 4, 5;

--  DELINQUENCY ROLL-RATE MATRIX USING LAG() OVER month_end

CREATE OR REPLACE VIEW vw_roll_rate_matrix AS
WITH loan_transitions AS (
    SELECT
        loan_id,
        month_end,
        LAG(month_end)   OVER (PARTITION BY loan_id ORDER BY month_end) AS prev_month_end,
        LAG(bucket)      OVER (PARTITION BY loan_id ORDER BY month_end) AS prev_bucket,
        LAG(outstanding) OVER (PARTITION BY loan_id ORDER BY month_end) AS prev_outstanding,
        bucket AS curr_bucket,
        outstanding AS curr_outstanding
    FROM monthly_balance_snapshot
),
valid_consecutive_transitions AS (
    SELECT
        prev_bucket,
        curr_bucket,
        prev_outstanding,
        curr_outstanding
    FROM loan_transitions
    WHERE prev_bucket IS NOT NULL
      AND (EXTRACT(YEAR FROM month_end) * 12 + EXTRACT(MONTH FROM month_end))
        - (EXTRACT(YEAR FROM prev_month_end) * 12 + EXTRACT(MONTH FROM prev_month_end)) = 1
),
matrix_agg AS (
    SELECT
        prev_bucket AS from_bucket,
        COUNT(*) AS total_loans_in_from_bucket,
        SUM(prev_outstanding) AS total_from_pos,
        COUNT(CASE WHEN curr_bucket = 'Current' THEN 1 END) AS to_current_cnt,
        COUNT(CASE WHEN curr_bucket = '1-30'    THEN 1 END) AS to_1_30_cnt,
        COUNT(CASE WHEN curr_bucket = '31-60'   THEN 1 END) AS to_31_60_cnt,
        COUNT(CASE WHEN curr_bucket = '61-90'   THEN 1 END) AS to_61_90_cnt,
        COUNT(CASE WHEN curr_bucket = '90+'     THEN 1 END) AS to_90_plus_cnt
    FROM valid_consecutive_transitions
    GROUP BY prev_bucket
)
SELECT
    from_bucket,
    total_loans_in_from_bucket,
    ROUND(100.0 * to_current_cnt / total_loans_in_from_bucket, 2) AS pct_to_current,
    ROUND(100.0 * to_1_30_cnt    / total_loans_in_from_bucket, 2) AS pct_to_1_30,
    ROUND(100.0 * to_31_60_cnt   / total_loans_in_from_bucket, 2) AS pct_to_31_60,
    ROUND(100.0 * to_61_90_cnt   / total_loans_in_from_bucket, 2) AS pct_to_61_90,
    ROUND(100.0 * to_90_plus_cnt / total_loans_in_from_bucket, 2) AS pct_to_90_plus
FROM matrix_agg
ORDER BY CASE from_bucket
    WHEN 'Current' THEN 1
    WHEN '1-30'    THEN 2
    WHEN '31-60'   THEN 3
    WHEN '61-90'   THEN 4
    WHEN '90+'     THEN 5
END;





CREATE OR REPLACE VIEW vw_vintage_default_curves AS
WITH loan_cohorts AS (
    SELECT
        l.loan_id,
        l.product,
        l.branch_id,
        b.branch_name,
        b.state,
        DATE_TRUNC('month', l.disbursal_date)::DATE AS vintage_month,
        l.principal
    FROM loans l
    JOIN branches b ON l.branch_id = b.branch_id
),
cohort_totals AS (
    SELECT
        vintage_month,
        product,
        branch_id,
        branch_name,
        state,
        COUNT(*) AS cohort_loan_count,
        SUM(principal) AS cohort_disbursed_amt
    FROM loan_cohorts
    GROUP BY 1, 2, 3, 4, 5
),
first_default_mob AS (
    -- Identify the exact Month-on-Book (MOB) when a loan first hits 90+ DPD
    SELECT
        lc.loan_id,
        lc.vintage_month,
        lc.product,
        lc.branch_id,
        lc.principal,
        MIN(
            (EXTRACT(YEAR FROM m.month_end) - EXTRACT(YEAR FROM lc.vintage_month)) * 12 +
            (EXTRACT(MONTH FROM m.month_end) - EXTRACT(MONTH FROM lc.vintage_month))
        )::INT AS first_90_plus_mob
    FROM loan_cohorts lc
    JOIN monthly_balance_snapshot m ON lc.loan_id = m.loan_id
    WHERE m.dpd >= 90
    GROUP BY 1, 2, 3, 4, 5
),
mob_grid AS (
    SELECT DISTINCT
        ct.vintage_month,
        ct.product,
        ct.branch_id,
        ct.branch_name,
        ct.state,
        ct.cohort_loan_count,
        ct.cohort_disbursed_amt,
        gs.mob
    FROM cohort_totals ct
    CROSS JOIN GENERATE_SERIES(1, 32) AS gs(mob)
    WHERE (ct.vintage_month + (gs.mob || ' months')::INTERVAL) <= '2026-09-30'::DATE
),
incremental_defaults AS (
    SELECT
        vintage_month,
        product,
        branch_id,
        first_90_plus_mob AS mob,
        COUNT(*) AS newly_defaulted_loans,
        SUM(principal) AS newly_defaulted_principal
    FROM first_default_mob
    GROUP BY 1, 2, 3, 4
)
SELECT
    mg.vintage_month,
    mg.product,
    mg.branch_id,
    mg.branch_name,
    mg.state,
    mg.mob,
    mg.cohort_loan_count,
    ROUND(mg.cohort_disbursed_amt / 100000.0, 2) AS cohort_disbursed_lakhs,

    SUM(COALESCE(id.newly_defaulted_loans, 0)) OVER (
        PARTITION BY mg.vintage_month, mg.product, mg.branch_id
        ORDER BY mg.mob
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cum_defaulted_loans,
    ROUND(
        100.0 * SUM(COALESCE(id.newly_defaulted_principal, 0)) OVER (
            PARTITION BY mg.vintage_month, mg.product, mg.branch_id
            ORDER BY mg.mob
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) / NULLIF(mg.cohort_disbursed_amt, 0),
    2) AS cum_vintage_default_pct
FROM mob_grid mg
LEFT JOIN incremental_defaults id
       ON mg.vintage_month = id.vintage_month
      AND mg.product = id.product
      AND mg.branch_id = id.branch_id
      AND mg.mob = id.mob;


-- AGENT & BRANCH COLLECTION EFFICIENCY + RECURSIVE HIERARCHY CTE

CREATE OR REPLACE VIEW vw_agent_branch_collections AS
WITH recursive_org AS (

    SELECT
        a.agent_id,
        a.branch_id,
        a.join_date,
        a.manager_agent_id,
        1 AS hierarchy_level,
        a.agent_id::TEXT AS reporting_chain,
        a.agent_id AS top_manager_id
    FROM agents a
    WHERE a.manager_agent_id IS NULL

    UNION ALL

    SELECT
        sub.agent_id,
        sub.branch_id,
        sub.join_date,
        sub.manager_agent_id,
        ro.hierarchy_level + 1,
        ro.reporting_chain || ' -> ' || sub.agent_id,
        ro.top_manager_id
    FROM agents sub
    INNER JOIN recursive_org ro ON sub.manager_agent_id = ro.agent_id
),
valid_collections AS (
    SELECT
        p.agent_id,
        p.loan_id,
        p.emi_no,
        p.paid_date,
        p.amount AS collected_amount,
        e.due_date,
        e.emi_amount AS due_amount,
        (p.paid_date - e.due_date) AS days_to_collect
    FROM payments p
    JOIN emi_schedule e
      ON p.loan_id = e.loan_id AND p.emi_no = e.emi_no
    WHERE p.is_reversed = FALSE
      AND e.due_date <= '2026-09-30'::DATE
),
agent_metrics AS (
    SELECT
        ro.agent_id,
        ro.branch_id,
        b.branch_name,
        b.state,
        ro.manager_agent_id,
        ro.hierarchy_level,
        ro.reporting_chain,
        COUNT(vc.loan_id) AS emis_handled,
        SUM(vc.due_amount) AS total_due_assigned,
        SUM(vc.collected_amount) AS total_collected,
        ROUND(100.0 * SUM(vc.collected_amount) / NULLIF(SUM(vc.due_amount), 0), 2) AS collection_efficiency_pct,
        ROUND(AVG(vc.days_to_collect), 2) AS avg_days_to_collect,
        ROUND(100.0 * COUNT(CASE WHEN vc.days_to_collect <= 0 THEN 1 END)
              / NULLIF(COUNT(vc.loan_id), 0), 2) AS on_time_collection_pct
    FROM recursive_org ro
    JOIN branches b ON ro.branch_id = b.branch_id
    LEFT JOIN valid_collections vc ON ro.agent_id = vc.agent_id
    GROUP BY 1, 2, 3, 4, 5, 6, 7
)
SELECT
    *,
    DENSE_RANK() OVER (ORDER BY collection_efficiency_pct DESC NULLS LAST, avg_days_to_collect ASC NULLS LAST) AS overall_agent_rank,
    DENSE_RANK() OVER (PARTITION BY branch_id ORDER BY collection_efficiency_pct DESC NULLS LAST, avg_days_to_collect ASC NULLS LAST) AS branch_agent_rank
FROM agent_metrics;

CREATE OR REPLACE VIEW vw_branch_collection_ranking AS
WITH branch_due AS (
    SELECT
        l.branch_id,
        COUNT(*) AS total_emis_due,
        SUM(e.emi_amount) AS total_amount_due
    FROM emi_schedule e
    JOIN loans l ON e.loan_id = l.loan_id
    WHERE e.due_date <= '2026-09-30'::DATE
    GROUP BY l.branch_id
),
branch_paid AS (
    SELECT
        l.branch_id,
        SUM(p.amount) AS total_amount_collected,
        ROUND(AVG(p.paid_date - e.due_date), 2) AS avg_days_to_collect,
        ROUND(100.0 * COUNT(CASE WHEN p.paid_date <= e.due_date THEN 1 END)
              / NULLIF(COUNT(*), 0), 2) AS on_time_emi_pct
    FROM payments p
    JOIN loans l ON p.loan_id = l.loan_id
    JOIN emi_schedule e ON p.loan_id = e.loan_id AND p.emi_no = e.emi_no
    WHERE p.is_reversed = FALSE
      AND e.due_date <= '2026-09-30'::DATE
    GROUP BY l.branch_id
)
SELECT
    b.branch_id,
    b.branch_name,
    b.city,
    b.state,
    bd.total_emis_due,
    ROUND(bd.total_amount_due / 100000.0, 2) AS total_due_lakhs,
    ROUND(COALESCE(bp.total_amount_collected, 0) / 100000.0, 2) AS total_collected_lakhs,
    ROUND(100.0 * COALESCE(bp.total_amount_collected, 0) / NULLIF(bd.total_amount_due, 0), 2) AS collection_efficiency_pct,
    bp.avg_days_to_collect,
    bp.on_time_emi_pct,
    DENSE_RANK() OVER (
        ORDER BY (COALESCE(bp.total_amount_collected, 0) / NULLIF(bd.total_amount_due, 0)) DESC,
                 bp.avg_days_to_collect ASC
    ) AS branch_rank
FROM branches b
JOIN branch_due bd ON b.branch_id = bd.branch_id
LEFT JOIN branch_paid bp ON b.branch_id = bp.branch_id;

--  TRIGGER TO REJECT PAYMENTS LARGER THAN EMI DUE

CREATE OR REPLACE FUNCTION fn_validate_payment_amount()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_emi_due       NUMERIC(12,2);
    v_already_paid  NUMERIC(12,2);
BEGIN
    -- Ignore reversed rows if updating flag
    IF NEW.is_reversed = TRUE THEN
        RETURN NEW;
    END IF;

    SELECT emi_amount
      INTO v_emi_due
      FROM finease.emi_schedule
     WHERE loan_id = NEW.loan_id
       AND emi_no  = NEW.emi_no;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid payment: EMI schedule entry not found for loan_id=%, emi_no=%',
            NEW.loan_id, NEW.emi_no;
    END IF;

    SELECT COALESCE(SUM(amount), 0)
      INTO v_already_paid
      FROM finease.payments
     WHERE loan_id = NEW.loan_id
       AND emi_no  = NEW.emi_no
       AND is_reversed = FALSE
       AND payment_id <> NEW.payment_id;

    IF (v_already_paid + NEW.amount) > (v_emi_due + 0.01) THEN
        RAISE EXCEPTION 'Overpayment rejected for loan_id=%, emi_no=%: cumulative payment (%.2f) exceeds EMI due (%.2f)',
            NEW.loan_id, NEW.emi_no, (v_already_paid + NEW.amount), v_emi_due;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reject_overpayment
BEFORE INSERT OR UPDATE ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_validate_payment_amount();


--  AUTOMATED, RE-RUNNABLE MONTH-END CLOSE PROCEDURE WITH SAVEPOINT
CREATE TABLE IF NOT EXISTS pending_month_end_payments (
    batch_id         VARCHAR(20)   NOT NULL,
    payment_id       VARCHAR(15)   PRIMARY KEY,
    loan_id          VARCHAR(12)   NOT NULL,
    emi_no           INT           NOT NULL,
    paid_date        DATE          NOT NULL,
    amount           NUMERIC(12,2) NOT NULL,
    mode             VARCHAR(30)   NOT NULL,
    agent_id         VARCHAR(10)   NOT NULL,
    processed        BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE OR REPLACE PROCEDURE sp_month_end_close(
    p_month_end DATE,
    p_batch_id  VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec           RECORD;
    v_loans_count   INT := 0;
BEGIN
    IF p_month_end <> (DATE_TRUNC('month', p_month_end) + INTERVAL '1 month - 1 day')::DATE THEN
        RAISE EXCEPTION 'Parameter p_month_end (%) must be a valid calendar month-end date.', p_month_end;
    END IF;

    IF p_batch_id IS NOT NULL THEN
        FOR v_rec IN
            SELECT * FROM finease.pending_month_end_payments
             WHERE batch_id = p_batch_id AND processed = FALSE
        LOOP
            BEGIN
                SAVEPOINT sp_book_single_payment;

                INSERT INTO finease.payments (payment_id, loan_id, emi_no, paid_date, amount, mode, agent_id, is_reversed)
                VALUES (v_rec.payment_id, v_rec.loan_id, v_rec.emi_no, v_rec.paid_date, v_rec.amount, v_rec.mode, v_rec.agent_id, FALSE);

                UPDATE finease.pending_month_end_payments
                   SET processed = TRUE
                 WHERE payment_id = v_rec.payment_id;

            EXCEPTION WHEN OTHERS THEN
                ROLLBACK TO SAVEPOINT sp_book_single_payment;
                INSERT INTO finease.payments_quarantine (payment_id, loan_id, emi_no, paid_date, amount, mode, agent_id, reject_reason)
                VALUES (v_rec.payment_id, v_rec.loan_id, v_rec.emi_no, v_rec.paid_date, v_rec.amount, v_rec.mode, v_rec.agent_id, SQLERRM);
            END;
        END LOOP;
    END IF;

    SAVEPOINT sp_snapshot_rebuild;

    DELETE FROM finease.monthly_balance_snapshot
     WHERE month_end = p_month_end;

    WITH active_loans AS (
        SELECT loan_id, disbursal_date, principal, tenure_months
          FROM finease.loans
         WHERE disbursal_date <= p_month_end
    ),
    emi_status AS (
        SELECT
            al.loan_id,
            al.principal,
            e.emi_no,
            e.due_date,
            e.emi_amount,
            e.principal_part,
            COALESCE(SUM(p.amount), 0) AS paid_amt
        FROM active_loans al
        JOIN finease.emi_schedule e ON al.loan_id = e.loan_id
        LEFT JOIN finease.payments p
               ON e.loan_id = p.loan_id
              AND e.emi_no  = p.emi_no
              AND p.is_reversed = FALSE
              AND p.paid_date <= p_month_end
        GROUP BY al.loan_id, al.principal, e.emi_no, e.due_date, e.emi_amount, e.principal_part
    ),
    loan_summary AS (
        SELECT
            loan_id,
            SUM(CASE WHEN paid_amt < (emi_amount - 0.01) THEN principal_part ELSE 0 END) AS calc_outstanding,
            MIN(CASE WHEN due_date <= p_month_end AND paid_amt < (emi_amount - 0.01) THEN due_date END) AS earliest_unpaid_due
        FROM emi_status
        GROUP BY loan_id
    )
    INSERT INTO finease.monthly_balance_snapshot (month_end, loan_id, outstanding, dpd, bucket)
    SELECT
        p_month_end AS month_end,
        loan_id,
        calc_outstanding AS outstanding,
        COALESCE((p_month_end - earliest_unpaid_due), 0)::INT AS dpd,
        CASE
            WHEN earliest_unpaid_due IS NULL OR (p_month_end - earliest_unpaid_due) <= 0  THEN 'Current'
            WHEN (p_month_end - earliest_unpaid_due) BETWEEN 1 AND 30                    THEN '1-30'
            WHEN (p_month_end - earliest_unpaid_due) BETWEEN 31 AND 60                   THEN '31-60'
            WHEN (p_month_end - earliest_unpaid_due) BETWEEN 61 AND 90                   THEN '61-90'
            ELSE '90+'
        END AS bucket
    FROM loan_summary
    WHERE calc_outstanding > 0;

    GET DIAGNOSTICS v_loans_count = ROW_COUNT;

    INSERT INTO finease.month_end_close_log (target_month_end, status, loans_processed)
    VALUES (p_month_end, 'SUCCESS', v_loans_count);

EXCEPTION WHEN OTHERS THEN
    ROLLBACK TO SAVEPOINT sp_snapshot_rebuild;
    INSERT INTO finease.month_end_close_log (target_month_end, status, error_message)
    VALUES (p_month_end, 'FAILED', SQLERRM);
    RAISE;
END;
$$;


--  READ-ONLY ANALYST ROLE & VIEW-LEVEL SECURITY
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'finease_risk_analyst') THEN
        CREATE ROLE finease_risk_analyst NOLOGIN;
    END IF;
END
$$;

REVOKE ALL ON SCHEMA finease FROM PUBLIC, finease_risk_analyst;
REVOKE ALL ON ALL TABLES IN SCHEMA finease FROM PUBLIC, finease_risk_analyst;

GRANT USAGE ON SCHEMA finease TO finease_risk_analyst;
GRANT SELECT ON
    finease.vw_month_end_dpd_npa_trend,
    finease.vw_segment_slippage_summary,
    finease.vw_roll_rate_matrix,
    finease.vw_vintage_default_curves,
    finease.vw_agent_branch_collections,
    finease.vw_branch_collection_ranking
TO finease_risk_analyst;