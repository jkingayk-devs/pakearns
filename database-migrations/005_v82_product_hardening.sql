-- 005_v82_product_hardening.sql
-- PakCash V8.2 forensic repairs, data-safe upgrade, authoritative settings, reconciliation, and hardened RPCs.

-- -----------------------------------------------------------------------------
-- 1. Authoritative platform settings. Values are server-side policy, not UI data.
-- -----------------------------------------------------------------------------
create table if not exists public.app_settings(
  key text primary key check(key ~ '^[a-z0-9_]+$'),
  value numeric(12,2) not null,
  updated_at timestamptz not null default now()
);

insert into public.app_settings(key,value) values
 ('withdrawal_min_pkr',100),
 ('withdrawal_max_pkr',1500),
 ('daily_withdrawal_limit_pkr',1500),
 ('verified_referrals_required',1000),
 ('daily_spin_min_pkr',1),
 ('daily_spin_max_pkr',5)
on conflict(key) do nothing;

alter table public.app_settings enable row level security;
drop policy if exists app_settings_public_read on public.app_settings;
create policy app_settings_public_read on public.app_settings for select using(true);

-- -----------------------------------------------------------------------------
-- 2. Safe upgrade of the immutable ledger for existing V7/V8 wallets.
--    Existing wallet state is never silently reset. If an existing ledger is
--    already present but disagrees with the wallet, migration aborts instead
--    of hiding the inconsistency.
-- -----------------------------------------------------------------------------
DO $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid='public.wallet_transactions'::regclass and contype='c' and pg_get_constraintdef(oid) ilike '%transaction_type%' loop
    execute format('alter table public.wallet_transactions drop constraint %I',c.conname);
  end loop;
end $$;

alter table public.wallet_transactions add constraint wallet_transactions_transaction_type_check check(transaction_type in(
 'opening_balance','daily_reward','task_reward','referral_reward','withdrawal_hold',
 'withdrawal_paid','withdrawal_refund','admin_adjustment','reversal'
));

DO $$
declare r record; lb numeric; lr numeric; le numeric;
begin
  for r in select w.user_id,w.balance_pkr,w.reserved_pkr,w.total_earned_pkr from public.wallets w loop
    select coalesce(sum(available_delta_pkr),0),coalesce(sum(reserved_delta_pkr),0),coalesce(sum(total_earned_delta_pkr),0)
      into lb,lr,le from public.wallet_transactions t where t.user_id=r.user_id;
    if not exists(select 1 from public.wallet_transactions t where t.user_id=r.user_id) then
      if r.balance_pkr<>0 or r.reserved_pkr<>0 or r.total_earned_pkr<>0 then
        insert into public.wallet_transactions(user_id,transaction_type,amount_pkr,available_delta_pkr,reserved_delta_pkr,total_earned_delta_pkr,balance_before_pkr,balance_after_pkr,reserved_before_pkr,reserved_after_pkr,reference_type,reference_id,metadata)
        values(r.user_id,'opening_balance',greatest(r.balance_pkr,0),r.balance_pkr,r.reserved_pkr,r.total_earned_pkr,0,r.balance_pkr,0,r.reserved_pkr,'migration','v7-v8-opening-balance',jsonb_build_object('source','existing_wallet_state'));
      end if;
    elsif lb<>r.balance_pkr or lr<>r.reserved_pkr or le<>r.total_earned_pkr then
      raise exception 'Wallet/ledger mismatch for user %; reconcile before completing V8.2 migration',r.user_id;
    end if;
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- 3. Username uniqueness must be case-insensitive. Existing conflicting data
--    is detected rather than silently rewritten.
-- -----------------------------------------------------------------------------
DO $$ begin
  if exists(select 1 from public.profiles group by lower(username) having count(*)>1) then
    raise exception 'Duplicate usernames differing only by case exist; resolve before V8.2 migration';
  end if;
end $$;
create unique index if not exists profiles_username_lower_uidx on public.profiles(lower(username));

-- -----------------------------------------------------------------------------
-- 4. Exactly one active daily-spin configuration.
-- -----------------------------------------------------------------------------
DO $$ begin
 if exists(select 1 from public.tasks where type='daily_spin' and active=true group by type having count(*)>1) then
   raise exception 'Multiple active daily-spin tasks exist; deactivate extras before completing V8.2 migration';
 end if;
end $$;


create unique index if not exists tasks_one_active_daily_spin_idx on public.tasks(type) where type='daily_spin' and active=true;

-- -----------------------------------------------------------------------------
-- 5. Reconciliation helpers. Read-only for normal users; admin may inspect any
--    user. Referral reconciliation reports drift without inventing rewards.
-- -----------------------------------------------------------------------------
create or replace function public.reconcile_wallet(p_user_id uuid)
returns table(user_id uuid,wallet_balance numeric,ledger_balance numeric,wallet_reserved numeric,ledger_reserved numeric,wallet_total_earned numeric,ledger_total_earned numeric,balanced boolean)
language sql stable security definer set search_path=pg_catalog,public
as $$
 select p_user_id,w.balance_pkr,coalesce(sum(t.available_delta_pkr),0),w.reserved_pkr,coalesce(sum(t.reserved_delta_pkr),0),w.total_earned_pkr,coalesce(sum(t.total_earned_delta_pkr),0),
 (w.balance_pkr=coalesce(sum(t.available_delta_pkr),0) and w.reserved_pkr=coalesce(sum(t.reserved_delta_pkr),0) and w.total_earned_pkr=coalesce(sum(t.total_earned_delta_pkr),0))
 from public.wallets w left join public.wallet_transactions t on t.user_id=w.user_id
 where w.user_id=p_user_id and (auth.uid()=p_user_id or public.is_admin()) group by w.user_id,w.balance_pkr,w.reserved_pkr,w.total_earned_pkr
$$;

create or replace function public.reconcile_referrals(p_user_id uuid)
returns table(user_id uuid,stored_verified integer,actual_verified bigint,balanced boolean)
language sql stable security definer set search_path=pg_catalog,public
as $$
 select p.id,p.verified_referrals,coalesce(count(r.id) filter(where r.status='verified'),0),p.verified_referrals=coalesce(count(r.id) filter(where r.status='verified'),0)
 from public.profiles p left join public.referrals r on r.referrer_id=p.id
 where p.id=p_user_id and (auth.uid()=p_user_id or public.is_admin()) group by p.id,p.verified_referrals
$$;

create or replace function public.reconcile_withdrawals(p_user_id uuid default null)
returns table(user_id uuid,open_count bigint,reserved_sum numeric,hold_ledger_sum numeric,balanced boolean)
language sql stable security definer set search_path=pg_catalog,public
as $$
 select u.id,count(w.id) filter(where w.status in('pending','approved')),coalesce(sum(w.amount_pkr) filter(where w.status in('pending','approved')),0),coalesce(sum(t.amount_pkr) filter(where t.transaction_type='withdrawal_hold'),0),
 true
 from public.profiles u left join public.withdrawals w on w.user_id=u.id left join public.wallet_transactions t on t.user_id=u.id
 where (p_user_id is null or u.id=p_user_id) and (auth.uid()=u.id or public.is_admin()) group by u.id
$$;

revoke all on function public.reconcile_wallet(uuid) from public,anon,authenticated;
revoke all on function public.reconcile_referrals(uuid) from public,anon,authenticated;
revoke all on function public.reconcile_withdrawals(uuid) from public,anon,authenticated;
grant execute on function public.reconcile_wallet(uuid) to authenticated;
grant execute on function public.reconcile_referrals(uuid) to authenticated;
grant execute on function public.reconcile_withdrawals(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 6. Hardened daily spin. Uses Pakistan calendar day and exactly one active task.
-- -----------------------------------------------------------------------------
create or replace function public.claim_daily_spin()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $$
declare uid uuid:=auth.uid(); tid bigint; reward numeric(10,2); min_reward numeric; max_reward numeric; claim_day date:=(now() at time zone 'Asia/Karachi')::date; active_count integer;
begin
 if uid is null then raise exception 'Not authenticated'; end if;
 if not exists(select 1 from public.profiles where id=uid and account_status='active') then raise exception 'Account is not active'; end if;
 select count(*) into active_count from public.tasks where type='daily_spin' and active=true;
 if active_count<>1 then raise exception 'Daily spin configuration is invalid'; end if;
 select id,coalesce((config->>'min_reward')::numeric,(select value from public.app_settings where key='daily_spin_min_pkr')),coalesce((config->>'max_reward')::numeric,(select value from public.app_settings where key='daily_spin_max_pkr'))
 into tid,min_reward,max_reward from public.tasks where type='daily_spin' and active=true limit 1;
 if min_reward is null or max_reward is null or min_reward<=0 or max_reward<min_reward or max_reward>100 then raise exception 'Invalid daily spin reward configuration'; end if;
 reward:=round((min_reward+random()*(max_reward-min_reward))::numeric,2);
 begin
  insert into public.task_completions(user_id,task_id,claim_day,reward_pkr,metadata) values(uid,tid,claim_day,reward,jsonb_build_object('source','daily_spin','claim_day',claim_day));
 exception when unique_violation then raise exception 'Daily spin already claimed'; end;
 perform public.apply_wallet_tx(uid,'daily_reward',reward,reward,0,reward,'task',tid::text,jsonb_build_object('task','daily_spin','claim_day',claim_day));
 perform public.audit('daily_reward','task',tid::text,jsonb_build_object('amount_pkr',reward,'claim_day',claim_day));
 return jsonb_build_object('reward_pkr',reward,'claim_day',claim_day,'next_eligible_at',((claim_day+1)::timestamp at time zone 'Asia/Karachi'));
end $$;

-- -----------------------------------------------------------------------------
-- 7. Authoritative withdrawal settings and referral verification.
-- -----------------------------------------------------------------------------
create or replace function public.request_withdrawal(p_amount numeric,p_method text,p_destination text)
returns public.withdrawals language plpgsql security definer set search_path=pg_catalog,public
as $$
declare uid uuid:=auth.uid();w public.wallets;v public.withdrawals;daily numeric;dest text;min_amt numeric;max_amt numeric;daily_limit numeric;required_refs integer;verified_count bigint;
begin
 if uid is null then raise exception 'Not authenticated'; end if;
 if not exists(select 1 from public.profiles where id=uid and account_status='active') then raise exception 'Account is not active'; end if;
 select value into min_amt from public.app_settings where key='withdrawal_min_pkr';select value into max_amt from public.app_settings where key='withdrawal_max_pkr';select value into daily_limit from public.app_settings where key='daily_withdrawal_limit_pkr';select value::integer into required_refs from public.app_settings where key='verified_referrals_required';
 if p_amount is null or p_amount<min_amt or p_amount>max_amt then raise exception 'Withdrawal amount is outside the configured limits'; end if;
 if p_method not in('easypaisa','jazzcash','bank') then raise exception 'Unsupported withdrawal method'; end if;
 dest:=trim(coalesce(p_destination,''));if dest~'[[:cntrl:]]' or length(dest)<3 or length(dest)>160 then raise exception 'Invalid destination'; end if;
 if p_method in('easypaisa','jazzcash') and dest !~ '^03[0-9]{9}$' then raise exception 'Mobile wallet destination must be 11 digits starting with 03'; end if;
 if p_method='bank' and dest !~ '^[A-Za-z0-9]{8,34}$' then raise exception 'Bank destination must be 8 to 34 letters or numbers'; end if;
 select count(*) into verified_count from public.referrals r join public.profiles rp on rp.id=r.referrer_id join auth.users au on au.id=r.referred_id join public.profiles rr on rr.id=r.referred_id where r.referrer_id=uid and r.status='verified' and rp.account_status='active' and rr.account_status='active' and au.email_confirmed_at is not null;
 if verified_count<required_refs then raise exception 'The configured verified-referral requirement has not been met'; end if;
 select * into w from public.wallets where user_id=uid for update;if not found then raise exception 'Wallet not found'; end if;if w.balance_pkr<p_amount then raise exception 'Insufficient available balance'; end if;
 select coalesce(sum(amount_pkr),0) into daily from public.withdrawals where user_id=uid and created_at>=date_trunc('day',now()) and status in('pending','approved','paid');
 if daily+p_amount>daily_limit then raise exception 'Daily withdrawal limit exceeded'; end if;
 if exists(select 1 from public.withdrawals where user_id=uid and status in('pending','approved')) then raise exception 'You already have a pending withdrawal'; end if;
 insert into public.withdrawals(user_id,amount_pkr,method,destination) values(uid,p_amount,p_method,dest) returning * into v;
 perform public.apply_wallet_tx(uid,'withdrawal_hold',p_amount,-p_amount,p_amount,0,'withdrawal',v.id::text,jsonb_build_object('method',p_method));
 perform public.audit('withdrawal_requested','withdrawal',v.id::text,jsonb_build_object('amount_pkr',p_amount,'method',p_method));return v;
end $$;

create or replace function public.admin_verify_referral(p_referral_id bigint,p_reason text)
returns void language plpgsql security definer set search_path=pg_catalog,public
as $$
declare r public.referrals; ref_status text; referred_status text; confirmed timestamptz;
begin
 if not public.is_admin() then raise exception 'Admin authorization required';end if;if length(trim(coalesce(p_reason,'')))<3 then raise exception 'Verification reason is required';end if;
 select * into r from public.referrals where id=p_referral_id for update;if not found then raise exception 'Referral not found';end if;if r.status='verified' then return;end if;
 select account_status into ref_status from public.profiles where id=r.referrer_id;select p.account_status,au.email_confirmed_at into referred_status,confirmed from public.profiles p join auth.users au on au.id=p.id where p.id=r.referred_id;
 if ref_status<>'active' then raise exception 'Referrer is not active';end if;if referred_status<>'active' or confirmed is null then raise exception 'Referred account is not eligible for verification';end if;
 update public.referrals set status='verified',verification_reason=trim(p_reason),verified_at=now() where id=p_referral_id;
 update public.profiles set verified_referrals=(select count(*) from public.referrals where referrer_id=r.referrer_id and status='verified') where id=r.referrer_id;
 perform public.audit('referral_verified','referral',r.id::text,jsonb_build_object('referrer_id',r.referrer_id,'reason',trim(p_reason)));end $$;

-- -----------------------------------------------------------------------------
-- 8. Admin adjustments do not pretend to be earned rewards.
-- -----------------------------------------------------------------------------
create or replace function public.admin_adjust_wallet(p_user_id uuid,p_amount numeric,p_reason text)
returns void language plpgsql security definer set search_path=pg_catalog,public
as $$
begin
 if not public.is_admin() then raise exception 'Admin authorization required';end if;if p_amount is null or round(p_amount,2)=0 then raise exception 'Adjustment cannot be zero';end if;if length(trim(coalesce(p_reason,'')))<5 or trim(p_reason)~'[[:cntrl:]]' then raise exception 'Reason is required';end if;
 perform public.apply_wallet_tx(p_user_id,'admin_adjustment',abs(round(p_amount,2)),round(p_amount,2),0,0,'admin_adjustment',p_user_id::text,jsonb_build_object('reason',trim(p_reason),'direction',case when p_amount>0 then 'credit' else 'debit' end));
 perform public.audit('wallet_adjusted','user',p_user_id::text,jsonb_build_object('amount_pkr',round(p_amount,2),'reason',trim(p_reason)));end $$;

-- -----------------------------------------------------------------------------
-- 9. Event slugs are immutable after creation; active events require dates.
-- -----------------------------------------------------------------------------
create or replace function public.admin_set_event(p_id bigint,p_slug text,p_title text,p_description text,p_active boolean,p_starts timestamptz,p_ends timestamptz,p_config jsonb)
returns public.events language plpgsql security definer set search_path=pg_catalog,public
as $$
declare v public.events;slug_clean text:=lower(trim(coalesce(p_slug,'')));title_clean text:=trim(coalesce(p_title,''));old_slug text;
begin
 if not public.is_admin() then raise exception 'Admin authorization required';end if;if slug_clean!~'^[a-z0-9]+(?:-[a-z0-9]+)*$' or length(slug_clean)>80 then raise exception 'Invalid event slug';end if;if length(title_clean)<2 or length(title_clean)>160 or title_clean~'[[:cntrl:]]' then raise exception 'Invalid event title';end if;if length(coalesce(p_description,''))>4000 or coalesce(p_description,'')~'[[:cntrl:]]' then raise exception 'Invalid event description';end if;if p_active and (p_starts is null or p_ends is null or p_ends<=p_starts) then raise exception 'Active event requires valid start and end dates';end if;if p_starts is not null and p_ends is not null and p_ends<=p_starts then raise exception 'End must be after start';end if;
 if p_id is null then insert into public.events(slug,title,description,active,starts_at,ends_at,config) values(slug_clean,title_clean,p_description,p_active,p_starts,p_ends,coalesce(p_config,'{}')) returning * into v;
 else select slug into old_slug from public.events where id=p_id;if old_slug is null then raise exception 'Event not found';end if;if old_slug<>slug_clean then raise exception 'Published event slugs cannot be changed';end if;update public.events set title=title_clean,description=p_description,active=p_active,starts_at=p_starts,ends_at=p_ends,config=coalesce(p_config,'{}') where id=p_id returning * into v;end if;
 perform public.audit('event_upserted','event',v.id::text,jsonb_build_object('active',v.active,'slug',v.slug));return v;
exception when unique_violation then raise exception 'Event slug already exists';end $$;

-- -----------------------------------------------------------------------------
-- 10. Re-apply deliberate grants after replacements.
-- -----------------------------------------------------------------------------
revoke all on function public.claim_daily_spin() from public,anon;grant execute on function public.claim_daily_spin() to authenticated;
revoke all on function public.request_withdrawal(numeric,text,text) from public,anon;grant execute on function public.request_withdrawal(numeric,text,text) to authenticated;
revoke all on function public.admin_verify_referral(bigint,text) from public,anon;grant execute on function public.admin_verify_referral(bigint,text) to authenticated;
revoke all on function public.admin_adjust_wallet(uuid,numeric,text) from public,anon;grant execute on function public.admin_adjust_wallet(uuid,numeric,text) to authenticated;
revoke all on function public.admin_set_event(bigint,text,text,text,boolean,timestamptz,timestamptz,jsonb) from public,anon;grant execute on function public.admin_set_event(bigint,text,text,text,boolean,timestamptz,timestamptz,jsonb) to authenticated;
revoke all on function public.reconcile_wallet(uuid) from public,anon;grant execute on function public.reconcile_wallet(uuid) to authenticated;
revoke all on function public.reconcile_referrals(uuid) from public,anon;grant execute on function public.reconcile_referrals(uuid) to authenticated;
revoke all on function public.reconcile_withdrawals(uuid) from public,anon;grant execute on function public.reconcile_withdrawals(uuid) to authenticated;

-- No direct writes to app_settings. Only authenticated admins should modify it
-- in a future dedicated RPC; this build intentionally has no client settings editor.
revoke insert,update,delete on public.app_settings from anon,authenticated;

-- Keep the cached verified_referrals field derived from the referral table.
create or replace function public.sync_verified_referral_count()
returns trigger language plpgsql security definer set search_path=pg_catalog,public
as $$
declare rid uuid;
begin
 rid:=coalesce(new.referrer_id,old.referrer_id);
 if rid is not null then
   update public.profiles set verified_referrals=(select count(*) from public.referrals where referrer_id=rid and status='verified') where id=rid;
 end if;
 return coalesce(new,old);
end $$;
drop trigger if exists referrals_sync_verified_count on public.referrals;
create trigger referrals_sync_verified_count after insert or update or delete on public.referrals for each row execute function public.sync_verified_referral_count();
revoke all on function public.sync_verified_referral_count() from public,anon,authenticated;

update public.profiles p set verified_referrals=(select count(*) from public.referrals r where r.referrer_id=p.id and r.status='verified');

-- Replace the earlier reconciliation query with non-multiplying correlated totals.
create or replace function public.reconcile_withdrawals(p_user_id uuid default null)
returns table(user_id uuid,wallet_reserved numeric,open_withdrawal_sum numeric,hold_ledger_net numeric,balanced boolean)
language sql stable security definer set search_path=pg_catalog,public
as $$
 select p.id,
        w.reserved_pkr,
        coalesce((select sum(amount_pkr) from public.withdrawals x where x.user_id=p.id and x.status in('pending','approved')),0),
        coalesce((select sum(available_delta_pkr*-1) from public.wallet_transactions t where t.user_id=p.id and t.transaction_type='withdrawal_hold'),0)
        -coalesce((select sum(amount_pkr) from public.wallet_transactions t where t.user_id=p.id and t.transaction_type in('withdrawal_paid','withdrawal_refund')),0),
        w.reserved_pkr=coalesce((select sum(amount_pkr) from public.withdrawals x where x.user_id=p.id and x.status in('pending','approved')),0)
        and coalesce((select sum(amount_pkr) from public.withdrawals x where x.user_id=p.id and x.status in('pending','approved')),0)=coalesce((select sum(available_delta_pkr*-1) from public.wallet_transactions t where t.user_id=p.id and t.transaction_type='withdrawal_hold'),0)-coalesce((select sum(amount_pkr) from public.wallet_transactions t where t.user_id=p.id and t.transaction_type in('withdrawal_paid','withdrawal_refund')),0)
 from public.profiles p join public.wallets w on w.user_id=p.id
 where (p_user_id is null or p.id=p_user_id) and (auth.uid()=p.id or public.is_admin())
$$;
revoke all on function public.reconcile_withdrawals(uuid) from public,anon,authenticated;
grant execute on function public.reconcile_withdrawals(uuid) to authenticated;


-- Harden task administration after app_settings exists.
create or replace function public.admin_upsert_task(
 p_id bigint,p_type public.task_type,p_title text,p_description text,p_reward numeric,p_daily_limit integer,p_active boolean,p_config jsonb,p_event_id bigint default null)
returns public.tasks language plpgsql security definer set search_path=pg_catalog,public
as $$
declare v public.tasks;cfg jsonb:=coalesce(p_config,'{}'::jsonb);mn numeric;mx numeric;
begin
 if not public.is_admin() then raise exception 'Admin authorization required';end if;if length(trim(coalesce(p_title,'')))<2 or length(trim(p_title))>120 or trim(p_title)~'[[:cntrl:]]' then raise exception 'Invalid task title';end if;if length(coalesce(p_description,''))>2000 or coalesce(p_description,'')~'[[:cntrl:]]' then raise exception 'Invalid task description';end if;if p_reward<0 or p_daily_limit<1 then raise exception 'Invalid task configuration';end if;
 if p_type='daily_spin' then
   if p_daily_limit<>1 or round(coalesce(p_reward,0),2)<>0 or p_event_id is not null then raise exception 'Daily spin must be global, limit 1, with server-generated reward';end if;
   mn:=coalesce((cfg->>'min_reward')::numeric,(select value from public.app_settings where key='daily_spin_min_pkr'));mx:=coalesce((cfg->>'max_reward')::numeric,(select value from public.app_settings where key='daily_spin_max_pkr'));
   if mn<=0 or mx<mn or mx>100 then raise exception 'Invalid daily spin reward configuration';end if;
 elsif p_active then raise exception 'This task type has no verified reward engine and cannot be activated'; end if;
 if p_id is null then insert into public.tasks(type,title,description,reward_pkr,daily_limit,active,config,event_id) values(p_type,trim(p_title),p_description,p_reward,p_daily_limit,p_active,cfg,p_event_id) returning * into v;
 else update public.tasks set type=p_type,title=trim(p_title),description=p_description,reward_pkr=p_reward,daily_limit=p_daily_limit,active=p_active,config=cfg,event_id=p_event_id where id=p_id returning * into v;if not found then raise exception 'Task not found';end if;end if;
 perform public.audit('task_upserted','task',v.id::text,jsonb_build_object('active',v.active,'type',v.type));return v;
end $$;
revoke all on function public.admin_upsert_task(bigint,public.task_type,text,text,numeric,integer,boolean,jsonb,bigint) from public,anon;grant execute on function public.admin_upsert_task(bigint,public.task_type,text,text,numeric,integer,boolean,jsonb,bigint) to authenticated;

-- Harden operator note fields against control-character/log injection.
create or replace function public.admin_approve_withdrawal(p_id bigint,p_notes text default null)
returns void language plpgsql security definer set search_path=pg_catalog,public
as $$
declare v public.withdrawals;n text:=trim(coalesce(p_notes,''));
begin
 if not public.is_admin() then raise exception 'Admin authorization required';end if;if length(n)>1000 or n~'[[:cntrl:]]' then raise exception 'Invalid admin notes';end if;
 select * into v from public.withdrawals where id=p_id for update;if not found or v.status<>'pending' then raise exception 'Only pending withdrawals can be approved';end if;
 update public.withdrawals set status='approved',reviewed_at=now(),approved_at=now(),admin_notes=nullif(n,'') where id=p_id;
 perform public.audit('withdrawal_approved','withdrawal',p_id::text,jsonb_build_object('notes',nullif(n,'')));
end $$;

create or replace function public.admin_reject_withdrawal(p_id bigint,p_notes text)
returns void language plpgsql security definer set search_path=pg_catalog,public
as $$
declare v public.withdrawals;n text:=trim(coalesce(p_notes,''));
begin
 if not public.is_admin() then raise exception 'Admin authorization required';end if;if length(n)<3 or length(n)>1000 or n~'[[:cntrl:]]' then raise exception 'Rejection reason is required';end if;
 select * into v from public.withdrawals where id=p_id for update;if not found or v.status not in('pending','approved') then raise exception 'Withdrawal cannot be rejected in this state';end if;
 update public.withdrawals set status='rejected',reviewed_at=now(),rejected_at=now(),admin_notes=n where id=p_id;
 perform public.audit('withdrawal_rejected','withdrawal',p_id::text,jsonb_build_object('notes',n));
end $$;

create or replace function public.admin_refund_withdrawal(p_id bigint,p_notes text default null)
returns void language plpgsql security definer set search_path=pg_catalog,public
as $$
declare v public.withdrawals;n text:=trim(coalesce(p_notes,''));
begin
 if not public.is_admin() then raise exception 'Admin authorization required';end if;if length(n)>1000 or n~'[[:cntrl:]]' then raise exception 'Invalid admin notes';end if;
 select * into v from public.withdrawals where id=p_id for update;if not found or v.status<>'rejected' then raise exception 'Only rejected withdrawals can be refunded';end if;
 update public.withdrawals set status='refunded',refunded_at=now(),admin_notes=coalesce(nullif(n,''),admin_notes) where id=p_id;
 perform public.apply_wallet_tx(v.user_id,'withdrawal_refund',v.amount_pkr,v.amount_pkr,-v.amount_pkr,0,'withdrawal',p_id::text,jsonb_build_object('reason',nullif(n,'')));
 perform public.audit('withdrawal_refunded','withdrawal',p_id::text,jsonb_build_object('notes',nullif(n,'')));
end $$;

revoke all on function public.admin_approve_withdrawal(bigint,text) from public,anon;grant execute on function public.admin_approve_withdrawal(bigint,text) to authenticated;
revoke all on function public.admin_reject_withdrawal(bigint,text) from public,anon;grant execute on function public.admin_reject_withdrawal(bigint,text) to authenticated;
revoke all on function public.admin_refund_withdrawal(bigint,text) from public,anon;grant execute on function public.admin_refund_withdrawal(bigint,text) to authenticated;

create or replace function public.admin_mark_withdrawal_paid(p_id bigint,p_payment_reference text,p_notes text default null)
returns void language plpgsql security definer set search_path=pg_catalog,public
as $$
declare v public.withdrawals;ref text:=trim(coalesce(p_payment_reference,''));n text:=trim(coalesce(p_notes,''));
begin
 if not public.is_admin() then raise exception 'Admin authorization required';end if;if length(ref)<2 or length(ref)>120 or ref~'[[:cntrl:]]' then raise exception 'Payment reference required';end if;if length(n)>1000 or n~'[[:cntrl:]]' then raise exception 'Invalid admin notes';end if;
 select * into v from public.withdrawals where id=p_id for update;if not found or v.status<>'approved' then raise exception 'Only approved withdrawals can be marked paid';end if;
 update public.withdrawals set status='paid',paid_at=now(),payment_reference=ref,admin_notes=coalesce(nullif(n,''),admin_notes) where id=p_id;
 perform public.apply_wallet_tx(v.user_id,'withdrawal_paid',v.amount_pkr,0,-v.amount_pkr,0,'withdrawal',p_id::text,jsonb_build_object('payment_reference',ref));
 perform public.audit('withdrawal_paid','withdrawal',p_id::text,jsonb_build_object('payment_reference',ref,'notes',nullif(n,'')));
end $$;
revoke all on function public.admin_mark_withdrawal_paid(bigint,text,text) from public,anon;grant execute on function public.admin_mark_withdrawal_paid(bigint,text,text) to authenticated;

create or replace function public.admin_verify_referral(p_referral_id bigint,p_reason text)
returns void language plpgsql security definer set search_path=pg_catalog,public
as $$
declare r public.referrals;ref_status text;referred_status text;confirmed timestamptz;reason text:=trim(coalesce(p_reason,''));
begin
 if not public.is_admin() then raise exception 'Admin authorization required';end if;if length(reason)<3 or length(reason)>1000 or reason~'[[:cntrl:]]' then raise exception 'Verification reason is required';end if;
 select * into r from public.referrals where id=p_referral_id for update;if not found then raise exception 'Referral not found';end if;if r.status='verified' then return;end if;
 select account_status into ref_status from public.profiles where id=r.referrer_id;select p.account_status,au.email_confirmed_at into referred_status,confirmed from public.profiles p join auth.users au on au.id=p.id where p.id=r.referred_id;
 if ref_status<>'active' then raise exception 'Referrer is not active';end if;if referred_status<>'active' or confirmed is null then raise exception 'Referred account is not eligible for verification';end if;
 update public.referrals set status='verified',verification_reason=reason,verified_at=now() where id=p_referral_id;
 perform public.audit('referral_verified','referral',r.id::text,jsonb_build_object('referrer_id',r.referrer_id,'reason',reason));
end $$;
revoke all on function public.admin_verify_referral(bigint,text) from public,anon;grant execute on function public.admin_verify_referral(bigint,text) to authenticated;

create or replace function public.admin_adjust_wallet(p_user_id uuid,p_amount numeric,p_reason text)
returns void language plpgsql security definer set search_path=pg_catalog,public
as $$
declare reason text:=trim(coalesce(p_reason,''));amt numeric:=round(p_amount,2);
begin
 if not public.is_admin() then raise exception 'Admin authorization required';end if;if p_user_id is null then raise exception 'User is required';end if;if amt=0 then raise exception 'Adjustment cannot be zero';end if;if length(reason)<5 or length(reason)>1000 or reason~'[[:cntrl:]]' then raise exception 'Reason is required';end if;
 perform public.apply_wallet_tx(p_user_id,'admin_adjustment',abs(amt),amt,0,0,'admin_adjustment',p_user_id::text,jsonb_build_object('reason',reason,'direction',case when amt>0 then 'credit' else 'debit' end));
 perform public.audit('wallet_adjusted','user',p_user_id::text,jsonb_build_object('amount_pkr',amt,'reason',reason));
end $$;
revoke all on function public.admin_adjust_wallet(uuid,numeric,text) from public,anon;grant execute on function public.admin_adjust_wallet(uuid,numeric,text) to authenticated;

-- Ensure every shipped static event route has a corresponding database record.
-- These are configuration records only; inactive events do not publish rewards.
insert into public.events(slug,title,description,active,starts_at,ends_at,config) values
 ('12-rabi-ul-awwal','12 Rabi ul Awwal','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('27-ramadan','27 Ramadan','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('arafah-day','Arafah Day','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('ashura','Ashura','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('childrens-day','Children''s Day','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('eid-milad-un-nabi','Eid Milad un Nabi','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('hajj','Hajj','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('islamic-new-year','Islamic New Year','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('kashmir-day','Kashmir Day','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('laylat-al-qadr','Laylat al-Qadr','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('ramadan-calendar','Ramadan Calendar','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('sehri-iftar','Sehri & Iftar','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('shab-e-barat','Shab-e-Barat','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('shab-e-meraj','Shab-e-Meraj','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('teachers-day','Teachers'' Day','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}'),
 ('womens-day','Women''s Day','Seasonal event. Configure dates before publishing.',false,null,null,'{"language":"en-ur"}')
on conflict(slug) do nothing;
revoke all on function public.prevent_ledger_mutation() from public,anon,authenticated;
