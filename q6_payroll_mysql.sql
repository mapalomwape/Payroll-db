-- Question 6: Monthly Payroll Processing (MySQL 8.0.16+)
-- CHECK constraints are only enforced from 8.0.16, so use 8.0.16 or later.

DROP DATABASE IF EXISTS payroll_db;
CREATE DATABASE payroll_db;
USE payroll_db;

-- =====================================================================
-- (a) DATABASE AND SEED DATA
-- =====================================================================
CREATE TABLE employees (
    employee_id  INT AUTO_INCREMENT PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary DECIMAL(10,2) NOT NULL,
    allowance    DECIMAL(10,2) NOT NULL DEFAULT 0,
    deduction    DECIMAL(10,2) NOT NULL DEFAULT 0,
    active       BOOLEAN       NOT NULL DEFAULT TRUE,
    CONSTRAINT ck_emp_basic     CHECK (basic_salary >= 0),
    CONSTRAINT ck_emp_allowance CHECK (allowance    >= 0),
    CONSTRAINT ck_emp_deduction CHECK (deduction    >= 0),
    CONSTRAINT ck_emp_active    CHECK (active IN (0,1))
) ENGINE=InnoDB;

CREATE TABLE payroll (
    payroll_id  INT AUTO_INCREMENT PRIMARY KEY,
    employee_id INT           NOT NULL,
    pay_month   DATE          NOT NULL,
    gross_pay   DECIMAL(10,2) NOT NULL,
    net_pay     DECIMAL(10,2) NOT NULL,
    CONSTRAINT fk_payroll_emp FOREIGN KEY (employee_id)
        REFERENCES employees(employee_id),
    CONSTRAINT uq_payroll_emp_month UNIQUE (employee_id, pay_month),
    CONSTRAINT ck_pay_month_first   CHECK (DAY(pay_month) = 1),
    CONSTRAINT ck_pay_gross         CHECK (gross_pay >= 0),
    CONSTRAINT ck_pay_net           CHECK (net_pay   >= 0)
) ENGINE=InnoDB;

CREATE TABLE salary_audit (
    audit_id    INT AUTO_INCREMENT PRIMARY KEY,
    employee_id INT           NOT NULL,
    old_salary  DECIMAL(10,2) NOT NULL,
    new_salary  DECIMAL(10,2) NOT NULL,
    changed_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_audit_emp FOREIGN KEY (employee_id)
        REFERENCES employees(employee_id)
) ENGINE=InnoDB;

-- Seed: 4 active, 1 inactive (Dina)
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
 ('Amina Yusuf', 5000.00,  800.00, 600.00, TRUE),
 ('Brian Okoro', 4200.00,  500.00, 450.00, TRUE),
 ('Chen Wei',    6000.00, 1000.00, 900.00, TRUE),
 ('Dina Musa',   3500.00,  300.00, 350.00, FALSE),
 ('Esa Bello',   3000.00,  200.00, 250.00, TRUE);

-- Two historical months. Dina (inactive) keeps her history.
-- Esa is deliberately missing from October to demonstrate "insert missing only".
INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay) VALUES
 (1,'2026-09-01',5800.00,5200.00),
 (2,'2026-09-01',4700.00,4250.00),
 (3,'2026-09-01',7000.00,6100.00),
 (4,'2026-09-01',3800.00,3450.00),
 (5,'2026-09-01',3200.00,2950.00),
 (1,'2026-10-01',5800.00,5200.00),
 (2,'2026-10-01',4700.00,4250.00),
 (3,'2026-10-01',7000.00,6100.00),
 (4,'2026-10-01',3800.00,3450.00);

-- =====================================================================
-- (b) FUNCTION fn_net_pay
-- =====================================================================
DELIMITER $$

CREATE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_net   DECIMAL(10,2);

    SELECT COUNT(*) INTO v_count
    FROM employees
    WHERE employee_id = p_employee_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unknown employee';
    END IF;

    SELECT basic_salary + allowance - deduction
      INTO v_net
    FROM employees
    WHERE employee_id = p_employee_id;

    IF v_net < 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Computed net pay is negative';
    END IF;

    RETURN v_net;
END$$

-- =====================================================================
-- (c) PROCEDURE pr_process_payroll
-- MySQL has no "FOR rec IN query LOOP" (that is PL/pgSQL / Oracle).
-- The MySQL equivalent is a cursor over the query driven by a LOOP.
-- =====================================================================
CREATE PROCEDURE pr_process_payroll(IN p_month DATE)
BEGIN
    DECLARE v_done  BOOLEAN DEFAULT FALSE;
    DECLARE v_id    INT;
    DECLARE v_gross DECIMAL(10,2);

    DECLARE cur_emp CURSOR FOR
        SELECT employee_id, basic_salary + allowance
        FROM employees
        WHERE active = TRUE
        ORDER BY employee_id;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    -- Any error (e.g. from fn_net_pay) undoes everything and is re-raised
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_month IS NULL OR DAY(p_month) <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'p_month must be the first day of a month';
    END IF;

    START TRANSACTION;

    OPEN cur_emp;
    read_loop: LOOP
        FETCH cur_emp INTO v_id, v_gross;
        IF v_done THEN
            LEAVE read_loop;
        END IF;

        -- Insert only if missing; an existing row is left untouched
        IF NOT EXISTS (SELECT 1 FROM payroll
                       WHERE employee_id = v_id AND pay_month = p_month) THEN
            INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
            VALUES (v_id, p_month, v_gross, fn_net_pay(v_id));
        END IF;
    END LOOP;
    CLOSE cur_emp;

    COMMIT;
END$$

-- =====================================================================
-- (d) TRIGGER: audit real basic_salary changes only
-- <=> is NULL-safe equality, so only genuine changes are logged.
-- =====================================================================
CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
BEGIN
    IF NOT (OLD.basic_salary <=> NEW.basic_salary) THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, NOW());
    END IF;
END$$

DELIMITER ;

-- =====================================================================
-- (e) VIEW: no filter on employees.active, so history of employees
-- who later became inactive is still shown.
-- =====================================================================
CREATE VIEW v_payroll_report AS
SELECT e.employee_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

-- =====================================================================
-- (f) INDEX
-- uq_payroll_emp_month is (employee_id, pay_month). The leftmost column
-- is employee_id, so it cannot be used efficiently for
-- WHERE pay_month = ... across all employees. A separate index led by
-- pay_month fixes this without duplicating the unique index.
-- (InnoDB secondary indexes also carry the primary key payroll_id.)
-- =====================================================================
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

-- Evidence:
EXPLAIN SELECT * FROM v_payroll_report WHERE pay_month = '2026-10-01';

-- =====================================================================
-- (g) SCHEDULED JOB (MySQL Event Scheduler)
-- =====================================================================
SET GLOBAL event_scheduler = ON;   -- needs SUPER / SYSTEM_VARIABLES_ADMIN

-- MySQL has no built-in run history table, so create one
CREATE TABLE payroll_job_log (
    log_id   INT AUTO_INCREMENT PRIMARY KEY,
    job_name VARCHAR(64)  NOT NULL,
    run_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    p_month  DATE         NULL,
    status   VARCHAR(10)  NOT NULL,
    message  VARCHAR(255) NULL
) ENGINE=InnoDB;

DELIMITER $$

CREATE EVENT ev_monthly_payroll
ON SCHEDULE EVERY 1 MONTH
STARTS '2026-12-01 02:00:00'
DO
BEGIN
    DECLARE v_month DATE;
    DECLARE v_msg   VARCHAR(255);

    SET v_month = DATE_SUB(DATE_FORMAT(CURDATE(), '%Y-%m-01'), INTERVAL 1 MONTH);

    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
            INSERT INTO payroll_job_log (job_name, p_month, status, message)
            VALUES ('ev_monthly_payroll', v_month, 'FAILED', v_msg);
        END;

        CALL pr_process_payroll(v_month);

        INSERT INTO payroll_job_log (job_name, p_month, status, message)
        VALUES ('ev_monthly_payroll', v_month, 'SUCCESS', NULL);
    END;
END$$

DELIMITER ;

-- Inspect the job (definition, schedule, status, last run)
SHOW EVENTS FROM payroll_db;

SELECT event_name, status, event_type, interval_value, interval_field,
       starts, last_executed, event_definition
FROM information_schema.EVENTS
WHERE event_schema = 'payroll_db' AND event_name = 'ev_monthly_payroll';

SHOW CREATE EVENT ev_monthly_payroll;

-- Run history
SELECT * FROM payroll_job_log ORDER BY run_at DESC;

-- =====================================================================
-- TEST SCRIPT
-- =====================================================================
-- 1. Function
SELECT fn_net_pay(1);            -- 5200.00
-- SELECT fn_net_pay(999);       -- ERROR: Unknown employee

-- 2. Procedure: re-run October. Only Esa (missing) is inserted.
CALL pr_process_payroll('2026-10-01');
SELECT * FROM payroll WHERE pay_month = '2026-10-01';

-- Run again: nothing changes (idempotent)
CALL pr_process_payroll('2026-10-01');

-- Invalid month
-- CALL pr_process_payroll('2026-10-15');   -- ERROR

-- New month: only the 4 active employees are inserted (Dina excluded)
CALL pr_process_payroll('2026-11-01');

-- Whole-call failure: make Esa's net negative, nothing from Dec is kept
UPDATE employees SET deduction = 9999 WHERE employee_id = 5;
-- CALL pr_process_payroll('2026-12-01');   -- ERROR; rollback; no Dec rows
SELECT COUNT(*) FROM payroll WHERE pay_month = '2026-12-01';   -- 0
UPDATE employees SET deduction = 250 WHERE employee_id = 5;

-- 3. Trigger
UPDATE employees SET basic_salary = 5500 WHERE employee_id = 1;  -- logged
UPDATE employees SET basic_salary = 5500 WHERE employee_id = 1;  -- no change, not logged
UPDATE employees SET full_name = 'Amina Y.' WHERE employee_id = 1; -- not logged
SELECT * FROM salary_audit;

-- 4. View includes inactive Dina's history
SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;
