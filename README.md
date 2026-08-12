# PakCash V8.2

Production-oriented static frontend + Supabase/PostgreSQL backend for PakCash.

## Core rule

Only server-verified functionality can create rewards or move money.

Currently implemented reward engine:

- `daily_spin` — server-generated, atomic, once per Pakistan calendar day.

Not implemented as reward engines:

- `watch_content`
- `offer`
- `referral`
- `event`

Unsupported reward types cannot be activated by the admin RPC.

## Financial architecture

Wallet state is protected by PostgreSQL functions and an immutable `wallet_transactions` ledger.

Withdrawal lifecycle:

```text
pending → approved → paid
pending → rejected → refunded
approved → rejected → refunded
```

Funds are reserved when a withdrawal is requested. Payment removes the reservation only after the operator records payment. Rejection is refunded through a separate audited transaction.

## V8.2 documents

- `V8.2-FORENSIC-AUDIT.md`
- `V8.2-TEST-REPORT.md`
- `V8.2-CHANGELOG.md`
- `V8.2-SETUP.md`
- `RPC-PERMISSIONS-V8.2.md`

## Database migrations

Run in order:

1. `001_core.sql`
2. `002_security_and_functions.sql`
3. `003_rls_and_seed.sql`
4. `004_v81_reconciliation.sql`
5. `005_v82_product_hardening.sql`

Back up an existing production database before migration.

## Secrets

The browser may contain the public Supabase anon/publishable key. Never put a service-role/secret key in this project.

## Deployment

For Cloudflare Workers Static Assets, the repository includes:

- `worker.js`
- `wrangler.toml`

For Cloudflare Pages, `_headers` is also provided.

## Advertising

Ads are configured centrally in `js/ads.js` and are completely separate from financial rewards. Ordinary ad clicks, impressions, shares, or visits do not create wallet rewards.
