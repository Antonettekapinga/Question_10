DROP VIEW IF EXISTS v_approved_applicants CASCADE;
DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a) Tables & Seed Data
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12, 2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5, 2) NOT NULL CHECK (average_mark >= 0 AND average_mark <= 100),
    submitted_on       DATE NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(15) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(15) NOT NULL,
    new_status     VARCHAR(15) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO students (student_number, full_name) VALUES
    ('ST2026-1', 'Muleba Mwashi'),
    ('ST2026-2', 'Beatrice Tembo'),
    ('ST2026-3', 'Davies Banda');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 2500.00, 82.00, '2026-11-10', 'PENDING'), -- qualifies
    (1, 18, 3000.00, 70.00, '2026-11-12', 'PENDING'), -- boundary qualifies
    (2, 26, 2000.00, 85.00, '2026-11-14', 'PENDING'), -- fails age
    (2, 21, 3500.00, 78.00, '2026-11-15', 'PENDING'), -- fails income
    (3, 22, 1500.00, 65.00, '2026-11-18', 'PENDING'), -- fails mark
    (3, 17, 1000.00, 90.00, '2026-11-20', 'PENDING'); -- fails age

-- (b) Function
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Inputs cannot be NULL';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly income cannot be negative, got %', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000)
       AND (p_mark >= 70);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age      INTEGER;
    v_income   NUMERIC(12, 2);
    v_mark     NUMERIC(5, 2);
    v_status   VARCHAR(15);
    v_eligible BOOLEAN;
    v_new_stat VARCHAR(15);
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % is already assessed with status %', p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);
    v_new_stat := CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END;

    UPDATE applications
    SET status = v_new_stat
    WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_log_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE OF status ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION fn_log_decision_audit();

-- (e) View
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index & EXPLAIN
CREATE INDEX idx_applications_status_submitted_on
ON applications (status, submitted_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT application_id, student_id, average_mark, submitted_on, status
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

-- (g) Batch Procedure & Schedule
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();
SELECT * FROM v_approved_applicants;
SELECT * FROM decision_audit;

