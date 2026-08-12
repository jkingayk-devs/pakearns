# PakCash V8.2 Setup

## 1. Deploy the files

For Cloudflare Workers Static Assets, use the included `worker.js` and `wrangler.toml`.

```bash
npx wrangler login
npx wrangler deploy
```

For Cloudflare Pages, the `_headers` file is included as well. Do not deploy both systems in a way that creates competing asset roots.

## 2. Supabase project

The frontend contains only the public Supabase URL and anon/publishable key. Never put a service-role/secret key into this repository.

Open the Supabase SQL Editor and run migrations in this order:

1. `database-migrations/001_core.sql`
2. `database-migrations/002_security_and_functions.sql`
3. `database-migrations/003_rls_and_seed.sql`
4. `database-migrations/004_v81_reconciliation.sql`
5. `database-migrations/005_v82_product_hardening.sql`

### Existing V7/V8 data

`005_v82_product_hardening.sql` is intentionally conservative:

- Existing wallets are preserved.
- Existing ledger history is preserved.
- If a wallet has no ledger, an auditable `opening_balance` entry is created.
- If an existing ledger disagrees with the wallet, migration stops instead of silently changing money.
- Existing referral counts are recalculated from referral rows.
- Multiple active daily-spin tasks cause migration failure rather than selecting one arbitrarily.

Back up the database before running migrations.

## 3. Authentication

In Supabase:

**Authentication → Providers → Email**

Enable email/password authentication.

For production, enable email confirmation. The referral verification engine requires the referred user's email to be confirmed before an admin can verify the referral.

Configure the Site URL to the production origin, for example:

`https://pakcash.siteo.workers.dev`

Configure the password-recovery redirect URL:

`https://pakcash.siteo.workers.dev/reset-password.html`

The UI requires passwords of at least 10 characters. Configure Supabase Auth's password policy to at least the same strength in the dashboard.

## 4. Create the first admin

Create a normal account through `/register.html` and confirm its email.

Then copy that user's UUID from **Authentication → Users** and run in the SQL Editor:

```sql
insert into public.admin_users(user_id)
values ('YOUR_AUTH_USER_UUID')
on conflict (user_id) do nothing;
```

Never put an admin flag in frontend JavaScript.

## 5. Verify the database

Run:

```sql
select * from public.reconcile_wallet('YOUR_USER_UUID');
select * from public.reconcile_referrals('YOUR_USER_UUID');
select * from public.reconcile_withdrawals('YOUR_USER_UUID');
```

All should report a balanced state for a healthy account.

Check active daily spin:

```sql
select id,type,title,active,config
from public.tasks
where type='daily_spin' and active=true;
```

Exactly one row should be returned.

## 6. Platform configuration

Current authoritative values are stored in `public.app_settings`:

- `withdrawal_min_pkr`
- `withdrawal_max_pkr`
- `daily_withdrawal_limit_pkr`
- `verified_referrals_required`
- `daily_spin_min_pkr`
- `daily_spin_max_pkr`

There is intentionally no public client-side settings editor.

Changes should be performed through a future audited admin settings RPC or directly by a trusted database operator.

## 7. Events

Existing static event URLs are retained.

New events created by the admin use the shared route:

`/events/event.html?slug=your-event-slug`

Existing slugs cannot be changed after creation. This prevents published URLs from silently breaking.

An event is publicly active only when:

- `active = true`
- `starts_at` is present
- `ends_at` is present
- current time is within the configured interval

Eid events are seeded inactive. Configure their dates before activating them.

## 8. Advertising

Advertising is configured centrally in `js/ads.js`.

Ads do not create wallet rewards.

The current project does not implement rewarded-ad verification. Do not describe ordinary ad clicks/impressions as a reward task.

If an ad provider changes its approved embed code, update only the centralized ad configuration and review the CSP before deployment.

## 9. Support

A real public support contact is **not configured** in this package. Before production launch, configure a real support email or support URL in `support.html`.

Do not invent a support address.

## 10. Security

- No service-role key belongs in the frontend.
- Sensitive RPCs are not executable by anonymous users.
- Admin RPCs check `is_admin()` server-side.
- Financial tables have no direct client write policies.
- Wallet transactions are immutable.
- Wallet changes occur through trusted database functions.
- Security headers are applied by `worker.js` for Workers and `_headers` for Pages-style deployment.

## 11. Rate limiting / abuse controls

This build does not claim a custom application-level IP/device fingerprinting system.

Configure production protections through:

- Supabase Auth rate limits and abuse controls
- Cloudflare WAF/rate limiting for authentication and high-risk routes
- operational review of suspicious referral/withdrawal activity

Advanced fraud detection is an external operational requirement, not fabricated in the application.

## 12. Payment operations

PakCash V8.2 does not call Easypaisa, JazzCash, or bank APIs.

The admin `Mark paid` action records the external payment reference after the operator has actually made the payment.

Do not mark a withdrawal paid before the external payment has been completed.
