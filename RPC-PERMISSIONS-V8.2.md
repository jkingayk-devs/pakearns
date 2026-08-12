# PakCash V8.2 RPC permission matrix

The browser receives only the public/anon Supabase key. Sensitive functions are deliberately not executable by `anon` or `public`.

| Function | Anonymous | Authenticated | Admin | SECURITY DEFINER | Purpose |
|---|---|---|---|---|---|
| `is_admin()` | Denied | Allowed | Allowed | Yes | Server-side admin membership check |
| `audit(...)` | Denied | Denied | Internal only | Yes | Internal append-only audit writer |
| `handle_new_user()` | Denied | Denied | Trigger only | Yes | Auth-user trigger for profile/wallet/referral attribution |
| `apply_wallet_tx(...)` | Denied | Denied | Internal only | Yes | Internal atomic wallet/ledger mutation |
| `claim_daily_spin()` | Denied | Allowed | Allowed, subject to normal user rules | Yes | Authenticated daily reward |
| `request_withdrawal(...)` | Denied | Allowed | Allowed, subject to normal user rules | Yes | Authenticated withdrawal request |
| `admin_verify_referral(...)` | Denied | Allowed only when caller is admin | Yes | Yes | Referral verification |
| `admin_approve_withdrawal(...)` | Denied | Allowed only when caller is admin | Yes | Yes | Withdrawal approval |
| `admin_reject_withdrawal(...)` | Denied | Allowed only when caller is admin | Yes | Yes | Withdrawal rejection |
| `admin_refund_withdrawal(...)` | Denied | Allowed only when caller is admin | Yes | Yes | Refund after rejection |
| `admin_mark_withdrawal_paid(...)` | Denied | Allowed only when caller is admin | Yes | Yes | Final payment state |
| `admin_set_user_status(...)` | Denied | Allowed only when caller is admin | Yes | Yes | Active/suspended/closed status |
| `admin_adjust_wallet(...)` | Denied | Allowed only when caller is admin | Yes | Yes | Audited manual correction |
| `admin_upsert_task(...)` | Denied | Allowed only when caller is admin | Yes | Yes | Task configuration |
| `admin_set_event(...)` | Denied | Allowed only when caller is admin | Yes | Yes | Event configuration |
| `reconcile_wallet(...)` | Denied | Own user only, or admin | Admin for other users | Yes | Wallet/ledger reconciliation |
| `reconcile_referrals(...)` | Denied | Own user only, or admin | Admin for other users | Yes | Referral-count reconciliation |
| `reconcile_withdrawals(...)` | Denied | Own user only, or admin | Admin for other users | Yes | Withdrawal reservation reconciliation |

`public` is explicitly revoked for the sensitive functions. `authenticated` grants are applied in migrations 002 and 005.

## Important distinction

A function being executable by `authenticated` does **not** make it an admin function. Every admin RPC calls `is_admin()` inside the security-definer function before changing protected state.
