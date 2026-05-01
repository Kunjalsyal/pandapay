Copy-paste this whole thing into `README.md`:

````md
# PandaPay

PandaPay is a DBMS project based on a digital wallet system with transaction rules and audit logs.

The main focus of this project is the Oracle database part. The SQL/PLSQL code handles wallet balance updates, transaction validation, spending limits, refund processing, wallet status changes, and audit logging. A simple Node.js backend and HTML frontend are added only to test and display the database operations through a dashboard.

## Tech Used

- Oracle Database XE
- SQL and PL/SQL
- Node.js
- Express.js
- HTML, CSS, JavaScript
- oracledb Node.js driver

## Main Features

- User wallet with balance and status
- Credit, debit, transfer, and refund transactions
- Daily, monthly, and per-transaction spending limits
- Admin refund approval and rejection
- Wallet freeze and unfreeze option
- Audit logs for important operations
- Frontend dashboard connected to Oracle through Node.js APIs

## Project Files

```text
database.sql        Oracle tables, constraints, triggers, views, package and sample data
server.js           Node.js backend for connecting the frontend with Oracle
index.html          Frontend dashboard
package.json        Node dependencies
.env                Local database credentials, not uploaded to GitHub
````

## How to Run

Run the database script in Oracle using SQLPlus or SQL Developer:

```sql
@"C:\path\to\database.sql"
```

Install the Node dependencies:

```bash
npm install
```

Create a `.env` file in the project folder:

```env
DB_USER=system
DB_PASSWORD=your_oracle_password
DB_CONNECT_STRING=localhost:1521/XEPDB1
PORT=3000
```

Start the server:

```bash
node server.js
```

Open the frontend in the browser:

```text
http://localhost:3000/index.html
```

## Note

The `.env` file is not included in this repository because it contains local database credentials. The project will run only after Oracle Database is installed, the SQL script is executed, and the correct `.env` values are added.

```
```
