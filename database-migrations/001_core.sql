-- 001_core.sql
create extension if not exists pgcrypto;

do $$ begin
  create type public.task_type as enum ('daily_spin','watch_content','referral','event','offer');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.withdrawal_status as enum ('pending','approved','paid','rejected','refunded');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check(username ~ '^[A-Za-z0-9_]{3,30}$'),
  referral_code text not null unique check(referral_code ~ '^PK[A-Z0-9]{8}$'),
  verified_referrals integer not null default 0 check(verified_referrals>=0),
  account_status text not null default 'active' check(account_status in ('active','suspended','closed')),
  created_at timestamptz not null default now()
);

create table if not exists public.wallets(
  user_id uuid primary key references public.profiles(id) on delete cascade,
  balance_pkr numeric(12,2) not null default 0 check(balance_pkr>=0),
  reserved_pkr numeric(12,2) not null default 0 check(reserved_pkr>=0),
  total_earned_pkr numeric(12,2) not null default 0 check(total_earned_pkr>=0),
  updated_at timestamptz not null default now()
);


-- Upgrade compatibility for the earlier V7 schema. These ALTERs preserve existing user data.
do $$ begin
  alter type public.withdrawal_status add value if not exists 'refunded';
exception when undefined_object then null; end $$;

alter table if exists public.profiles add column if not exists account_status text not null default 'active';
do $$ begin
  alter table public.profiles add constraint profiles_account_status_check check(account_status in ('active','suspended','closed'));
exception when duplicate_object then null; end $$;
alter table if exists public.referrals add column if not exists status text;
alter table if exists public.referrals add column if not exists verification_reason text;
alter table if exists public.referrals add column if not exists verified_at timestamptz;
update public.referrals set status=case when coalesce(verified,false) then 'verified' else 'pending' end where status is null;
alter table if exists public.referrals alter column status set default 'pending';
alter table if exists public.referrals alter column status set not null;
alter table if exists public.wallets add column if not exists reserved_pkr numeric(12,2) not null default 0;
alter table if exists public.wallets add column if not exists total_earned_pkr numeric(12,2) not null default 0;

alter table if exists public.task_completions add column if not exists claim_day date;
update public.task_completions set claim_day=coalesce(claim_day,completed_at::date) where claim_day is null;
alter table if exists public.task_completions alter column claim_day set not null;

alter table if exists public.withdrawals add column if not exists admin_notes text;
alter table if exists public.withdrawals add column if not exists payment_reference text;
alter table if exists public.withdrawals add column if not exists approved_at timestamptz;
alter table if exists public.withdrawals add column if not exists rejected_at timestamptz;
alter table if exists public.withdrawals add column if not exists refunded_at timestamptz;

create table if not exists public.wallet_transactions(
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete restrict,
  transaction_type text not null check(transaction_type in(
    'daily_reward','task_reward','referral_reward','withdrawal_hold',
    'withdrawal_paid','withdrawal_refund','admin_adjustment','reversal'
  )),
  amount_pkr numeric(12,2) not null,
  available_delta_pkr numeric(12,2) not null default 0,
  reserved_delta_pkr numeric(12,2) not null default 0,
  total_earned_delta_pkr numeric(12,2) not null default 0,
  balance_before_pkr numeric(12,2) not null,
  balance_after_pkr numeric(12,2) not null,
  reserved_before_pkr numeric(12,2) not null,
  reserved_after_pkr numeric(12,2) not null,
  reference_type text,
  reference_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists wallet_tx_user_created_idx on public.wallet_transactions(user_id,created_at desc);

create table if not exists public.events(
  id bigint generated always as identity primary key,
  slug text not null unique,
  title text not null,
  description text,
  active boolean not null default false,
  starts_at timestamptz,
  ends_at timestamptz,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check(ends_at is null or starts_at is null or ends_at>starts_at)
);

create table if not exists public.tasks(
  id bigint generated always as identity primary key,
  event_id bigint references public.events(id) on delete cascade,
  type public.task_type not null,
  title text not null,
  description text,
  reward_pkr numeric(10,2) not null default 0 check(reward_pkr>=0),
  daily_limit integer not null default 1 check(daily_limit>0),
  active boolean not null default true,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists tasks_active_idx on public.tasks(active,event_id);

create table if not exists public.task_completions(
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  task_id bigint not null references public.tasks(id) on delete restrict,
  claim_day date not null,
  reward_pkr numeric(10,2) not null default 0 check(reward_pkr>=0),
  metadata jsonb not null default '{}'::jsonb,
  completed_at timestamptz not null default now(),
  unique(user_id,task_id,claim_day)
);
create index if not exists task_completions_user_idx on public.task_completions(user_id,completed_at desc);

create table if not exists public.referrals(
  id bigint generated always as identity primary key,
  referrer_id uuid not null references public.profiles(id) on delete restrict,
  referred_id uuid not null unique references public.profiles(id) on delete cascade,
  referral_code text not null,
  status text not null default 'pending' check(status in('pending','verified','rejected')),
  verification_reason text,
  created_at timestamptz not null default now(),
  verified_at timestamptz,
  check(referrer_id<>referred_id)
);
create index if not exists referrals_referrer_status_idx on public.referrals(referrer_id,status);

create table if not exists public.withdrawals(
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete restrict,
  amount_pkr numeric(10,2) not null check(amount_pkr>=100 and amount_pkr<=1500),
  method text not null check(method in('easypaisa','jazzcash','bank')),
  destination text not null check(length(destination) between 3 and 160),
  status public.withdrawal_status not null default 'pending',
  admin_notes text,
  payment_reference text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  approved_at timestamptz,
  rejected_at timestamptz,
  paid_at timestamptz,
  refunded_at timestamptz
);
create index if not exists withdrawals_user_created_idx on public.withdrawals(user_id,created_at desc);
create index if not exists withdrawals_status_idx on public.withdrawals(status,created_at);

create table if not exists public.admin_users(
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.audit_logs(
  id bigint generated always as identity primary key,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  target_type text,
  target_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists audit_logs_created_idx on public.audit_logs(created_at desc);
create index if not exists audit_logs_actor_idx on public.audit_logs(actor_user_id,created_at desc);

create or replace function public.prevent_ledger_mutation()
returns trigger language plpgsql as $$
begin raise exception 'wallet transaction ledger is immutable'; end $$;

drop trigger if exists wallet_transactions_immutable on public.wallet_transactions;
create trigger wallet_transactions_immutable before update or delete on public.wallet_transactions
for each row execute function public.prevent_ledger_mutation();
