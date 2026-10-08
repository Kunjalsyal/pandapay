-- Digital Wallet System
-- Course: UCS310 - Database Management Systems
-- Thapar Institute of Engineering and Technology, Patiala
-- Authors: Barleen Kaur, Ayush Vaibhav, Kunjal Syal
-- Session: Jan-May 2026
--
-- Final version: ADMIN-managed USER wallets with spending controls,
-- transactional processing, refund approval, wallet freezing and
-- immutable auditing.
--
-- Run this entire file in Oracle SQL Developer (F5).
-- Target: Oracle Database XE / compatible Oracle database.

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

CREATE SEQUENCE SEQ_USER   START WITH 1001 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SEQ_WALLET START WITH 1    INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SEQ_TXN    START WITH 1    INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SEQ_REFUND START WITH 1    INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SEQ_AUDIT  START WITH 1    INCREMENT BY 1 NOCACHE NOCYCLE;

CREATE TABLE ROLES (
  role_id   NUMBER        PRIMARY KEY,
  role_name VARCHAR2(20)  NOT NULL UNIQUE,
  CONSTRAINT chk_role_name CHECK (role_name IN ('USER', 'ADMIN', 'AUDITOR'))
);

INSERT INTO ROLES VALUES (1, 'USER');
INSERT INTO ROLES VALUES (2, 'ADMIN');
INSERT INTO ROLES VALUES (3, 'AUDITOR');
COMMIT;

CREATE TABLE USERS (
  user_id       NUMBER         DEFAULT SEQ_USER.NEXTVAL PRIMARY KEY,
  full_name     VARCHAR2(100)  NOT NULL,
  email         VARCHAR2(150)  NOT NULL UNIQUE,
  phone         VARCHAR2(15),
  password_hash VARCHAR2(256)  NOT NULL,
  role_id       NUMBER         NOT NULL,
  is_active     CHAR(1)        DEFAULT 'Y' NOT NULL,
  created_at    TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT fk_user_role   FOREIGN KEY (role_id) REFERENCES ROLES(role_id),
  CONSTRAINT chk_user_active CHECK (is_active IN ('Y','N'))
);

CREATE TABLE WALLET (
  wallet_id    NUMBER        DEFAULT SEQ_WALLET.NEXTVAL PRIMARY KEY,
  user_id      NUMBER        NOT NULL UNIQUE,
  admin_id     NUMBER        NOT NULL,
  balance      NUMBER(12, 2) DEFAULT 0 NOT NULL,
  status       VARCHAR2(10)   DEFAULT 'ACTIVE' NOT NULL,
  currency     VARCHAR2(3)    DEFAULT 'INR' NOT NULL,
  freeze_note  VARCHAR2(300),
  created_at   TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  updated_at   TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT fk_wallet_user   FOREIGN KEY (user_id)  REFERENCES USERS(user_id),
  CONSTRAINT fk_wallet_admin  FOREIGN KEY (admin_id) REFERENCES USERS(user_id),
  CONSTRAINT chk_balance      CHECK (balance >= 0),
  CONSTRAINT chk_wallet_status CHECK (status IN ('ACTIVE', 'FROZEN')),
  CONSTRAINT chk_currency     CHECK (currency IN ('INR', 'USD', 'EUR'))
);

CREATE TABLE SPENDING_LIMIT (
  wallet_id      NUMBER        PRIMARY KEY,
  daily_limit    NUMBER(12, 2) DEFAULT 10000  NOT NULL,
  monthly_limit  NUMBER(12, 2) DEFAULT 100000 NOT NULL,
  per_txn_limit  NUMBER(12, 2) DEFAULT 5000   NOT NULL,
  CONSTRAINT fk_limit_wallet  FOREIGN KEY (wallet_id) REFERENCES WALLET(wallet_id),
  CONSTRAINT chk_daily_pos    CHECK (daily_limit   > 0),
  CONSTRAINT chk_monthly_pos  CHECK (monthly_limit > 0),
  CONSTRAINT chk_per_txn_pos  CHECK (per_txn_limit > 0),
  CONSTRAINT chk_daily_monthly CHECK (daily_limit <= monthly_limit),
  CONSTRAINT chk_per_txn_daily CHECK (per_txn_limit <= daily_limit)
);

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
  CONSTRAINT fk_txn_wallet    FOREIGN KEY (wallet_id) REFERENCES WALLET(wallet_id),
  CONSTRAINT fk_txn_user      FOREIGN KEY (initiated_by) REFERENCES USERS(user_id),
  CONSTRAINT chk_txn_type     CHECK (txn_type IN ('CREDIT','DEBIT','TRANSFER','REFUND')),
  CONSTRAINT chk_txn_status   CHECK (status IN ('PENDING','SUCCESS','FAILED','REVERSED','ROLLED_BACK')),
  CONSTRAINT chk_txn_amount   CHECK (amount > 0)
);

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
  CONSTRAINT fk_refund_txn      FOREIGN KEY (txn_id) REFERENCES TRANSACTION_HISTORY(txn_id),
  CONSTRAINT fk_refund_user     FOREIGN KEY (requested_by) REFERENCES USERS(user_id),
  CONSTRAINT fk_refund_admin    FOREIGN KEY (approved_by) REFERENCES USERS(user_id),
  CONSTRAINT chk_refund_status  CHECK (approval_status IN ('PENDING','APPROVED','REJECTED'))
);

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

CREATE INDEX idx_audit_table_date ON AUDIT_LOG(table_name, created_at);
CREATE INDEX idx_audit_performer  ON AUDIT_LOG(performed_by, created_at);
CREATE INDEX idx_txn_wallet_date  ON TRANSACTION_HISTORY(wallet_id, created_at);
CREATE INDEX idx_txn_status       ON TRANSACTION_HISTORY(status);

CREATE OR REPLACE VIEW VW_WALLET_SUMMARY AS
SELECT
  u.user_id,
  u.full_name,
  u.email,
  w.wallet_id,
  w.admin_id,
  admin_u.full_name AS admin_name,
  w.balance,
  w.currency,
  w.status,
  w.freeze_note,
  sl.daily_limit,
  sl.monthly_limit,
  sl.per_txn_limit
FROM USERS u
JOIN WALLET w ON u.user_id = w.user_id
JOIN USERS admin_u ON w.admin_id = admin_u.user_id
LEFT JOIN SPENDING_LIMIT sl ON w.wallet_id = sl.wallet_id;

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

CREATE OR REPLACE PACKAGE wallet_ops AS

  PROCEDURE write_audit(
    p_performed_by IN NUMBER,
    p_action       IN VARCHAR2,
    p_table        IN VARCHAR2,
    p_record_id    IN NUMBER,
    p_old          IN VARCHAR2 DEFAULT NULL,
    p_new          IN VARCHAR2 DEFAULT NULL
  );

  FUNCTION daily_spent(p_wallet_id IN NUMBER) RETURN NUMBER;
  FUNCTION monthly_spent(p_wallet_id IN NUMBER) RETURN NUMBER;
  FUNCTION consecutive_failures(p_wallet_id IN NUMBER) RETURN NUMBER;
  FUNCTION new_reference RETURN VARCHAR2;

  PROCEDURE do_transaction(
    p_wallet_id    IN NUMBER,
    p_type         IN VARCHAR2,
    p_amount       IN NUMBER,
    p_description  IN VARCHAR2,
    p_initiated_by IN NUMBER,
    p_recipient_id IN NUMBER DEFAULT NULL,
    p_txn_id       OUT NUMBER,
    p_status       OUT VARCHAR2,
    p_message      OUT VARCHAR2
  );

  PROCEDURE request_refund(
    p_txn_id       IN NUMBER,
    p_requested_by IN NUMBER,
    p_reason       IN VARCHAR2,
    p_refund_id    OUT NUMBER,
    p_status       OUT VARCHAR2,
    p_message      OUT VARCHAR2
  );

  PROCEDURE handle_refund(
    p_refund_id IN NUMBER,
    p_admin_id  IN NUMBER,
    p_decision  IN VARCHAR2,
    p_note      IN VARCHAR2 DEFAULT NULL,
    p_status    OUT VARCHAR2,
    p_message   OUT VARCHAR2
  );

  PROCEDURE set_wallet_status(
    p_wallet_id IN NUMBER,
    p_admin_id  IN NUMBER,
    p_action    IN VARCHAR2,
    p_reason    IN VARCHAR2 DEFAULT NULL,
    p_status    OUT VARCHAR2,
    p_message   OUT VARCHAR2
  );

  PROCEDURE set_spending_limits(
    p_wallet_id     IN NUMBER,
    p_admin_id      IN NUMBER,
    p_daily_limit   IN NUMBER,
    p_monthly_limit IN NUMBER,
    p_per_txn_limit IN NUMBER,
    p_status        OUT VARCHAR2,
    p_message       OUT VARCHAR2
  );

END wallet_ops;
/

CREATE OR REPLACE PACKAGE BODY wallet_ops AS

  PROCEDURE assert_active_role(
    p_user_id IN NUMBER,
    p_required_role IN VARCHAR2
  ) IS
    v_role VARCHAR2(20);
  BEGIN
    SELECT r.role_name
      INTO v_role
      FROM USERS u
      JOIN ROLES r ON u.role_id = r.role_id
     WHERE u.user_id = p_user_id
       AND u.is_active = 'Y';

    IF v_role != p_required_role THEN
      RAISE_APPLICATION_ERROR(-20010,
        'User does not have the required ' || p_required_role || ' role.');
    END IF;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20011, 'Invalid or inactive user.');
  END assert_active_role;


  PROCEDURE assert_wallet_owner(
    p_wallet_id IN NUMBER,
    p_user_id IN NUMBER
  ) IS
    v_user_id NUMBER;
  BEGIN
    SELECT user_id INTO v_user_id
      FROM WALLET
     WHERE wallet_id = p_wallet_id;

    IF v_user_id != p_user_id THEN
      RAISE_APPLICATION_ERROR(-20012, 'User does not own this wallet.');
    END IF;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20013, 'Wallet not found.');
  END assert_wallet_owner;


  PROCEDURE assert_wallet_admin(
    p_wallet_id IN NUMBER,
    p_admin_id IN NUMBER
  ) IS
    v_manager NUMBER;
  BEGIN
    SELECT admin_id INTO v_manager
      FROM WALLET
     WHERE wallet_id = p_wallet_id;

    IF v_manager != p_admin_id THEN
      RAISE_APPLICATION_ERROR(-20014, 'Admin does not manage this wallet.');
    END IF;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20013, 'Wallet not found.');
  END assert_wallet_admin;


  PROCEDURE write_audit(
    p_performed_by IN NUMBER,
    p_action       IN VARCHAR2,
    p_table        IN VARCHAR2,
    p_record_id    IN NUMBER,
    p_old          IN VARCHAR2 DEFAULT NULL,
    p_new          IN VARCHAR2 DEFAULT NULL
  ) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO AUDIT_LOG(
      performed_by, action_type, table_name, record_id, old_value, new_value
    )
    VALUES (
      p_performed_by, p_action, p_table, p_record_id, p_old, p_new
    );
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
  END write_audit;


  FUNCTION daily_spent(p_wallet_id IN NUMBER) RETURN NUMBER IS
    v_total NUMBER := 0;
  BEGIN
    SELECT NVL(SUM(amount), 0)
      INTO v_total
      FROM TRANSACTION_HISTORY
     WHERE wallet_id = p_wallet_id
       AND txn_type IN ('DEBIT', 'TRANSFER')
       AND status = 'SUCCESS'
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
       AND txn_type IN ('DEBIT', 'TRANSFER')
       AND status = 'SUCCESS'
       AND TRUNC(created_at, 'MM') = TRUNC(SYSDATE, 'MM');
    RETURN v_total;
  END monthly_spent;


  FUNCTION consecutive_failures(p_wallet_id IN NUMBER) RETURN NUMBER IS
    v_count NUMBER := 0;
  BEGIN
    FOR r IN (
      SELECT status
      FROM (
        SELECT status, created_at, txn_id
        FROM TRANSACTION_HISTORY
        WHERE wallet_id = p_wallet_id
        ORDER BY created_at DESC, txn_id DESC
      )
      WHERE ROWNUM <= 5
    ) LOOP
      EXIT WHEN r.status != 'FAILED';
      v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
  END consecutive_failures;


  FUNCTION new_reference RETURN VARCHAR2 IS
  BEGIN
    RETURN 'TXN' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3');
  END new_reference;


  PROCEDURE record_failed_transaction(
    p_wallet_id    IN NUMBER,
    p_type         IN VARCHAR2,
    p_amount       IN NUMBER,
    p_description  IN VARCHAR2,
    p_initiated_by IN NUMBER,
    p_recipient_id IN NUMBER,
    p_reason       IN VARCHAR2,
    p_txn_id       OUT NUMBER
  ) IS
    v_wallet_balance NUMBER;
    v_txn_id NUMBER := SEQ_TXN.NEXTVAL;
    v_ref VARCHAR2(50);
  BEGIN
    SELECT balance INTO v_wallet_balance
      FROM WALLET
     WHERE wallet_id = p_wallet_id;

    v_ref := new_reference || LPAD(v_txn_id, 8, '0');

    INSERT INTO TRANSACTION_HISTORY(
      txn_id, wallet_id, txn_type, amount, status, description,
      reference_no, recipient_id, initiated_by, balance_before, balance_after
    )
    VALUES(
      v_txn_id, p_wallet_id, p_type, p_amount, 'FAILED',
      SUBSTR(p_description || ' [FAILED: ' || p_reason || ']', 1, 300),
      v_ref, p_recipient_id, p_initiated_by, v_wallet_balance, v_wallet_balance
    );

    write_audit(
      p_initiated_by, 'TXN_FAILED', 'TRANSACTION_HISTORY',
      v_txn_id, p_reason, 'FAILED'
    );

    COMMIT;
    p_txn_id := v_txn_id;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_txn_id := NULL;
  END record_failed_transaction;


  PROCEDURE do_transaction(
    p_wallet_id    IN NUMBER,
    p_type         IN VARCHAR2,
    p_amount       IN NUMBER,
    p_description  IN VARCHAR2,
    p_initiated_by IN NUMBER,
    p_recipient_id IN NUMBER DEFAULT NULL,
    p_txn_id       OUT NUMBER,
    p_status       OUT VARCHAR2,
    p_message      OUT VARCHAR2
  ) IS
    v_wallet       WALLET%ROWTYPE;
    v_recipient    WALLET%ROWTYPE;
    v_limits       SPENDING_LIMIT%ROWTYPE;
    v_role         VARCHAR2(20);
    v_type         VARCHAR2(20) := UPPER(TRIM(p_type));
    v_new_bal      NUMBER;
    v_recipient_new NUMBER;
    v_ref          VARCHAR2(50);
    v_txn_id       NUMBER;
    v_failed_id    NUMBER;

    e_frozen       EXCEPTION;
    e_no_funds     EXCEPTION;
    e_over_daily   EXCEPTION;
    e_over_monthly EXCEPTION;
    e_over_pertxn  EXCEPTION;
    e_bad_transfer EXCEPTION;
    e_bad_request  EXCEPTION;
  BEGIN
    p_txn_id := NULL;
    p_status := 'FAILED';
    p_message := NULL;

    IF p_amount IS NULL OR p_amount <= 0 OR p_description IS NULL OR TRIM(p_description) IS NULL THEN
      RAISE e_bad_request;
    END IF;

    IF v_type NOT IN ('CREDIT','DEBIT','TRANSFER') THEN
      RAISE_APPLICATION_ERROR(-20015, 'Only CREDIT, DEBIT and TRANSFER are allowed through this endpoint.');
    END IF;

    SELECT r.role_name
      INTO v_role
      FROM USERS u
      JOIN ROLES r ON u.role_id = r.role_id
     WHERE u.user_id = p_initiated_by
       AND u.is_active = 'Y';

    -- CREDIT = admin loads money into a managed user wallet.
    IF v_type = 'CREDIT' THEN
      IF v_role != 'ADMIN' THEN
        RAISE_APPLICATION_ERROR(-20016, 'Only admins can load money into a wallet.');
      END IF;
    ELSE
      IF v_role != 'USER' THEN
        RAISE_APPLICATION_ERROR(-20017, 'Only wallet users can spend or transfer money.');
      END IF;
    END IF;

    -- Lock wallets in deterministic order for transfers to reduce deadlock risk.
    IF v_type = 'TRANSFER' THEN
      IF p_recipient_id IS NULL OR p_recipient_id = p_wallet_id THEN
        RAISE e_bad_transfer;
      END IF;

      IF p_wallet_id < p_recipient_id THEN
        SELECT * INTO v_wallet FROM WALLET WHERE wallet_id = p_wallet_id FOR UPDATE;
        SELECT * INTO v_recipient FROM WALLET WHERE wallet_id = p_recipient_id FOR UPDATE;
      ELSE
        SELECT * INTO v_recipient FROM WALLET WHERE wallet_id = p_recipient_id FOR UPDATE;
        SELECT * INTO v_wallet FROM WALLET WHERE wallet_id = p_wallet_id FOR UPDATE;
      END IF;

      IF v_recipient.status != 'ACTIVE' THEN
        RAISE_APPLICATION_ERROR(-20018, 'Recipient wallet is frozen.');
      END IF;

      IF v_recipient.admin_id != v_wallet.admin_id THEN
        RAISE_APPLICATION_ERROR(-20019, 'Transfers are limited to wallets managed by the same admin.');
      END IF;

    ELSE
      SELECT * INTO v_wallet FROM WALLET
       WHERE wallet_id = p_wallet_id FOR UPDATE;
    END IF;

    -- Authorization is checked against the locked wallet, not user-supplied metadata.
    IF v_type = 'CREDIT' THEN
      IF v_wallet.admin_id != p_initiated_by THEN
        RAISE_APPLICATION_ERROR(-20014, 'Admin does not manage this wallet.');
      END IF;
    ELSE
      IF v_wallet.user_id != p_initiated_by THEN
        RAISE_APPLICATION_ERROR(-20012, 'User does not own this wallet.');
      END IF;
    END IF;

    IF v_wallet.status != 'ACTIVE' THEN
      RAISE e_frozen;
    END IF;

    BEGIN
      SELECT * INTO v_limits
        FROM SPENDING_LIMIT
       WHERE wallet_id = p_wallet_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        v_limits.daily_limit := 10000;
        v_limits.monthly_limit := 100000;
        v_limits.per_txn_limit := 5000;
    END;

    IF v_type IN ('DEBIT','TRANSFER') THEN
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
      WHEN v_type = 'CREDIT' THEN v_wallet.balance + p_amount
      ELSE v_wallet.balance - p_amount
    END;

    v_txn_id := SEQ_TXN.NEXTVAL;
    v_ref := new_reference || LPAD(v_txn_id, 8, '0');

    INSERT INTO TRANSACTION_HISTORY(
      txn_id, wallet_id, txn_type, amount, status, description,
      reference_no, recipient_id, initiated_by,
      balance_before, balance_after
    )
    VALUES(
      v_txn_id, p_wallet_id, v_type, p_amount, 'SUCCESS', p_description,
      v_ref, p_recipient_id, p_initiated_by,
      v_wallet.balance, v_new_bal
    );

    UPDATE WALLET
       SET balance = v_new_bal,
           updated_at = SYSTIMESTAMP
     WHERE wallet_id = p_wallet_id;

    IF v_type = 'TRANSFER' THEN
      v_recipient_new := v_recipient.balance + p_amount;

      UPDATE WALLET
         SET balance = v_recipient_new,
             updated_at = SYSTIMESTAMP
       WHERE wallet_id = p_recipient_id;

      INSERT INTO TRANSACTION_HISTORY(
        txn_id, wallet_id, txn_type, amount, status,
        description, reference_no, recipient_id, initiated_by,
        balance_before, balance_after
      )
      VALUES(
        SEQ_TXN.NEXTVAL, p_recipient_id, 'CREDIT', p_amount, 'SUCCESS',
        'Transfer received (ref: ' || v_ref || ')',
        v_ref || '-CR', NULL, p_initiated_by,
        v_recipient.balance, v_recipient_new
      );
    END IF;

    COMMIT;

    write_audit(
      p_initiated_by, 'TXN_' || v_type, 'TRANSACTION_HISTORY',
      v_txn_id, 'balance=' || v_wallet.balance,
      'balance=' || v_new_bal
    );

    p_txn_id := v_txn_id;
    p_status := 'SUCCESS';
    p_message := 'Transaction complete. Ref: ' || v_ref;

  EXCEPTION
    WHEN e_frozen THEN
      ROLLBACK;
      p_status := 'FAILED';
      p_message := 'Wallet is FROZEN. Contact the admin.';

    WHEN e_no_funds THEN
      ROLLBACK;
      record_failed_transaction(
        p_wallet_id, v_type, p_amount, p_description, p_initiated_by,
        p_recipient_id, 'Insufficient balance', v_failed_id
      );
      p_txn_id := v_failed_id;
      p_status := 'FAILED';
      p_message := 'Insufficient balance.';

    WHEN e_over_pertxn THEN
      ROLLBACK;
      record_failed_transaction(
        p_wallet_id, v_type, p_amount, p_description, p_initiated_by,
        p_recipient_id, 'Per-transaction spending limit exceeded', v_failed_id
      );
      p_txn_id := v_failed_id;
      p_status := 'FAILED';
      p_message := 'Exceeds the per-transaction limit of ' || v_limits.per_txn_limit || '.';

    WHEN e_over_daily THEN
      ROLLBACK;
      record_failed_transaction(
        p_wallet_id, v_type, p_amount, p_description, p_initiated_by,
        p_recipient_id, 'Daily spending limit exceeded', v_failed_id
      );
      p_txn_id := v_failed_id;
      p_status := 'FAILED';
      p_message := 'Daily spending limit would be exceeded.';

    WHEN e_over_monthly THEN
      ROLLBACK;
      record_failed_transaction(
        p_wallet_id, v_type, p_amount, p_description, p_initiated_by,
        p_recipient_id, 'Monthly spending limit exceeded', v_failed_id
      );
      p_txn_id := v_failed_id;
      p_status := 'FAILED';
      p_message := 'Monthly spending limit would be exceeded.';

    WHEN e_bad_transfer THEN
      ROLLBACK;
      p_status := 'FAILED';
      p_message := 'Invalid transfer request.';

    WHEN e_bad_request THEN
      ROLLBACK;
      p_status := 'FAILED';
      p_message := 'Amount and description are required.';

    WHEN OTHERS THEN
      ROLLBACK;
      p_status := 'ERROR';
      p_message := SQLERRM;
  END do_transaction;


  PROCEDURE request_refund(
    p_txn_id       IN NUMBER,
    p_requested_by IN NUMBER,
    p_reason       IN VARCHAR2,
    p_refund_id    OUT NUMBER,
    p_status       OUT VARCHAR2,
    p_message      OUT VARCHAR2
  ) IS
    v_wallet_id NUMBER;
    v_owner_id NUMBER;
    v_type VARCHAR2(10);
    v_txn_status VARCHAR2(15);
    v_existing NUMBER;
    v_refund NUMBER;
  BEGIN
    assert_active_role(p_requested_by, 'USER');

    SELECT t.wallet_id, w.user_id, t.txn_type, t.status
      INTO v_wallet_id, v_owner_id, v_type, v_txn_status
      FROM TRANSACTION_HISTORY t
      JOIN WALLET w ON t.wallet_id = w.wallet_id
     WHERE t.txn_id = p_txn_id
       FOR UPDATE;

    IF v_owner_id != p_requested_by THEN
      RAISE_APPLICATION_ERROR(-20021, 'You can only request refunds for your own transactions.');
    END IF;

    IF v_type NOT IN ('DEBIT','TRANSFER') OR v_txn_status != 'SUCCESS' THEN
      RAISE_APPLICATION_ERROR(-20022, 'Only successful debit/transfer transactions can be refunded.');
    END IF;

    IF p_reason IS NULL OR TRIM(p_reason) IS NULL THEN
      RAISE_APPLICATION_ERROR(-20023, 'Refund reason is required.');
    END IF;

    SELECT COUNT(*)
      INTO v_existing
      FROM REFUND_REQUEST
     WHERE txn_id = p_txn_id
       AND approval_status IN ('PENDING','APPROVED');

    IF v_existing > 0 THEN
      RAISE_APPLICATION_ERROR(-20024, 'A refund is already pending or approved for this transaction.');
    END IF;

    v_refund := SEQ_REFUND.NEXTVAL;

    INSERT INTO REFUND_REQUEST(refund_id, txn_id, requested_by, reason)
    VALUES(v_refund, p_txn_id, p_requested_by, p_reason);

    COMMIT;

    write_audit(
      p_requested_by, 'REFUND_REQUESTED', 'REFUND_REQUEST',
      v_refund, NULL, 'PENDING'
    );

    p_refund_id := v_refund;
    p_status := 'SUCCESS';
    p_message := 'Refund request submitted for admin approval.';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_refund_id := NULL;
      p_status := 'ERROR';
      p_message := SQLERRM;
  END request_refund;


  PROCEDURE handle_refund(
    p_refund_id IN NUMBER,
    p_admin_id  IN NUMBER,
    p_decision  IN VARCHAR2,
    p_note      IN VARCHAR2 DEFAULT NULL,
    p_status    OUT VARCHAR2,
    p_message   OUT VARCHAR2
  ) IS
    v_refund REFUND_REQUEST%ROWTYPE;
    v_txn TRANSACTION_HISTORY%ROWTYPE;
    v_wallet WALLET%ROWTYPE;
    v_role VARCHAR2(20);
  BEGIN
    assert_active_role(p_admin_id, 'ADMIN');

    SELECT * INTO v_refund
      FROM REFUND_REQUEST
     WHERE refund_id = p_refund_id
       FOR UPDATE;

    SELECT t.*
      INTO v_txn
      FROM TRANSACTION_HISTORY t
     WHERE t.txn_id = v_refund.txn_id
       FOR UPDATE;

    SELECT * INTO v_wallet
      FROM WALLET
     WHERE wallet_id = v_txn.wallet_id
       FOR UPDATE;

    IF v_wallet.admin_id != p_admin_id THEN
      p_status := 'ERROR';
      p_message := 'Admin does not manage this wallet.';
      ROLLBACK;
      RETURN;
    END IF;

    IF v_refund.approval_status != 'PENDING' THEN
      p_status := 'ERROR';
      p_message := 'Refund already resolved: ' || v_refund.approval_status;
      ROLLBACK;
      RETURN;
    END IF;

    IF UPPER(p_decision) NOT IN ('APPROVED','REJECTED') THEN
      p_status := 'ERROR';
      p_message := 'Decision must be APPROVED or REJECTED.';
      ROLLBACK;
      RETURN;
    END IF;

    IF UPPER(p_decision) = 'APPROVED' THEN
      IF v_txn.status != 'SUCCESS' OR v_txn.txn_type NOT IN ('DEBIT','TRANSFER') THEN
        p_status := 'ERROR';
        p_message := 'This transaction is no longer eligible for refund.';
        ROLLBACK;
        RETURN;
      END IF;

      UPDATE WALLET
         SET balance = balance + v_txn.amount,
             updated_at = SYSTIMESTAMP
       WHERE wallet_id = v_txn.wallet_id;

      UPDATE TRANSACTION_HISTORY
         SET status = 'REVERSED',
             updated_at = SYSTIMESTAMP
       WHERE txn_id = v_txn.txn_id;

      INSERT INTO TRANSACTION_HISTORY(
        txn_id, wallet_id, txn_type, amount, status,
        description, initiated_by, balance_before, balance_after
      )
      VALUES(
        SEQ_TXN.NEXTVAL, v_txn.wallet_id, 'REFUND', v_txn.amount, 'SUCCESS',
        'Refund for transaction #' || v_txn.txn_id,
        p_admin_id, v_wallet.balance, v_wallet.balance + v_txn.amount
      );
    END IF;

    UPDATE REFUND_REQUEST
       SET approval_status = UPPER(p_decision),
           approved_by = p_admin_id,
           admin_note = p_note,
           resolved_at = SYSTIMESTAMP
     WHERE refund_id = p_refund_id;

    COMMIT;

    write_audit(
      p_admin_id,
      'REFUND_' || UPPER(p_decision),
      'REFUND_REQUEST',
      p_refund_id,
      'PENDING',
      UPPER(p_decision)
    );

    p_status := 'SUCCESS';
    p_message := CASE
      WHEN UPPER(p_decision) = 'APPROVED'
        THEN 'Refund approved. ' || v_txn.amount || ' credited back.'
      ELSE 'Refund request rejected.'
    END;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status := 'ERROR';
      p_message := SQLERRM;
  END handle_refund;


  PROCEDURE set_wallet_status(
    p_wallet_id IN NUMBER,
    p_admin_id  IN NUMBER,
    p_action    IN VARCHAR2,
    p_reason    IN VARCHAR2 DEFAULT NULL,
    p_status    OUT VARCHAR2,
    p_message   OUT VARCHAR2
  ) IS
    v_wallet WALLET%ROWTYPE;
    v_action VARCHAR2(20) := UPPER(TRIM(p_action));
    v_new_status VARCHAR2(10);
  BEGIN
    assert_active_role(p_admin_id, 'ADMIN');

    SELECT * INTO v_wallet
      FROM WALLET
     WHERE wallet_id = p_wallet_id
       FOR UPDATE;

    IF v_wallet.admin_id != p_admin_id THEN
      p_status := 'ERROR';
      p_message := 'Admin does not manage this wallet.';
      ROLLBACK;
      RETURN;
    END IF;

    IF v_action = 'FREEZE' THEN
      v_new_status := 'FROZEN';
    ELSIF v_action = 'UNFREEZE' THEN
      v_new_status := 'ACTIVE';
    ELSE
      RAISE_APPLICATION_ERROR(-20025, 'Action must be FREEZE or UNFREEZE.');
    END IF;

    UPDATE WALLET
       SET status = v_new_status,
           freeze_note = CASE WHEN v_new_status = 'FROZEN' THEN p_reason ELSE NULL END,
           updated_at = SYSTIMESTAMP
     WHERE wallet_id = p_wallet_id;

    COMMIT;

    write_audit(
      p_admin_id,
      'WALLET_' || v_action,
      'WALLET',
      p_wallet_id,
      v_wallet.status,
      v_new_status
    );

    p_status := 'SUCCESS';
    p_message := 'Wallet ' || v_new_status || '.';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status := 'ERROR';
      p_message := SQLERRM;
  END set_wallet_status;


  PROCEDURE set_spending_limits(
    p_wallet_id     IN NUMBER,
    p_admin_id      IN NUMBER,
    p_daily_limit   IN NUMBER,
    p_monthly_limit IN NUMBER,
    p_per_txn_limit IN NUMBER,
    p_status        OUT VARCHAR2,
    p_message       OUT VARCHAR2
  ) IS
    v_wallet WALLET%ROWTYPE;
    v_old SPENDING_LIMIT%ROWTYPE;
    v_old_value VARCHAR2(4000);
  BEGIN
    assert_active_role(p_admin_id, 'ADMIN');

    IF p_daily_limit <= 0 OR p_monthly_limit <= 0 OR p_per_txn_limit <= 0 THEN
      RAISE_APPLICATION_ERROR(-20026, 'All spending limits must be positive.');
    END IF;

    IF p_daily_limit > p_monthly_limit THEN
      RAISE_APPLICATION_ERROR(-20027, 'Daily limit cannot exceed monthly limit.');
    END IF;

    IF p_per_txn_limit > p_daily_limit THEN
      RAISE_APPLICATION_ERROR(-20028, 'Per-transaction limit cannot exceed daily limit.');
    END IF;

    SELECT * INTO v_wallet
      FROM WALLET
     WHERE wallet_id = p_wallet_id
       FOR UPDATE;

    IF v_wallet.admin_id != p_admin_id THEN
      p_status := 'ERROR';
      p_message := 'Admin does not manage this wallet.';
      ROLLBACK;
      RETURN;
    END IF;

    BEGIN
      SELECT * INTO v_old
        FROM SPENDING_LIMIT
       WHERE wallet_id = p_wallet_id
       FOR UPDATE;
      v_old_value :=
        'daily=' || v_old.daily_limit ||
        ', monthly=' || v_old.monthly_limit ||
        ', per_txn=' || v_old.per_txn_limit;

      UPDATE SPENDING_LIMIT
         SET daily_limit = p_daily_limit,
             monthly_limit = p_monthly_limit,
             per_txn_limit = p_per_txn_limit
       WHERE wallet_id = p_wallet_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        v_old_value := 'none';
        INSERT INTO SPENDING_LIMIT(
          wallet_id, daily_limit, monthly_limit, per_txn_limit
        )
        VALUES(
          p_wallet_id, p_daily_limit, p_monthly_limit, p_per_txn_limit
        );
    END;

    COMMIT;

    write_audit(
      p_admin_id, 'LIMITS_UPDATED', 'SPENDING_LIMIT',
      p_wallet_id, v_old_value,
      'daily=' || p_daily_limit ||
      ', monthly=' || p_monthly_limit ||
      ', per_txn=' || p_per_txn_limit
    );

    p_status := 'SUCCESS';
    p_message := 'Spending limits updated.';
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_status := 'ERROR';
      p_message := SQLERRM;
  END set_spending_limits;

END wallet_ops;
/

CREATE OR REPLACE TRIGGER trg_audit_immutable
  BEFORE UPDATE OR DELETE ON AUDIT_LOG
  FOR EACH ROW
BEGIN
  RAISE_APPLICATION_ERROR(
    -20001,
    'Audit log is append-only. Existing audit records cannot be modified or deleted.'
  );
END;
/

CREATE OR REPLACE TRIGGER trg_balance_guard
  BEFORE UPDATE OF balance ON WALLET
  FOR EACH ROW
BEGIN
  IF :NEW.balance < 0 THEN
    RAISE_APPLICATION_ERROR(-20002, 'Wallet balance cannot be negative.');
  END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_txn_state_machine
  BEFORE UPDATE OF status ON TRANSACTION_HISTORY
  FOR EACH ROW
DECLARE
  v_ok BOOLEAN := FALSE;
BEGIN
  v_ok :=
    (:OLD.status = 'PENDING' AND :NEW.status IN ('SUCCESS','FAILED')) OR
    (:OLD.status = 'SUCCESS' AND :NEW.status IN ('REVERSED','ROLLED_BACK')) OR
    (:OLD.status = :NEW.status);

  IF NOT v_ok THEN
    RAISE_APPLICATION_ERROR(
      -20003,
      'Invalid status transition: ' || :OLD.status || ' -> ' || :NEW.status
    );
  END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_auto_freeze
FOR INSERT ON TRANSACTION_HISTORY
COMPOUND TRIGGER

  TYPE t_wallet_set IS TABLE OF BOOLEAN INDEX BY VARCHAR2(50);
  g_wallets t_wallet_set;

  AFTER EACH ROW IS
    v_key VARCHAR2(50);
  BEGIN
    IF :NEW.status = 'FAILED' THEN
      v_key := TO_CHAR(:NEW.wallet_id);
      g_wallets(v_key) := TRUE;
    END IF;
  END AFTER EACH ROW;

  AFTER STATEMENT IS
    v_key VARCHAR2(50);
    v_failures NUMBER;
    v_current VARCHAR2(10);
    v_actor NUMBER;
  BEGIN
    v_key := g_wallets.FIRST;

    WHILE v_key IS NOT NULL LOOP
      v_failures := wallet_ops.consecutive_failures(TO_NUMBER(v_key));

      IF v_failures >= 3 THEN
        SELECT status INTO v_current
          FROM WALLET
         WHERE wallet_id = TO_NUMBER(v_key);

        IF v_current = 'ACTIVE' THEN
          SELECT initiated_by INTO v_actor
            FROM TRANSACTION_HISTORY
           WHERE wallet_id = TO_NUMBER(v_key)
             AND status = 'FAILED'
           ORDER BY created_at DESC, txn_id DESC
           FETCH FIRST 1 ROW ONLY;

          UPDATE WALLET
             SET status = 'FROZEN',
                 freeze_note = 'Auto-frozen after ' || v_failures || ' consecutive failed attempts',
                 updated_at = SYSTIMESTAMP
           WHERE wallet_id = TO_NUMBER(v_key);

          wallet_ops.write_audit(
            v_actor,
            'AUTO_FREEZE',
            'WALLET',
            TO_NUMBER(v_key),
            'ACTIVE',
            'FROZEN'
          );
        END IF;
      END IF;

      v_key := g_wallets.NEXT(v_key);
    END LOOP;
  END AFTER STATEMENT;

END trg_auto_freeze;
/

-- Demo users. Passwords are stored as PBKDF2-SHA256 hashes.
-- Demo credentials:
-- USER:     kunjal@tietu.ac.in   / PandaPay@123
-- USER:     barleen@tietu.ac.in  / PandaPay@123
-- USER:     ayush@tietu.ac.in    / PandaPay@123
-- ADMIN:    diksha@tietu.ac.in   / PandaPayAdmin@123
-- AUDITOR:  auditor@tietu.ac.in  / PandaPayAudit@123

INSERT INTO USERS(full_name, email, phone, password_hash, role_id)
VALUES (
  'Kunjal Syal', 'kunjal@tietu.ac.in', '9876500001',
  'pbkdf2$310000$b8876c1d5f9fa0f03273cbc072a4cec2$e23ac47d121ceaa9da40100a1b00b57aa2c5b46475e68d49e18df52bbe71382b',
  1
);

INSERT INTO USERS(full_name, email, phone, password_hash, role_id)
VALUES (
  'Barleen Kaur', 'barleen@tietu.ac.in', '9876500002',
  'pbkdf2$310000$85874016484e63fb6b1c30ae970b5bea$6e04af50ef688f93cfcc6f3b28eee9b4dcc275c4c4c09cd7ffe4de6e1f5f7b3a',
  1
);

INSERT INTO USERS(full_name, email, phone, password_hash, role_id)
VALUES (
  'Ayush Vaibhav', 'ayush@tietu.ac.in', '9876500003',
  'pbkdf2$310000$a2e1024f15db4918fe36eb7fe4ad3fd3$32123322832a0e3e1bbe47188f584c58179957d84e4b8285b70d8ccc60968a40',
  1
);

INSERT INTO USERS(full_name, email, phone, password_hash, role_id)
VALUES (
  'Diksha Arora', 'diksha@tietu.ac.in', '9876500004',
  'pbkdf2$310000$bf06d8d10027b41ba371dbb2174e47f0$ec525eb603526a3f165d74e1952a6f5907ec1e6bc93e7506da9822917319b02f',
  2
);

INSERT INTO USERS(full_name, email, phone, password_hash, role_id)
VALUES (
  'Audit User', 'auditor@tietu.ac.in', '9876500005',
  'pbkdf2$310000$8cbb8a23e47947ed405fc9de59185088$46e8d97ac44b0ff8652fd1b08336deedb072b8e4d814045c8305ab991e72dec3',
  3
);

COMMIT;

INSERT INTO WALLET(user_id, admin_id, balance) VALUES (1001, 1004, 22000);
INSERT INTO WALLET(user_id, admin_id, balance) VALUES (1002, 1004, 15000);
INSERT INTO WALLET(user_id, admin_id, balance) VALUES (1003, 1004, 8500);
COMMIT;

INSERT INTO SPENDING_LIMIT(wallet_id, daily_limit, monthly_limit, per_txn_limit)
VALUES (1, 10000, 100000, 5000);

INSERT INTO SPENDING_LIMIT(wallet_id, daily_limit, monthly_limit, per_txn_limit)
VALUES (2, 5000, 50000, 2000);

INSERT INTO SPENDING_LIMIT(wallet_id, daily_limit, monthly_limit, per_txn_limit)
VALUES (3, 3000, 30000, 1500);

COMMIT;

-- Useful checks:
-- SELECT * FROM VW_WALLET_SUMMARY;
-- SELECT * FROM VW_TXN_HISTORY ORDER BY txn_id DESC;
-- SELECT * FROM VW_AUDIT_DETAIL ORDER BY audit_id DESC;
