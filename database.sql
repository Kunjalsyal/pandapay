-- Digital Wallet System
-- Course: UCS310 - Database Management Systems
-- Thapar Institute of Engineering and Technology, Patiala
-- Authors: Barleen Kaur, Ayush Vaibhav, Kunjal Syal
-- Session: Jan-May 2026

-- Run this entire file in Oracle SQL Developer (F5)
-- Target: Oracle Database XE, connected as SYSTEM user


-- ============================================================
-- CLEANUP: drop everything in reverse dependency order
-- ============================================================

BEGIN
  FOR t IN (
    SELECT table_name FROM user_tables
    WHERE table_name IN (
      'AUDIT_LOG','REFUND_REQUEST','TRANSACTION_HISTORY',
      'SPENDING_LIMIT','WALLET','USERS','ROLES'
    )
  ) LOOP
    EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
  END LOOP;
END;
/

BEGIN
  FOR s IN (
    SELECT sequence_name FROM user_sequences
    WHERE sequence_name IN (
      'SEQ_USER','SEQ_WALLET','SEQ_TXN','SEQ_REFUND','SEQ_AUDIT'
    )
  ) LOOP
    EXECUTE IMMEDIATE 'DROP SEQUENCE ' || s.sequence_name;
  END LOOP;
END;
/


-- ============================================================
-- SEQUENCES
-- ============================================================

CREATE SEQUENCE SEQ_USER   START WITH 1001 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SEQ_WALLET START WITH 1    INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SEQ_TXN    START WITH 1    INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SEQ_REFUND START WITH 1    INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SEQ_AUDIT  START WITH 1    INCREMENT BY 1 NOCACHE NOCYCLE;


-- ============================================================
-- TABLE: ROLES
-- Stores the three permission levels in the system.
-- Normalized separately so role names are never duplicated.
-- ============================================================

CREATE TABLE ROLES (
  role_id   NUMBER        PRIMARY KEY,
  role_name VARCHAR2(20)  NOT NULL UNIQUE,
  CONSTRAINT chk_role_name CHECK (role_name IN ('USER', 'ADMIN', 'AUDITOR'))
);

INSERT INTO ROLES VALUES (1, 'USER');
INSERT INTO ROLES VALUES (2, 'ADMIN');
INSERT INTO ROLES VALUES (3, 'AUDITOR');
COMMIT;


-- ============================================================
-- TABLE: USERS
-- One row per registered user. Role is a foreign key into ROLES.
-- Email uniqueness enforced by constraint, not application code.
-- ============================================================

CREATE TABLE USERS (
  user_id       NUMBER         DEFAULT SEQ_USER.NEXTVAL PRIMARY KEY,
  full_name     VARCHAR2(100)  NOT NULL,
  email         VARCHAR2(150)  NOT NULL UNIQUE,
  phone         VARCHAR2(15),
  password_hash VARCHAR2(256)  NOT NULL,
  role_id       NUMBER         NOT NULL,
  is_active     CHAR(1)        DEFAULT 'Y' NOT NULL,
  created_at    TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT fk_user_role   FOREIGN KEY (role_id)  REFERENCES ROLES(role_id),
  CONSTRAINT chk_user_active CHECK (is_active IN ('Y','N'))
);


-- ============================================================
-- TABLE: WALLET
-- One wallet per user (enforced by UNIQUE on user_id).
-- Balance cannot go below zero - enforced by CHECK constraint
-- and additionally by a trigger below.
-- Status transitions: ACTIVE <-> FROZEN only via admin action.
-- ============================================================

CREATE TABLE WALLET (
  wallet_id    NUMBER        DEFAULT SEQ_WALLET.NEXTVAL PRIMARY KEY,
  user_id      NUMBER        NOT NULL UNIQUE,
  balance      NUMBER(12, 2) DEFAULT 0 NOT NULL,
  status       VARCHAR2(10)  DEFAULT 'ACTIVE' NOT NULL,
  currency     VARCHAR2(3)   DEFAULT 'INR' NOT NULL,
  freeze_note  VARCHAR2(300),
  created_at   TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  updated_at   TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT fk_wallet_user   FOREIGN KEY (user_id) REFERENCES USERS(user_id),
  CONSTRAINT chk_balance      CHECK (balance >= 0),
  CONSTRAINT chk_wallet_status CHECK (status IN ('ACTIVE', 'FROZEN')),
  CONSTRAINT chk_currency     CHECK (currency IN ('INR', 'USD', 'EUR'))
);


-- ============================================================
-- TABLE: SPENDING_LIMIT
-- Per-wallet configurable limits. Kept in a separate table
-- (not in WALLET) to satisfy 3NF - limits are not functionally
-- dependent on wallet balance or status, they are a separate
-- entity that an admin can update independently.
-- ============================================================

CREATE TABLE SPENDING_LIMIT (
  wallet_id      NUMBER        PRIMARY KEY,
  daily_limit    NUMBER(12, 2) DEFAULT 10000  NOT NULL,
  monthly_limit  NUMBER(12, 2) DEFAULT 100000 NOT NULL,
  per_txn_limit  NUMBER(12, 2) DEFAULT 5000   NOT NULL,
  CONSTRAINT fk_limit_wallet  FOREIGN KEY (wallet_id) REFERENCES WALLET(wallet_id),
  CONSTRAINT chk_daily_pos    CHECK (daily_limit   > 0),
  CONSTRAINT chk_monthly_pos  CHECK (monthly_limit > 0),
  CONSTRAINT chk_per_txn_pos  CHECK (per_txn_limit > 0)
);


-- ============================================================
-- TABLE: TRANSACTION_HISTORY
-- Every debit, credit, transfer, and refund creates one row here.
-- balance_before and balance_after are stored for audit purposes -
-- they are intentionally redundant with wallet.balance because
-- wallet.balance reflects the current state, not history.
-- status follows a defined state machine enforced by a trigger.
-- ============================================================

CREATE TABLE TRANSACTION_HISTORY (
  txn_id         NUMBER        DEFAULT SEQ_TXN.NEXTVAL PRIMARY KEY,
  wallet_id      NUMBER        NOT NULL,
  txn_type       VARCHAR2(10)  NOT NULL,
  amount         NUMBER(12, 2) NOT NULL,
  status         VARCHAR2(15)  DEFAULT 'PENDING' NOT NULL,
  description    VARCHAR2(300),
  reference_no   VARCHAR2(50)  UNIQUE,
  recipient_id   NUMBER,
  initiated_by   NUMBER        NOT NULL,
  balance_before NUMBER(12, 2),
  balance_after  NUMBER(12, 2),
  created_at     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  updated_at     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT fk_txn_wallet    FOREIGN KEY (wallet_id)   REFERENCES WALLET(wallet_id),
  CONSTRAINT fk_txn_user      FOREIGN KEY (initiated_by) REFERENCES USERS(user_id),
  CONSTRAINT chk_txn_type     CHECK (txn_type IN ('CREDIT','DEBIT','TRANSFER','REFUND')),
  CONSTRAINT chk_txn_status   CHECK (status IN ('PENDING','SUCCESS','FAILED','REVERSED','ROLLED_BACK')),
  CONSTRAINT chk_txn_amount   CHECK (amount > 0)
);


-- ============================================================
-- TABLE: REFUND_REQUEST
-- Raised by a USER, approved or rejected by an ADMIN.
-- Kept separate from TRANSACTION_HISTORY because a refund
-- request has its own lifecycle and approval fields that have
-- nothing to do with the original transaction attributes.
-- ============================================================

CREATE TABLE REFUND_REQUEST (
  refund_id       NUMBER        DEFAULT SEQ_REFUND.NEXTVAL PRIMARY KEY,
  txn_id          NUMBER        NOT NULL,
  requested_by    NUMBER        NOT NULL,
  reason          VARCHAR2(500) NOT NULL,
  approval_status VARCHAR2(10)  DEFAULT 'PENDING' NOT NULL,
  approved_by     NUMBER,
  admin_note      VARCHAR2(500),
  requested_at    TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  resolved_at     TIMESTAMP,
  CONSTRAINT fk_refund_txn      FOREIGN KEY (txn_id)       REFERENCES TRANSACTION_HISTORY(txn_id),
  CONSTRAINT fk_refund_user     FOREIGN KEY (requested_by) REFERENCES USERS(user_id),
  CONSTRAINT fk_refund_admin    FOREIGN KEY (approved_by)  REFERENCES USERS(user_id),
  CONSTRAINT chk_refund_status  CHECK (approval_status IN ('PENDING','APPROVED','REJECTED'))
);


-- ============================================================
-- TABLE: AUDIT_LOG
-- Append-only log of every state change in the system.
-- A trigger below makes UPDATE and DELETE on this table
-- raise an application error, enforcing immutability.
-- Uses PRAGMA AUTONOMOUS_TRANSACTION in write procedure
-- so the log entry commits even if the calling transaction rolls back.
-- ============================================================

CREATE TABLE AUDIT_LOG (
  audit_id     NUMBER        DEFAULT SEQ_AUDIT.NEXTVAL PRIMARY KEY,
  performed_by NUMBER,
  action_type  VARCHAR2(40)  NOT NULL,
  table_name   VARCHAR2(50)  NOT NULL,
  record_id    NUMBER,
  old_value    VARCHAR2(4000),
  new_value    VARCHAR2(4000),
  created_at   TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT fk_audit_user FOREIGN KEY (performed_by) REFERENCES USERS(user_id)
);

-- Indexes on audit_log for the queries the auditor role will run most often
CREATE INDEX idx_audit_table_date  ON AUDIT_LOG(table_name, created_at);
CREATE INDEX idx_audit_performer   ON AUDIT_LOG(performed_by, created_at);
CREATE INDEX idx_txn_wallet_date   ON TRANSACTION_HISTORY(wallet_id, created_at);
CREATE INDEX idx_txn_status        ON TRANSACTION_HISTORY(status);


-- ============================================================
-- VIEWS
-- Encapsulate joins so the application layer does not need to
-- know the internal schema structure.
-- ============================================================

-- Full wallet summary used by the dashboard
CREATE OR REPLACE VIEW VW_WALLET_SUMMARY AS
SELECT
  u.user_id,
  u.full_name,
  u.email,
  w.wallet_id,
  w.balance,
  w.currency,
  w.status,
  w.freeze_note,
  sl.daily_limit,
  sl.monthly_limit,
  sl.per_txn_limit
FROM USERS u
JOIN WALLET          w  ON u.user_id   = w.user_id
LEFT JOIN SPENDING_LIMIT sl ON w.wallet_id = sl.wallet_id;


-- Audit log with the name of the person who performed the action
CREATE OR REPLACE VIEW VW_AUDIT_DETAIL AS
SELECT
  a.audit_id,
  NVL(u.full_name, 'System') AS performed_by_name,
  a.action_type,
  a.table_name,
  a.record_id,
  a.old_value,
  a.new_value,
  TO_CHAR(a.created_at, 'DD Mon YYYY, HH24:MI:SS') AS created_at
FROM AUDIT_LOG a
LEFT JOIN USERS u ON a.performed_by = u.user_id;


-- Transaction history with initiator name - used by the transactions page
CREATE OR REPLACE VIEW VW_TXN_HISTORY AS
SELECT
  t.txn_id,
  t.wallet_id,
  t.txn_type,
  t.amount,
  t.status,
  t.description,
  t.reference_no,
  t.balance_before,
  t.balance_after,
  t.recipient_id,
  TO_CHAR(t.created_at, 'DD Mon, HH24:MI') AS created_at,
  u.full_name AS initiated_by_name
FROM TRANSACTION_HISTORY t
JOIN USERS u ON t.initiated_by = u.user_id;


-- ============================================================
-- PL/SQL PACKAGE: wallet_ops
-- Groups all business logic in one place.
-- The package spec defines the public interface.
-- ============================================================

CREATE OR REPLACE PACKAGE wallet_ops AS

  -- Writes one row to AUDIT_LOG using an autonomous transaction.
  -- Called internally and can survive a rollback in the calling block.
  PROCEDURE write_audit(
    p_performed_by IN NUMBER,
    p_action       IN VARCHAR2,
    p_table        IN VARCHAR2,
    p_record_id    IN NUMBER,
    p_old          IN VARCHAR2 DEFAULT NULL,
    p_new          IN VARCHAR2 DEFAULT NULL
  );

  -- Returns the total amount debited or transferred from a wallet today.
  FUNCTION daily_spent(p_wallet_id IN NUMBER) RETURN NUMBER;

  -- Returns the total debited or transferred this calendar month.
  FUNCTION monthly_spent(p_wallet_id IN NUMBER) RETURN NUMBER;

  -- Counts how many of the most recent transactions for a wallet
  -- are consecutive failures. Used for the auto-freeze trigger.
  FUNCTION consecutive_failures(p_wallet_id IN NUMBER) RETURN NUMBER;

  -- Generates a unique reference number for each transaction.
  FUNCTION new_reference RETURN VARCHAR2;

  -- Core transaction handler. Validates limits, updates balances,
  -- inserts the transaction record, and calls write_audit.
  PROCEDURE do_transaction(
    p_wallet_id    IN  NUMBER,
    p_type         IN  VARCHAR2,
    p_amount       IN  NUMBER,
    p_description  IN  VARCHAR2,
    p_initiated_by IN  NUMBER,
    p_recipient_id IN  NUMBER   DEFAULT NULL,
    p_txn_id       OUT NUMBER,
    p_status       OUT VARCHAR2,
    p_message      OUT VARCHAR2
  );

  -- Admin: approve or reject a refund request.
  -- Uses a SAVEPOINT so partial work can be rolled back on error.
  PROCEDURE handle_refund(
    p_refund_id IN  NUMBER,
    p_admin_id  IN  NUMBER,
    p_decision  IN  VARCHAR2,
    p_note      IN  VARCHAR2 DEFAULT NULL,
    p_status    OUT VARCHAR2,
    p_message   OUT VARCHAR2
  );

  -- Admin: freeze or unfreeze a wallet.
  PROCEDURE set_wallet_status(
    p_wallet_id IN  NUMBER,
    p_admin_id  IN  NUMBER,
    p_action    IN  VARCHAR2,
    p_reason    IN  VARCHAR2 DEFAULT NULL,
    p_status    OUT VARCHAR2,
    p_message   OUT VARCHAR2
  );

END wallet_ops;
/


-- ============================================================
-- PL/SQL PACKAGE BODY: wallet_ops
-- ============================================================

CREATE OR REPLACE PACKAGE BODY wallet_ops AS

  PROCEDURE write_audit(
    p_performed_by IN NUMBER,
    p_action       IN VARCHAR2,
    p_table        IN VARCHAR2,
    p_record_id    IN NUMBER,
    p_old          IN VARCHAR2 DEFAULT NULL,
    p_new          IN VARCHAR2 DEFAULT NULL
  ) IS
    -- Autonomous transaction: this INSERT commits on its own
    -- regardless of what the calling transaction does.
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO AUDIT_LOG(performed_by, action_type, table_name,
                          record_id, old_value, new_value)
    VALUES (p_performed_by, p_action, p_table,
            p_record_id, p_old, p_new);
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN NULL;  -- audit must never crash the main operation
  END write_audit;


  FUNCTION daily_spent(p_wallet_id IN NUMBER) RETURN NUMBER IS
    v_total NUMBER := 0;
  BEGIN
    SELECT NVL(SUM(amount), 0)
      INTO v_total
      FROM TRANSACTION_HISTORY
     WHERE wallet_id = p_wallet_id
       AND txn_type  IN ('DEBIT', 'TRANSFER')
       AND status    = 'SUCCESS'
       AND TRUNC(created_at) = TRUNC(SYSDATE);
    RETURN v_total;
  END daily_spent;


  FUNCTION monthly_spent(p_wallet_id IN NUMBER) RETURN NUMBER IS
    v_total NUMBER := 0;
  BEGIN
    SELECT NVL(SUM(amount), 0)
      INTO v_total
      FROM TRANSACTION_HISTORY
     WHERE wallet_id = p_wallet_id
       AND txn_type  IN ('DEBIT', 'TRANSFER')
       AND status    = 'SUCCESS'
       AND TRUNC(created_at, 'MM') = TRUNC(SYSDATE, 'MM');
    RETURN v_total;
  END monthly_spent;


  FUNCTION consecutive_failures(p_wallet_id IN NUMBER) RETURN NUMBER IS
    v_count NUMBER := 0;
    CURSOR c_recent IS
      SELECT status FROM TRANSACTION_HISTORY
       WHERE wallet_id = p_wallet_id
       ORDER BY created_at DESC
      FETCH FIRST 5 ROWS ONLY;
  BEGIN
    FOR r IN c_recent LOOP
      EXIT WHEN r.status != 'FAILED';
      v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
  END consecutive_failures;


  FUNCTION new_reference RETURN VARCHAR2 IS
  BEGIN
    RETURN 'TXN' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHHMMSSFF3');
  END new_reference;


  PROCEDURE do_transaction(
    p_wallet_id    IN  NUMBER,
    p_type         IN  VARCHAR2,
    p_amount       IN  NUMBER,
    p_description  IN  VARCHAR2,
    p_initiated_by IN  NUMBER,
    p_recipient_id IN  NUMBER   DEFAULT NULL,
    p_txn_id       OUT NUMBER,
    p_status       OUT VARCHAR2,
    p_message      OUT VARCHAR2
  ) IS
    v_wallet   WALLET%ROWTYPE;
    v_limits   SPENDING_LIMIT%ROWTYPE;
    v_new_bal  NUMBER;
    v_ref      VARCHAR2(50);
    v_txn_id   NUMBER;

    e_frozen        EXCEPTION;
    e_no_funds      EXCEPTION;
    e_over_daily    EXCEPTION;
    e_over_monthly  EXCEPTION;
    e_over_pertxn   EXCEPTION;
  BEGIN
    -- Lock the wallet row so concurrent requests cannot race on the balance
    SELECT * INTO v_wallet FROM WALLET
     WHERE wallet_id = p_wallet_id FOR UPDATE;

    IF v_wallet.status != 'ACTIVE' THEN
      RAISE e_frozen;
    END IF;

    -- Load spending limits; fall back to conservative defaults if not set
    BEGIN
      SELECT * INTO v_limits FROM SPENDING_LIMIT WHERE wallet_id = p_wallet_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        v_limits.daily_limit   := 10000;
        v_limits.monthly_limit := 100000;
        v_limits.per_txn_limit := 5000;
    END;

    -- Spending validations only apply to outgoing transactions
    IF p_type IN ('DEBIT', 'TRANSFER') THEN
      IF v_wallet.balance < p_amount THEN
        RAISE e_no_funds;
      END IF;
      IF p_amount > v_limits.per_txn_limit THEN
        RAISE e_over_pertxn;
      END IF;
      IF daily_spent(p_wallet_id) + p_amount > v_limits.daily_limit THEN
        RAISE e_over_daily;
      END IF;
      IF monthly_spent(p_wallet_id) + p_amount > v_limits.monthly_limit THEN
        RAISE e_over_monthly;
      END IF;
    END IF;

    v_new_bal := CASE
      WHEN p_type IN ('CREDIT', 'REFUND') THEN v_wallet.balance + p_amount
      ELSE v_wallet.balance - p_amount
    END;

    v_ref    := new_reference;
    v_txn_id := SEQ_TXN.NEXTVAL;

    INSERT INTO TRANSACTION_HISTORY(
      txn_id, wallet_id, txn_type, amount, status,
      description, reference_no, recipient_id, initiated_by,
      balance_before, balance_after
    ) VALUES (
      v_txn_id, p_wallet_id, p_type, p_amount, 'SUCCESS',
      p_description, v_ref, p_recipient_id, p_initiated_by,
      v_wallet.balance, v_new_bal
    );

    UPDATE WALLET
       SET balance    = v_new_bal,
           updated_at = SYSTIMESTAMP
     WHERE wallet_id  = p_wallet_id;

    -- For transfers, credit the recipient wallet in the same transaction
    IF p_type = 'TRANSFER' AND p_recipient_id IS NOT NULL THEN
      UPDATE WALLET
         SET balance    = balance + p_amount,
             updated_at = SYSTIMESTAMP
       WHERE wallet_id  = p_recipient_id;

      INSERT INTO TRANSACTION_HISTORY(
        txn_id, wallet_id, txn_type, amount, status,
        description, reference_no, initiated_by
      ) VALUES (
        SEQ_TXN.NEXTVAL, p_recipient_id, 'CREDIT', p_amount, 'SUCCESS',
        'Transfer received (ref: ' || v_ref || ')',
        v_ref || '-CR', p_initiated_by
      );
    END IF;

    COMMIT;

    write_audit(
      p_initiated_by, 'TXN_' || p_type, 'TRANSACTION_HISTORY', v_txn_id,
      'balance=' || v_wallet.balance,
      'balance=' || v_new_bal
    );

    p_txn_id  := v_txn_id;
    p_status  := 'SUCCESS';
    p_message := 'Transaction complete. Ref: ' || v_ref;

  EXCEPTION
    WHEN e_frozen THEN
      ROLLBACK;
      p_txn_id  := NULL;
      p_status  := 'FAILED';
      p_message := 'Wallet is ' || v_wallet.status || '. Contact support.';

    WHEN e_no_funds THEN
      ROLLBACK;
      p_txn_id  := NULL;
      p_status  := 'FAILED';
      p_message := 'Insufficient balance.';

    WHEN e_over_pertxn THEN
      ROLLBACK;
      p_txn_id  := NULL;
      p_status  := 'FAILED';
      p_message := 'Exceeds per-transaction limit of ' || v_limits.per_txn_limit;

    WHEN e_over_daily THEN
      ROLLBACK;
      p_txn_id  := NULL;
      p_status  := 'FAILED';
      p_message := 'Daily spending limit of ' || v_limits.daily_limit || ' would be exceeded.';

    WHEN e_over_monthly THEN
      ROLLBACK;
      p_txn_id  := NULL;
      p_status  := 'FAILED';
      p_message := 'Monthly spending limit would be exceeded.';

    WHEN OTHERS THEN
      ROLLBACK;
      p_txn_id  := NULL;
      p_status  := 'ERROR';
      p_message := 'Unexpected error: ' || SQLERRM;
  END do_transaction;


  PROCEDURE handle_refund(
    p_refund_id IN  NUMBER,
    p_admin_id  IN  NUMBER,
    p_decision  IN  VARCHAR2,
    p_note      IN  VARCHAR2 DEFAULT NULL,
    p_status    OUT VARCHAR2,
    p_message   OUT VARCHAR2
  ) IS
    v_refund REFUND_REQUEST%ROWTYPE;
    v_txn    TRANSACTION_HISTORY%ROWTYPE;
    v_role   VARCHAR2(20);
  BEGIN
    SAVEPOINT sp_refund;

    -- Verify the caller is actually an admin
    SELECT r.role_name INTO v_role
      FROM USERS u JOIN ROLES r ON u.role_id = r.role_id
     WHERE u.user_id = p_admin_id AND u.is_active = 'Y';

    IF v_role != 'ADMIN' THEN
      p_status  := 'ERROR';
      p_message := 'Only admins can process refund requests.';
      RETURN;
    END IF;

    SELECT * INTO v_refund FROM REFUND_REQUEST
     WHERE refund_id = p_refund_id FOR UPDATE;

    IF v_refund.approval_status != 'PENDING' THEN
      p_status  := 'ERROR';
      p_message := 'Refund already resolved: ' || v_refund.approval_status;
      RETURN;
    END IF;

    SELECT * INTO v_txn FROM TRANSACTION_HISTORY
     WHERE txn_id = v_refund.txn_id;

    UPDATE REFUND_REQUEST
       SET approval_status = p_decision,
           approved_by     = p_admin_id,
           admin_note      = p_note,
           resolved_at     = SYSTIMESTAMP
     WHERE refund_id       = p_refund_id;

    IF p_decision = 'APPROVED' THEN
      UPDATE WALLET
         SET balance    = balance + v_txn.amount,
             updated_at = SYSTIMESTAMP
       WHERE wallet_id  = v_txn.wallet_id;

      UPDATE TRANSACTION_HISTORY
         SET status     = 'REVERSED',
             updated_at = SYSTIMESTAMP
       WHERE txn_id     = v_txn.txn_id;

      INSERT INTO TRANSACTION_HISTORY(
        txn_id, wallet_id, txn_type, amount, status,
        description, initiated_by
      ) VALUES (
        SEQ_TXN.NEXTVAL, v_txn.wallet_id, 'REFUND', v_txn.amount, 'SUCCESS',
        'Refund for txn #' || v_txn.txn_id, p_admin_id
      );

      p_message := 'Refund approved. ' || v_txn.amount || ' credited back.';
    ELSE
      p_message := 'Refund request rejected.';
    END IF;

    COMMIT;

    write_audit(
      p_admin_id, 'REFUND_' || p_decision, 'REFUND_REQUEST',
      p_refund_id, 'PENDING', p_decision
    );

    p_status := 'SUCCESS';

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      ROLLBACK TO sp_refund;
      p_status  := 'ERROR';
      p_message := 'Refund or admin record not found.';
    WHEN OTHERS THEN
      ROLLBACK TO sp_refund;
      p_status  := 'ERROR';
      p_message := SQLERRM;
  END handle_refund;


  PROCEDURE set_wallet_status(
    p_wallet_id IN  NUMBER,
    p_admin_id  IN  NUMBER,
    p_action    IN  VARCHAR2,
    p_reason    IN  VARCHAR2 DEFAULT NULL,
    p_status    OUT VARCHAR2,
    p_message   OUT VARCHAR2
  ) IS
    v_old_status VARCHAR2(10);
    v_new_status VARCHAR2(10);
  BEGIN
    SELECT status INTO v_old_status FROM WALLET
     WHERE wallet_id = p_wallet_id FOR UPDATE;

    v_new_status := CASE p_action WHEN 'FREEZE' THEN 'FROZEN' ELSE 'ACTIVE' END;

    UPDATE WALLET
       SET status       = v_new_status,
           freeze_note  = CASE p_action WHEN 'FREEZE' THEN p_reason ELSE NULL END,
           updated_at   = SYSTIMESTAMP
     WHERE wallet_id    = p_wallet_id;

    COMMIT;

    write_audit(
      p_admin_id, 'WALLET_' || p_action, 'WALLET',
      p_wallet_id, v_old_status, v_new_status
    );

    p_status  := 'SUCCESS';
    p_message := 'Wallet status changed to ' || v_new_status;

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status  := 'ERROR';
      p_message := SQLERRM;
  END set_wallet_status;

END wallet_ops;
/


-- ============================================================
-- TRIGGERS
-- ============================================================

-- Prevents anyone from modifying or deleting audit log rows.
-- Runs before every UPDATE or DELETE on AUDIT_LOG.
CREATE OR REPLACE TRIGGER trg_audit_immutable
  BEFORE UPDATE OR DELETE ON AUDIT_LOG
  FOR EACH ROW
BEGIN
  RAISE_APPLICATION_ERROR(
    -20001,
    'Audit log is append-only. Modification of existing records is not permitted.'
  );
END;
/


-- Keeps wallet.updated_at current without relying on application code.
CREATE OR REPLACE TRIGGER trg_wallet_updated_at
  BEFORE UPDATE ON WALLET
  FOR EACH ROW
BEGIN
  :NEW.updated_at := SYSTIMESTAMP;
END;
/


-- Prevents the wallet balance from going negative at the database level.
-- This is a safety net on top of the check constraint and package logic.
CREATE OR REPLACE TRIGGER trg_balance_guard
  BEFORE UPDATE OF balance ON WALLET
  FOR EACH ROW
BEGIN
  IF :NEW.balance < 0 THEN
    RAISE_APPLICATION_ERROR(-20002, 'Wallet balance cannot be negative.');
  END IF;
END;
/


-- Enforces valid state transitions on transactions.
-- Allowed: PENDING -> SUCCESS, PENDING -> FAILED, SUCCESS -> REVERSED
-- Anything else is rejected at the database level.
CREATE OR REPLACE TRIGGER trg_txn_state_machine
  BEFORE UPDATE OF status ON TRANSACTION_HISTORY
  FOR EACH ROW
DECLARE
  v_ok BOOLEAN := FALSE;
BEGIN
  v_ok :=
    (:OLD.status = 'PENDING' AND :NEW.status IN ('SUCCESS', 'FAILED')) OR
    (:OLD.status = 'SUCCESS' AND :NEW.status IN ('REVERSED', 'ROLLED_BACK')) OR
    (:OLD.status = :NEW.status);

  IF NOT v_ok THEN
    RAISE_APPLICATION_ERROR(
      -20003,
      'Invalid status transition: ' || :OLD.status || ' -> ' || :NEW.status
    );
  END IF;
END;
/


-- Auto-freezes a wallet after 3 consecutive failed transactions.
-- Uses wallet_ops.consecutive_failures to count from the most recent rows.
CREATE OR REPLACE TRIGGER trg_auto_freeze
  AFTER INSERT ON TRANSACTION_HISTORY
  FOR EACH ROW
  WHEN (NEW.status = 'FAILED')
DECLARE
  v_failures NUMBER;
  v_current  VARCHAR2(10);
BEGIN
  v_failures := wallet_ops.consecutive_failures(:NEW.wallet_id);
  IF v_failures >= 3 THEN
    SELECT status INTO v_current FROM WALLET WHERE wallet_id = :NEW.wallet_id;
    IF v_current = 'ACTIVE' THEN
      UPDATE WALLET
         SET status      = 'FROZEN',
             freeze_note = 'Auto-frozen after ' || v_failures || ' consecutive failures',
             updated_at  = SYSTIMESTAMP
       WHERE wallet_id   = :NEW.wallet_id;

      wallet_ops.write_audit(
        :NEW.initiated_by, 'AUTO_FREEZE', 'WALLET',
        :NEW.wallet_id, 'ACTIVE', 'FROZEN'
      );
    END IF;
  END IF;
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
/


-- ============================================================
-- SEED DATA
-- ============================================================

-- Users (password_hash values would be bcrypt hashes in production)
INSERT INTO USERS(full_name, email, phone, password_hash, role_id)
VALUES ('Kunjal Syal',   'kunjal@tietu.ac.in',   '9876500001', 'hash_ks', 1);

INSERT INTO USERS(full_name, email, phone, password_hash, role_id)
VALUES ('Barleen Kaur',  'barleen@tietu.ac.in',  '9876500002', 'hash_bk', 1);

INSERT INTO USERS(full_name, email, phone, password_hash, role_id)
VALUES ('Ayush Vaibhav', 'ayush@tietu.ac.in',    '9876500003', 'hash_av', 1);

INSERT INTO USERS(full_name, email, phone, password_hash, role_id)
VALUES ('Diksha Arora',  'diksha@tietu.ac.in',   '9876500004', 'hash_da', 2);

INSERT INTO USERS(full_name, email, phone, password_hash, role_id)
VALUES ('Audit User',    'auditor@tietu.ac.in',  '9876500005', 'hash_au', 3);

COMMIT;

-- Wallets
INSERT INTO WALLET(user_id, balance) VALUES (1001, 22000);
INSERT INTO WALLET(user_id, balance) VALUES (1002, 15000);
INSERT INTO WALLET(user_id, balance) VALUES (1003, 8500);

COMMIT;

-- Spending limits
INSERT INTO SPENDING_LIMIT(wallet_id, daily_limit, monthly_limit, per_txn_limit)
VALUES (1, 10000, 100000, 5000);

INSERT INTO SPENDING_LIMIT(wallet_id, daily_limit, monthly_limit, per_txn_limit)
VALUES (2, 5000, 50000, 2000);

INSERT INTO SPENDING_LIMIT(wallet_id, daily_limit, monthly_limit, per_txn_limit)
VALUES (3, 3000, 30000, 1500);

COMMIT;


-- ============================================================
-- USEFUL QUERIES (reference for the DBMS demo)
-- ============================================================

-- Check daily spend for a wallet
-- SELECT wallet_ops.daily_spent(1) FROM dual;

-- Wallet summary view
-- SELECT * FROM VW_WALLET_SUMMARY;

-- Recent audit trail
-- SELECT * FROM VW_AUDIT_DETAIL ORDER BY created_at DESC FETCH FIRST 20 ROWS ONLY;

-- Pending refunds
-- SELECT r.refund_id, u.full_name, t.amount, r.reason, r.requested_at
--   FROM REFUND_REQUEST r
--   JOIN TRANSACTION_HISTORY t ON r.txn_id = t.txn_id
--   JOIN USERS u ON r.requested_by = u.user_id
--  WHERE r.approval_status = 'PENDING';

-- Monthly spend per wallet
-- SELECT wallet_id, SUM(amount) AS total_spent
--   FROM TRANSACTION_HISTORY
--  WHERE txn_type IN ('DEBIT','TRANSFER')
--    AND status = 'SUCCESS'
--    AND TRUNC(created_at,'MM') = TRUNC(SYSDATE,'MM')
--  GROUP BY wallet_id;
