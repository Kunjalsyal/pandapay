require("dotenv").config();

const express = require("express");
const cors = require("cors");
const oracledb = require("oracledb");
const path = require("path");

const app = express();

app.use(cors());
app.use(express.json());


app.use(express.static(path.join(__dirname)));

const db = {
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  connectString: process.env.DB_CONNECT_STRING
};

async function query(sql, binds = {}) {
  let conn;
  try {
    conn = await oracledb.getConnection(db);
    const result = await conn.execute(sql, binds, {
      outFormat: oracledb.OUT_FORMAT_OBJECT
    });
    return result;
  } finally {
    if (conn) await conn.close();
  }
}


app.get("/api/wallet/:userId", async (req, res) => {
  try {
    const result = await query(
      "SELECT * FROM VW_WALLET_SUMMARY WHERE user_id = :userIdBind",
      { userIdBind: Number(req.params.userId) }
    );

    if (!result.rows.length) {
      return res.status(404).json({ error: "Wallet not found" });
    }

    res.json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/api/wallet/:walletId/spent", async (req, res) => {
  try {
    const result = await query(
      `SELECT
         wallet_ops.daily_spent(:walletIdBind) AS daily_spent,
         wallet_ops.monthly_spent(:walletIdBind) AS monthly_spent
       FROM dual`,
      { walletIdBind: Number(req.params.walletId) }
    );

    res.json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/api/transactions/:walletId", async (req, res) => {
  try {
    const result = await query(
      `SELECT * FROM VW_TXN_HISTORY
       WHERE wallet_id = :walletIdBind
       ORDER BY txn_id DESC`,
      { walletIdBind: Number(req.params.walletId) }
    );

    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post("/api/transaction", async (req, res) => {
  const { walletId, txnType, amount, description, initiatedBy, recipientId } = req.body;

  if (!walletId || !txnType || !amount || !description || !initiatedBy) {
    return res.status(400).json({ error: "Missing required fields" });
  }

  let conn;

  try {
    conn = await oracledb.getConnection(db);

    const result = await conn.execute(
      `BEGIN
         wallet_ops.do_transaction(
           p_wallet_id    => :wallet_id,
           p_type         => :txn_type,
           p_amount       => :amount,
           p_description  => :description,
           p_initiated_by => :initiated_by,
           p_recipient_id => :recipient_id,
           p_txn_id       => :txn_id,
           p_status       => :status,
           p_message      => :message
         );
       END;`,
      {
        wallet_id: Number(walletId),
        txn_type: txnType,
        amount: parseFloat(amount),
        description,
        initiated_by: Number(initiatedBy),
        recipient_id: recipientId ? Number(recipientId) : null,
        txn_id: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER },
        status: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 20 },
        message: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 400 }
      }
    );

    await conn.commit();

    res.json({
      txnId: result.outBinds.txn_id,
      status: result.outBinds.status,
      message: result.outBinds.message
    });
  } catch (err) {
    if (conn) await conn.rollback();
    res.status(500).json({ error: err.message });
  } finally {
    if (conn) await conn.close();
  }
});

app.get("/api/refunds", async (req, res) => {
  try {
    const result = await query(
      `SELECT
         r.refund_id,
         r.txn_id,
         r.reason,
         r.approval_status,
         r.admin_note,
         TO_CHAR(r.requested_at, 'DD Mon YYYY') AS requested_at,
         t.amount,
         u.full_name AS requested_by_name
       FROM REFUND_REQUEST r
       JOIN TRANSACTION_HISTORY t ON r.txn_id = t.txn_id
       JOIN USERS u ON r.requested_by = u.user_id
       ORDER BY r.requested_at DESC`
    );

    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post("/api/refund/request", async (req, res) => {
  const { txnId, requestedBy, reason } = req.body;

  if (!txnId || !requestedBy || !reason) {
    return res.status(400).json({ error: "txnId, requestedBy, reason required" });
  }

  let conn;

  try {
    conn = await oracledb.getConnection(db);

    await conn.execute(
      `INSERT INTO REFUND_REQUEST(refund_id, txn_id, requested_by, reason)
       VALUES (SEQ_REFUND.NEXTVAL, :txnIdBind, :requestedByBind, :reasonBind)`,
      {
        txnIdBind: Number(txnId),
        requestedByBind: Number(requestedBy),
        reasonBind: reason
      }
    );

    await conn.commit();
    res.json({ success: true });
  } catch (err) {
    if (conn) await conn.rollback();
    res.status(500).json({ error: err.message });
  } finally {
    if (conn) await conn.close();
  }
});

app.post("/api/refund/process", async (req, res) => {
  const { refundId, adminId, decision, note } = req.body;

  let conn;

  try {
    conn = await oracledb.getConnection(db);

    const result = await conn.execute(
      `BEGIN
         wallet_ops.handle_refund(
           p_refund_id => :refund_id,
           p_admin_id  => :admin_id,
           p_decision  => :decision,
           p_note      => :note,
           p_status    => :status,
           p_message   => :message
         );
       END;`,
      {
        refund_id: Number(refundId),
        admin_id: Number(adminId),
        decision,
        note: note || "",
        status: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 20 },
        message: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 400 }
      }
    );

    await conn.commit();

    res.json({
      status: result.outBinds.status,
      message: result.outBinds.message
    });
  } catch (err) {
    if (conn) await conn.rollback();
    res.status(500).json({ error: err.message });
  } finally {
    if (conn) await conn.close();
  }
});

app.get("/api/wallets", async (req, res) => {
  try {
    const result = await query(
      "SELECT * FROM VW_WALLET_SUMMARY ORDER BY user_id"
    );

    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post("/api/wallet/status", async (req, res) => {
  const { walletId, adminId, action, reason } = req.body;

  let conn;

  try {
    conn = await oracledb.getConnection(db);

    const result = await conn.execute(
      `BEGIN
         wallet_ops.set_wallet_status(
           p_wallet_id => :wallet_id,
           p_admin_id  => :admin_id,
           p_action    => :action,
           p_reason    => :reason,
           p_status    => :status,
           p_message   => :message
         );
       END;`,
      {
        wallet_id: Number(walletId),
        admin_id: Number(adminId),
        action,
        reason: reason || "",
        status: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 20 },
        message: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 400 }
      }
    );

    await conn.commit();

    res.json({
      status: result.outBinds.status,
      message: result.outBinds.message
    });
  } catch (err) {
    if (conn) await conn.rollback();
    res.status(500).json({ error: err.message });
  } finally {
    if (conn) await conn.close();
  }
});

app.get("/api/audit", async (req, res) => {
  try {
    const result = await query(
      `SELECT * FROM VW_AUDIT_DETAIL
       ORDER BY audit_id DESC
       FETCH FIRST 100 ROWS ONLY`
    );

    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get("/api/health", async (req, res) => {
  try {
    await query("SELECT 1 FROM dual");
    res.json({ ok: true });
  } catch (err) {
    res.status(503).json({ ok: false, message: err.message });
  }
});

const PORT = process.env.PORT || 3000;

app.listen(PORT, () => {
  console.log(`Server running at http://localhost:${PORT}`);
  console.log("Oracle:", db.connectString);
});