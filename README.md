# 🐼 PandaPay — Digital Wallet System

> A full-stack digital wallet application built with **Node.js + Express** on the backend and **Oracle Database XE** doing the heavy lifting where it matters — business logic, integrity, and audit trails.

---

## What It Does

PandaPay lets users hold a wallet balance, send money, top up, and withdraw — all within enforced daily and monthly spending limits. Admins can freeze wallets and process refunds. Every state-changing action is captured in an immutable audit log.

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
| `WALLET` | One wallet per user — balance, status (`ACTIVE`/`FROZEN`), timestamps |
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

Validation enforced inside Oracle (not the app layer):
- Balance cannot go below zero (`CHECK` constraint + `trg_balance_guard` trigger)
- Spending limits checked before every debit
- Three consecutive failures auto-freeze the wallet (`trg_auto_freeze`)
- Transaction status transitions follow a strict state machine (`trg_txn_state_machine`)
- Audit log rows are immutable — no `UPDATE` or `DELETE` allowed (`trg_audit_immutable`)

---

## REST API

### Wallet

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/wallet/:userId` | Wallet summary — balance, limits, status |
| `GET` | `/api/wallet/:walletId/spent` | Live daily and monthly spend totals |
| `GET` | `/api/wallets` | All wallets (admin) |
| `POST` | `/api/wallet/status` | Freeze or unfreeze a wallet |

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

### Misc

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/audit` | Last 100 audit log entries |
| `GET` | `/api/health` | DB connectivity check |

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

> The Oracle connection is pre-configured to connect as `system / 12345` on `localhost:1521/XEPDB1`. Update the `db` object in `server.js` if your credentials differ.

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

**Authors:** Barleen Kaur · Ayush Vaibhav · Kunjal Syal

---

## License

ISC
