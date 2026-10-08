require("dotenv").config();

const express = require("express");
const cors = require("cors");
const crypto = require("crypto");
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

let pool;


// ============================================================
// AUTHENTICATION
// ============================================================

function signToken(payload) {
  const secret = process.env.APP_SECRET || "change-this-in-production";

  const body = Buffer.from(
    JSON.stringify({
      ...payload,
      exp: Math.floor(Date.now() / 1000) + 60 * 60 * 8
    })
  ).toString("base64url");

  const sig = crypto
    .createHmac("sha256", secret)
    .update(body)
    .digest("base64url");

  return body + "." + sig;
}


function verifyToken(token) {
  if (!token) return null;

  const parts = token.split(".");
  if (parts.length !== 2) return null;

  const [body, sig] = parts;

  const secret = process.env.APP_SECRET || "change-this-in-production";

  const expected = crypto
    .createHmac("sha256", secret)
    .update(body)
    .digest("base64url");

  if (
    sig.length !== expected.length ||
    !crypto.timingSafeEqual(
      Buffer.from(sig),
      Buffer.from(expected)
    )
  ) {
    return null;
  }

  const payload = JSON.parse(
    Buffer.from(body, "base64url").toString()
  );

  if (!payload.exp || payload.exp < Math.floor(Date.now() / 1000)) {
    return null;
  }

  return payload;
}


function auth(req, res, next) {
  try {
    const token = (req.headers.authorization || "")
      .replace(/^Bearer\s+/i, "");

    const user = verifyToken(token);

    if (!user) {
      return res.status(401).json({
        error: "Authentication required"
      });
    }

    req.user = user;
    next();

  } catch {
    return res.status(401).json({
      error: "Invalid authentication token"
    });
  }
}


function allowRoles(...roles) {
  return (req, res, next) => {
    if (!roles.includes(req.user.role)) {
      return res.status(403).json({
        error: "You do not have permission for this operation"
      });
    }

    next();
  };
}


// ============================================================
// PASSWORD VERIFICATION
// ============================================================

function verifyPassword(password, stored) {
  const [scheme, iterations, saltHex, hashHex] =
    String(stored).split("$");

  if (
    scheme !== "pbkdf2" ||
    !iterations ||
    !saltHex ||
    !hashHex
  ) {
    return false;
  }

  const hash = crypto.pbkdf2Sync(
    password,
    Buffer.from(saltHex, "hex"),
    Number(iterations),
    32,
    "sha256"
  );

  const expected = Buffer.from(hashHex, "hex");

  return (
    expected.length === hash.length &&
    crypto.timingSafeEqual(hash, expected)
  );
}


// ============================================================
// DATABASE HELPERS
// ============================================================

async function query(sql, binds = {}) {
  const conn = await pool.getConnection();

  try {
    return await conn.execute(
      sql,
      binds,
      {
        outFormat: oracledb.OUT_FORMAT_OBJECT
      }
    );
  } finally {
    await conn.close();
  }
}


async function callPackage(sql, binds) {
  const conn = await pool.getConnection();

  try {
    const result = await conn.execute(sql, binds);

    await conn.commit();

    return result;

  } catch (err) {

    await conn.rollback();
    throw err;

  } finally {
    await conn.close();
  }
}


// ============================================================
// 1. LOGIN
// ============================================================

app.post("/api/login", async (req, res) => {

  const { email, password } = req.body;

  if (!email || !password) {
    return res.status(400).json({
      error: "Email and password are required"
    });
  }

  try {

    const result = await query(
      `SELECT
         u.user_id,
         u.full_name,
         u.password_hash,
         r.role_name,
         u.is_active
       FROM USERS u
       JOIN ROLES r
         ON u.role_id = r.role_id
       WHERE LOWER(u.email) = LOWER(:email)`,
      { email }
    );

    if (
      !result.rows.length ||
      result.rows[0].IS_ACTIVE !== "Y" ||
      !verifyPassword(
        password,
        result.rows[0].PASSWORD_HASH
      )
    ) {
      return res.status(401).json({
        error: "Invalid email or password"
      });
    }

    const row = result.rows[0];

    const user = {
      userId: row.USER_ID,
      name: row.FULL_NAME,
      role: row.ROLE_NAME
    };

    res.json({
      token: signToken(user),
      user
    });

  } catch (err) {

    res.status(500).json({
      error: err.message
    });

  }
});


// ============================================================
// 2. WALLET SUMMARY
// ============================================================

app.get("/api/wallet/:userId", auth, async (req, res) => {

  const userId = Number(req.params.userId);

  try {

    const result = await query(
      `SELECT *
       FROM VW_WALLET_SUMMARY
       WHERE user_id = :userId`,
      { userId }
    );

    if (!result.rows.length) {
      return res.status(404).json({
        error: "Wallet not found"
      });
    }

    const wallet = result.rows[0];

    // USER can only see their own wallet
    if (
      req.user.role === "USER" &&
      wallet.USER_ID !== req.user.userId
    ) {
      return res.status(403).json({
        error: "You can only view your own wallet"
      });
    }

    // ADMIN can only see wallets they manage
    if (
      req.user.role === "ADMIN" &&
      wallet.ADMIN_ID !== req.user.userId
    ) {
      return res.status(403).json({
        error: "Admin does not manage this wallet"
      });
    }

    // AUDITOR does not use wallet-owner pages
    if (req.user.role === "AUDITOR") {
      return res.status(403).json({
        error: "Auditors do not access wallet-owner data"
      });
    }

    res.json(wallet);

  } catch (err) {

    res.status(500).json({
      error: err.message
    });

  }
});


// ============================================================
// 3. WALLET SPENDING
// ============================================================

app.get("/api/wallet/:walletId/spent", auth, async (req, res) => {

  const walletId = Number(req.params.walletId);

  try {

    const owner = await query(
      `SELECT user_id, admin_id
       FROM WALLET
       WHERE wallet_id = :walletId`,
      { walletId }
    );

    if (!owner.rows.length) {
      return res.status(404).json({
        error: "Wallet not found"
      });
    }

    const wallet = owner.rows[0];

    if (
      req.user.role === "USER" &&
      wallet.USER_ID !== req.user.userId
    ) {
      return res.status(403).json({
        error: "You can only view your own spending"
      });
    }

    if (
      req.user.role === "ADMIN" &&
      wallet.ADMIN_ID !== req.user.userId
    ) {
      return res.status(403).json({
        error: "Admin does not manage this wallet"
      });
    }

    if (req.user.role === "AUDITOR") {
      return res.status(403).json({
        error: "Auditors do not access wallet spending"
      });
    }

    const result = await query(
      `SELECT
         wallet_ops.daily_spent(:walletId) AS daily_spent,
         wallet_ops.monthly_spent(:walletId) AS monthly_spent
       FROM dual`,
      { walletId }
    );

    res.json(result.rows[0]);

  } catch (err) {

    res.status(500).json({
      error: err.message
    });

  }
});


// ============================================================
// 4. TRANSACTION HISTORY
// ============================================================

app.get("/api/transactions/:walletId", auth, async (req, res) => {

  const walletId = Number(req.params.walletId);

  try {

    const owner = await query(
      `SELECT user_id, admin_id
       FROM WALLET
       WHERE wallet_id = :walletId`,
      { walletId }
    );

    if (!owner.rows.length) {
      return res.status(404).json({
        error: "Wallet not found"
      });
    }

    const wallet = owner.rows[0];

    if (
      req.user.role === "USER" &&
      wallet.USER_ID !== req.user.userId
    ) {
      return res.status(403).json({
        error: "You can only view your own transactions"
      });
    }

    if (
      req.user.role === "ADMIN" &&
      wallet.ADMIN_ID !== req.user.userId
    ) {
      return res.status(403).json({
        error: "Admin does not manage this wallet"
      });
    }

    if (req.user.role === "AUDITOR") {
      return res.status(403).json({
        error: "Auditors do not access wallet transactions"
      });
    }

    const result = await query(
      `SELECT *
       FROM VW_TXN_HISTORY
       WHERE wallet_id = :walletId
       ORDER BY txn_id DESC`,
      { walletId }
    );

    res.json(result.rows);

  } catch (err) {

    res.status(500).json({
      error: err.message
    });

  }
});


// ============================================================
// 5. CREATE TRANSACTION
// ============================================================

app.post("/api/transaction", auth, async (req, res) => {

  const {
    walletId,
    txnType,
    amount,
    description,
    recipientId
  } = req.body;

  if (
    !walletId ||
    !txnType ||
    !amount ||
    !description
  ) {
    return res.status(400).json({
      error:
        "walletId, txnType, amount and description are required"
    });
  }

  if (
    txnType === "CREDIT" &&
    req.user.role !== "ADMIN"
  ) {
    return res.status(403).json({
      error: "Only admins can load money"
    });
  }

  if (
    ["DEBIT", "TRANSFER"].includes(txnType) &&
    req.user.role !== "USER"
  ) {
    return res.status(403).json({
      error:
        "Only wallet users can spend or transfer money"
    });
  }

  try {

    const result = await callPackage(
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
        amount: Number(amount),
        description,
        initiated_by: req.user.userId,
        recipient_id:
          recipientId ? Number(recipientId) : null,

        txn_id: {
          dir: oracledb.BIND_OUT,
          type: oracledb.NUMBER
        },

        status: {
          dir: oracledb.BIND_OUT,
          type: oracledb.STRING,
          maxSize: 20
        },

        message: {
          dir: oracledb.BIND_OUT,
          type: oracledb.STRING,
          maxSize: 400
        }
      }
    );

    res.json({
      txnId: result.outBinds.txn_id,
      status: result.outBinds.status,
      message: result.outBinds.message
    });

  } catch (err) {

    res.status(500).json({
      error: err.message
    });

  }
});


// ============================================================
// 6. REFUND LIST
// ============================================================

app.get("/api/refunds", auth, async (req, res) => {

  try {

    let sql = `
      SELECT
        r.refund_id,
        r.txn_id,
        r.reason,
        r.approval_status,
        r.admin_note,
        TO_CHAR(
          r.requested_at,
          'DD Mon YYYY'
        ) AS requested_at,
        t.amount,
        u.full_name AS requested_by_name
      FROM REFUND_REQUEST r
      JOIN TRANSACTION_HISTORY t
        ON r.txn_id = t.txn_id
      JOIN USERS u
        ON r.requested_by = u.user_id
    `;

    const binds = {};

    if (req.user.role === "USER") {

      sql += `
        WHERE r.requested_by = :userId
      `;

      binds.userId = req.user.userId;

    } else if (req.user.role === "ADMIN") {

      sql += `
        WHERE EXISTS (
          SELECT 1
          FROM WALLET w
          WHERE w.wallet_id = t.wallet_id
            AND w.admin_id = :adminId
        )
      `;

      binds.adminId = req.user.userId;

    } else if (req.user.role !== "AUDITOR") {

      return res.status(403).json({
        error: "Not authorized"
      });
    }

    sql += `
      ORDER BY r.requested_at DESC
    `;

    const result = await query(sql, binds);

    res.json(result.rows);

  } catch (err) {

    res.status(500).json({
      error: err.message
    });

  }
});


// ============================================================
// 7. REQUEST REFUND
// ============================================================

app.post("/api/refund/request", auth, allowRoles("USER"), async (req, res) => {

  const {
    txnId,
    reason
  } = req.body;

  if (!txnId || !reason) {
    return res.status(400).json({
      error: "txnId and reason are required"
    });
  }

  try {

    const result = await callPackage(
      `BEGIN
         wallet_ops.request_refund(
           p_txn_id       => :txn_id,
           p_requested_by => :requested_by,
           p_reason       => :reason,
           p_refund_id    => :refund_id,
           p_status       => :status,
           p_message      => :message
         );
       END;`,
      {
        txn_id: Number(txnId),
        requested_by: req.user.userId,
        reason,

        refund_id: {
          dir: oracledb.BIND_OUT,
          type: oracledb.NUMBER
        },

        status: {
          dir: oracledb.BIND_OUT,
          type: oracledb.STRING,
          maxSize: 20
        },

        message: {
          dir: oracledb.BIND_OUT,
          type: oracledb.STRING,
          maxSize: 400
        }
      }
    );

    res.json({
      refundId: result.outBinds.refund_id,
      status: result.outBinds.status,
      message: result.outBinds.message
    });

  } catch (err) {

    res.status(500).json({
      error: err.message
    });

  }
});


// ============================================================
// 8. PROCESS REFUND
// ============================================================

app.post(
  "/api/refund/process",
  auth,
  allowRoles("ADMIN"),
  async (req, res) => {

    const {
      refundId,
      decision,
      note
    } = req.body;

    try {

      const result = await callPackage(
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
          admin_id: req.user.userId,
          decision,
          note: note || "",

          status: {
            dir: oracledb.BIND_OUT,
            type: oracledb.STRING,
            maxSize: 20
          },

          message: {
            dir: oracledb.BIND_OUT,
            type: oracledb.STRING,
            maxSize: 400
          }
        }
      );

      res.json({
        status: result.outBinds.status,
        message: result.outBinds.message
      });

    } catch (err) {

      res.status(500).json({
        error: err.message
      });

    }
  }
);


// ============================================================
// 9. ADMIN WALLET MANAGEMENT
// ============================================================

app.get(
  "/api/wallets",
  auth,
  allowRoles("ADMIN"),
  async (req, res) => {

    try {

      const result = await query(
        `SELECT *
         FROM VW_WALLET_SUMMARY
         WHERE admin_id = :adminId
         ORDER BY user_id`,
        {
          adminId: req.user.userId
        }
      );

      res.json(result.rows);

    } catch (err) {

      res.status(500).json({
        error: err.message
      });

    }
  }
);


// ============================================================
// 10. WALLET STATUS + SPENDING LIMITS
// ============================================================

app.post(
  "/api/wallet/status",
  auth,
  allowRoles("ADMIN"),
  async (req, res) => {

    const {
      walletId,
      action,
      reason,
      dailyLimit,
      monthlyLimit,
      perTxnLimit
    } = req.body;

    try {

      if (action === "SET_LIMITS") {

        const result = await callPackage(
          `BEGIN
             wallet_ops.set_spending_limits(
               p_wallet_id     => :wallet_id,
               p_admin_id      => :admin_id,
               p_daily_limit   => :daily_limit,
               p_monthly_limit => :monthly_limit,
               p_per_txn_limit => :per_txn_limit,
               p_status        => :status,
               p_message       => :message
             );
           END;`,
          {
            wallet_id: Number(walletId),
            admin_id: req.user.userId,
            daily_limit: Number(dailyLimit),
            monthly_limit: Number(monthlyLimit),
            per_txn_limit: Number(perTxnLimit),

            status: {
              dir: oracledb.BIND_OUT,
              type: oracledb.STRING,
              maxSize: 20
            },

            message: {
              dir: oracledb.BIND_OUT,
              type: oracledb.STRING,
              maxSize: 400
            }
          }
        );

        return res.json({
          status: result.outBinds.status,
          message: result.outBinds.message
        });
      }


      const result = await callPackage(
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
          admin_id: req.user.userId,
          action,
          reason: reason || "",

          status: {
            dir: oracledb.BIND_OUT,
            type: oracledb.STRING,
            maxSize: 20
          },

          message: {
            dir: oracledb.BIND_OUT,
            type: oracledb.STRING,
            maxSize: 400
          }
        }
      );

      res.json({
        status: result.outBinds.status,
        message: result.outBinds.message
      });

    } catch (err) {

      res.status(500).json({
        error: err.message
      });

    }
  }
);


// ============================================================
// 11. AUDIT LOG
// ============================================================

app.get(
  "/api/audit",
  auth,
  allowRoles("ADMIN", "AUDITOR"),
  async (req, res) => {

    try {

      const result = await query(
        `SELECT *
         FROM VW_AUDIT_DETAIL
         ORDER BY audit_id DESC
         FETCH FIRST 100 ROWS ONLY`
      );

      res.json(result.rows);

    } catch (err) {

      res.status(500).json({
        error: err.message
      });

    }
  }
);


// ============================================================
// HEALTH CHECK
// Not counted as one of the 11 application APIs.
// ============================================================

app.get("/api/health", async (req, res) => {

  try {

    await query("SELECT 1 FROM dual");

    res.json({
      ok: true
    });

  } catch (err) {

    res.status(503).json({
      ok: false,
      message: err.message
    });

  }
});


// ============================================================
// START SERVER
// ============================================================

async function start() {

  pool = await oracledb.createPool({
    ...db,
    poolMin: 1,
    poolMax: 10,
    poolIncrement: 1
  });

  const PORT = process.env.PORT || 3000;

  app.listen(PORT, () => {
    console.log(
      `PandaPay API running on port ${PORT}`
    );
  });
}


async function shutdown() {

  if (pool) {
    await pool.close(10);
  }

  process.exit(0);
}


process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);


start().catch(err => {

  console.error(
    "Failed to start:",
    err
  );

  process.exit(1);

});
