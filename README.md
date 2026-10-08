#  Digital Wallet System

> A full-stack digital wallet application built with **Node.js + Express** on the backend and **Oracle Database XE** doing the heavy lifting where it matters — business logic, integrity, and audit trails.

---

## What It Does

PandaPay models an ADMIN-managed wallet system: an organization/parent account loads funds for USER wallets, sets spending limits, can freeze wallets, and approves refunds. USERS can spend or transfer money within enforced per-transaction, daily, and monthly limits. AUDITORS can review the immutable audit trail.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Backend | Node.js, Express 5 |
| Database | Oracle Database XE (XEPDB1) |
| DB Driver | `oracledb` v6 |
| Frontend | Vanilla HTML/CSS/JS (`index.html`) |

---

## Project Structure

```
pandapay/
├── server.js          # Express API — thin HTTP layer, delegates to Oracle
├── index.html         # Frontend UI
├── database.sql       # Complete schema, seed data, views, package, triggers
└── package.json
```

---

## Database Architecture

The real brains of PandaPay live inside Oracle. The Node.js server is intentionally thin — it validates HTTP input, calls Oracle, and forwards the result.

### Tables

| Table | Purpose |
|---|---|
| `ROLES` | Three roles: `USER`, `ADMIN`, `AUDITOR` |
| `USERS` | Registered users with role, status, and hashed password |
| `WALLET` | One wallet per user — assigned admin, balance, status (`ACTIVE`/`FROZEN`), timestamps |
| `SPENDING_LIMIT` | Per-wallet daily and monthly caps |
| `TRANSACTION_HISTORY` | Every transaction with type, amount, status, and reference |
| `REFUND_REQUEST` | Refund submissions pending admin review |
| `AUDIT_LOG` | Append-only log of every significant event |

### Views

- `VW_WALLET_SUMMARY` — balance, limits, and status joined for one user
- `VW_TXN_HISTORY` — enriched transaction list with user info
- `VW_AUDIT_DETAIL` — human-readable audit feed for the admin panel

### Package: `wallet_ops`

All business logic is encapsulated in a single PL/SQL package:

```
wallet_ops.do_transaction(...)     -- credit, debit, transfer — fully validated
wallet_ops.handle_refund(...)      -- approve or reject a pending refund request
wallet_ops.set_wallet_status(...)  -- freeze or unfreeze a wallet
wallet_ops.daily_spent(...)        -- live daily spend total for a wallet
wallet_ops.monthly_spent(...)      -- live monthly spend total for a wallet
```

Validation enforced inside Oracle (not only the app layer):
- Only an ADMIN assigned to a wallet can load money, change limits, freeze/unfreeze, or approve its refunds
- A USER can spend/transfer only from their own managed wallet
- Balance cannot go below zero (`CHECK` constraint + `trg_balance_guard` trigger)
- Spending limits are checked before every debit/transfer
- Failed attempts are recorded without changing the balance; three consecutive failures auto-freeze the wallet
- Transfer wallets are locked in deterministic order to reduce deadlock risk
- Transaction status transitions follow a strict state machine (`trg_txn_state_machine`)
- Audit log rows are immutable — no `UPDATE` or `DELETE` allowed (`trg_audit_immutable`)

---

## REST API

### Wallet

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/login` | Authenticate a user and return a signed session token |
| `GET` | `/api/wallet/:userId` | Wallet summary — balance, limits, status |
| `GET` | `/api/wallet/:walletId/spent` | Live daily and monthly spend totals |
| `GET` | `/api/wallets` | All wallets (admin) |
| `POST` | `/api/wallet/status` | Freeze/unfreeze a wallet or update its spending limits |

### Transactions

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/transaction` | Execute a transaction (credit/debit/transfer) |
| `GET` | `/api/transactions/:walletId` | Full transaction history for a wallet |

### Refunds

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/refund/request` | Submit a refund request |
| `POST` | `/api/refund/process` | Admin approves or rejects a refund |
| `GET` | `/api/refunds` | All refund requests |

### Audit

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/audit` | Last 100 audit log entries |

> The deployment health check remains available at `/api/health`; it is operational infrastructure and is not counted in the 11 application REST APIs listed above.

---

## Getting Started

### Prerequisites

- [Node.js](https://nodejs.org/) v18+
- Oracle Database XE running locally (default port `1521`, service `XEPDB1`)

### Setup

```bash
# 1. Install dependencies
npm install

# 2. Load the schema into Oracle
#    Open database.sql in SQL Developer and run it (F5)
#    This creates all tables, sequences, views, the wallet_ops package, and triggers

# 3. Start the server
npm start
# → http://localhost:3000
```

> Configure `DB_USER`, `DB_PASSWORD`, `DB_CONNECT_STRING`, and `APP_SECRET` as environment variables. Do not commit database credentials or the application secret.

---

## Example: Creating a Transaction

```http
POST /api/transaction
Content-Type: application/json

{
  "walletId": 1,
  "txnType": "DEBIT",
  "amount": 250.00,
  "description": "Coffee shop",
  "initiatedBy": 1001,
  "recipientId": null
}
```

Response:
```json
{
  "txnId": 42,
  "status": "SUCCESS",
  "message": "Transaction completed. Ref: TXN-A3F9K2"
}
```

---

## Academic Context

Built as a Database Management Systems project at **Thapar Institute of Engineering and Technology, Patiala** (UCS310, Jan–May 2026).

**Authors:**  Kunjal Syal  

---

## License

ISC
