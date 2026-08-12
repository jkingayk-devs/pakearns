-- 003_rls_and_seed.sql
-- V8.1: RLS, uniqueness, public event/task reads, and non-fake seed data.
alter table public.profiles enable row level security;
alter table public.wallets enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.events enable row level security;
alter table public.tasks enable row level security;
alter table public.task_completions enable row level security;
alter table public.referrals enable row level security;
alter table public.withdrawals enable row level security;
alter table public.admin_users enable row level security;
alter table public.audit_logs enable row level security;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles for select using(auth.uid()=id or public.is_admin());

drop policy if exists wallets_select_own on public.wallets;
create policy wallets_select_own on public.wallets for select using(auth.uid()=user_id or public.is_admin());

drop policy if exists wallet_tx_select_own on public.wallet_transactions;
create policy wallet_tx_select_own on public.wallet_transactions for select using(auth.uid()=user_id or public.is_admin());

drop policy if exists events_public_read on public.events;
create policy events_public_read on public.events for select using((active=true and starts_at is not null and ends_at is not null and now()>=starts_at and now()<ends_at) or public.is_admin());

drop policy if exists tasks_public_read on public.tasks;
create policy tasks_public_read on public.tasks for select using((auth.uid() is not null and active=true) or public.is_admin());

drop policy if exists completions_select_own on public.task_completions;
create policy completions_select_own on public.task_completions for select using(auth.uid()=user_id or public.is_admin());

drop policy if exists referrals_select_own on public.referrals;
create policy referrals_select_own on public.referrals for select using(auth.uid()=referrer_id or auth.uid()=referred_id or public.is_admin());

drop policy if exists withdrawals_select_own on public.withdrawals;
create policy withdrawals_select_own on public.withdrawals for select using(auth.uid()=user_id or public.is_admin());

drop policy if exists admin_users_self on public.admin_users;
create policy admin_users_self on public.admin_users for select using(auth.uid()=user_id);

drop policy if exists audit_admin_read on public.audit_logs;
create policy audit_admin_read on public.audit_logs for select using(public.is_admin());

-- no client INSERT/UPDATE/DELETE policies on financial tables.
-- Financial mutations happen only through security-definer RPCs.

insert into public.events(slug,title,description,active,starts_at,ends_at,config)
values
('independence-day','Pakistan Independence Day','14 August Pakistan Independence Day event',true,'2026-08-12 00:00:00+05','2026-08-15 00:00:00+05','{"language":"en-ur","max_withdrawal_pkr":1500,"verified_referrals_required":1000}'::jsonb),
('eid','Eid','Seasonal Eid event. Activate and configure dates before publishing.',false,null,null,'{"language":"en-ur"}'::jsonb),
('eid-ul-fitr','Eid ul Fitr','Seasonal Eid ul Fitr event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'::jsonb),
('eid-ul-adha','Eid ul Adha','Seasonal Eid ul Adha event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'::jsonb),
('ramadan','Ramadan','Seasonal Ramadan event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'::jsonb),
('pakistan-day','Pakistan Day','23 March event',false,null,null,'{}'),
('labour-day','Labour Day','1 May event',false,null,null,'{}'),
('defence-day','Defence Day','6 September event',false,null,null,'{}'),
('iqbal-day','Iqbal Day','9 November event',false,null,null,'{}'),
('quaid-e-azam-day','Quaid-e-Azam Day','25 December event',false,null,null,'{}')
on conflict(slug) do update set title=excluded.title,description=excluded.description;

insert into public.tasks(type,title,description,reward_pkr,daily_limit,active,config)
select 'daily_spin','Daily Spin','One server-controlled daily reward. Reward is generated on the server.',0,1,true,'{}'
where not exists(select 1 from public.tasks where type='daily_spin');

-- Intentionally no rewardable watch/offer/referral tasks are seeded.
-- Those tasks require an actual verification implementation before activation.


-- Prevent multiple unresolved withdrawal reservations for one user even under races.
create unique index if not exists withdrawals_one_open_per_user_idx
on public.withdrawals(user_id)
where status in ('pending','approved');

-- Public clients can only read verified rewardable task definitions. Admins can read all.
drop policy if exists tasks_public_read on public.tasks;
create policy tasks_public_read on public.tasks for select
using ((auth.uid() is not null and active=true and type='daily_spin') or public.is_admin());

-- Public event reads are restricted to events currently within their configured window.
drop policy if exists events_public_read on public.events;
create policy events_public_read on public.events for select
using ((active=true and starts_at is not null and ends_at is not null and now()>=starts_at and now()<ends_at) or public.is_admin());

-- No direct client writes to referral verification, wallet state, withdrawals, ledger, or audit records.

DO $$ BEGIN
  ALTER TABLE public.referrals ADD CONSTRAINT referrals_no_self CHECK (referrer_id<>referred_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
