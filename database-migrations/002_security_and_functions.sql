-- 002_security_and_functions.sql
-- PakCash V8.1: trusted RPCs, explicit grants, atomic ledger operations.

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = pg_catalog, public
as $$
  select exists(select 1 from public.admin_users where user_id = auth.uid())
$$;

create or replace function public.audit(
  p_action text,
  p_target_type text default null,
  p_target_id text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if nullif(trim(p_action),'') is null then raise exception 'Audit action is required'; end if;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata)
  values(auth.uid(),trim(p_action),nullif(trim(p_target_type),''),nullif(trim(p_target_id),''),coalesce(p_metadata,'{}'::jsonb));
end
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  uname text := new.raw_user_meta_data->>'username';
  refcode text := upper(coalesce(new.raw_user_meta_data->>'referral_code',''));
  code text := upper('PK'||substr(replace(gen_random_uuid()::text,'-',''),1,8));
  referrer uuid;
begin
  if uname is null or uname !~ '^[A-Za-z0-9_]{3,30}$' then raise exception 'Invalid username'; end if;
  insert into public.profiles(id,username,referral_code) values(new.id,uname,code);
  insert into public.wallets(user_id) values(new.id);
  if refcode <> '' then
    select id into referrer from public.profiles
    where referral_code=refcode and id<>new.id and account_status='active';
    if referrer is null then raise exception 'Referral code is invalid or unavailable'; end if;
    insert into public.referrals(referrer_id,referred_id,referral_code)
    values(referrer,new.id,refcode)
    on conflict(referred_id) do nothing;
  end if;
  return new;
end
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.apply_wallet_tx(
  p_user uuid,p_type text,p_amount numeric,p_available_delta numeric,p_reserved_delta numeric,
  p_total_earned_delta numeric,p_reference_type text default null,p_reference_id text default null,p_metadata jsonb default '{}'::jsonb
) returns public.wallet_transactions
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare w public.wallets; tx public.wallet_transactions;
      after_available numeric; after_reserved numeric; after_earned numeric;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if p_user is null then raise exception 'User is required'; end if;
  if p_type not in('daily_reward','task_reward','referral_reward','withdrawal_hold','withdrawal_paid','withdrawal_refund','admin_adjustment','reversal') then raise exception 'Invalid transaction type'; end if;
  if p_amount < 0 then raise exception 'Transaction amount cannot be negative'; end if;
  select * into w from public.wallets where user_id=p_user for update;
  if not found then raise exception 'Wallet not found'; end if;
  after_available := w.balance_pkr + p_available_delta;
  after_reserved := w.reserved_pkr + p_reserved_delta;
  after_earned := w.total_earned_pkr + p_total_earned_delta;
  if after_available < 0 or after_reserved < 0 or after_earned < 0 then raise exception 'Wallet balance would become negative'; end if;
  update public.wallets set balance_pkr=after_available,reserved_pkr=after_reserved,total_earned_pkr=after_earned,updated_at=now() where user_id=p_user;
  insert into public.wallet_transactions(user_id,transaction_type,amount_pkr,available_delta_pkr,reserved_delta_pkr,total_earned_delta_pkr,balance_before_pkr,balance_after_pkr,reserved_before_pkr,reserved_after_pkr,reference_type,reference_id,metadata)
  values(p_user,p_type,p_amount,p_available_delta,p_reserved_delta,p_total_earned_delta,w.balance_pkr,after_available,w.reserved_pkr,after_reserved,p_reference_type,p_reference_id,coalesce(p_metadata,'{}'))
  returning * into tx;
  return tx;
end
$$;

create or replace function public.claim_daily_spin()
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare uid uuid:=auth.uid(); tid bigint; reward numeric(10,2); min_reward numeric:=1; max_reward numeric:=5;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if not exists(select 1 from public.profiles where id=uid and account_status='active') then raise exception 'Account is not active'; end if;
  select id,coalesce((config->>'min_reward')::numeric,1),coalesce((config->>'max_reward')::numeric,5)
    into tid,min_reward,max_reward
  from public.tasks
  where type='daily_spin' and active=true
  order by id limit 1;
  if tid is null then raise exception 'Daily spin is not configured'; end if;
  if min_reward<0 or max_reward<min_reward then raise exception 'Invalid daily spin configuration'; end if;
  -- The unique (user_id, task_id, claim_day) constraint is the concurrency guard.
  -- No task row lock is taken, so different users can spin concurrently.
  reward := round((min_reward + random() * (max_reward-min_reward))::numeric,2);
  begin
    insert into public.task_completions(user_id,task_id,claim_day,reward_pkr,metadata)
    values(uid,tid,current_date,reward,jsonb_build_object('source','daily_spin'));
  exception when unique_violation then
    raise exception 'Daily spin already claimed';
  end;
  perform public.apply_wallet_tx(uid,'daily_reward',reward,reward,0,reward,'task',tid::text,jsonb_build_object('task','daily_spin','claim_day',current_date));
  perform public.audit('daily_reward','task',tid::text,jsonb_build_object('amount_pkr',reward,'claim_day',current_date));
  return jsonb_build_object('reward_pkr',reward);
end
$$;

create or replace function public.request_withdrawal(p_amount numeric,p_method text,p_destination text)
returns public.withdrawals
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare uid uuid:=auth.uid(); w public.wallets; v public.withdrawals; daily numeric; dest text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if not exists(select 1 from public.profiles where id=uid and account_status='active') then raise exception 'Account is not active'; end if;
  if p_amount is null or p_amount<100 or p_amount>1500 then raise exception 'Withdrawal must be between 100 and 1500 PKR'; end if;
  if p_method not in('easypaisa','jazzcash','bank') then raise exception 'Unsupported withdrawal method'; end if;
  dest:=trim(coalesce(p_destination,''));
  if dest ~ '[[:cntrl:]]' or length(dest)<3 or length(dest)>160 then raise exception 'Invalid destination'; end if;
  if p_method in('easypaisa','jazzcash') and dest !~ '^03[0-9]{9}$' then raise exception 'Mobile wallet destination must be 11 digits starting with 03'; end if;
  if p_method='bank' and dest !~ '^[A-Za-z0-9]{8,34}$' then raise exception 'Bank destination must be 8 to 34 letters or numbers'; end if;
  if (select verified_referrals from public.profiles where id=uid)<1000 then raise exception '1000 verified referrals are required before payout requests'; end if;
  select * into w from public.wallets where user_id=uid for update;
  if w.balance_pkr<p_amount then raise exception 'Insufficient available balance'; end if;
  select coalesce(sum(amount_pkr),0) into daily from public.withdrawals
    where user_id=uid and created_at>=date_trunc('day',now()) and status in('pending','approved','paid');
  if daily+p_amount>1500 then raise exception 'Daily withdrawal limit is 1500 PKR'; end if;
  if exists(select 1 from public.withdrawals where user_id=uid and status in('pending','approved')) then raise exception 'You already have a pending withdrawal'; end if;
  insert into public.withdrawals(user_id,amount_pkr,method,destination) values(uid,p_amount,p_method,dest) returning * into v;
  perform public.apply_wallet_tx(uid,'withdrawal_hold',p_amount,-p_amount,p_amount,0,'withdrawal',v.id::text,jsonb_build_object('method',p_method));
  perform public.audit('withdrawal_requested','withdrawal',v.id::text,jsonb_build_object('amount_pkr',p_amount,'method',p_method));
  return v;
end
$$;

create or replace function public.admin_verify_referral(p_referral_id bigint,p_reason text)
returns void language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare r public.referrals; ref_status text;
begin
  if not public.is_admin() then raise exception 'Admin authorization required'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'Verification reason is required'; end if;
  select * into r from public.referrals where id=p_referral_id for update;
  if not found then raise exception 'Referral not found'; end if;
  if r.status='verified' then return; end if;
  select account_status into ref_status from public.profiles where id=r.referrer_id;
  if ref_status is null or ref_status<>'active' then raise exception 'Referrer is not active'; end if;
  update public.referrals set status='verified',verification_reason=trim(p_reason),verified_at=now() where id=p_referral_id;
  update public.profiles set verified_referrals=verified_referrals+1 where id=r.referrer_id;
  perform public.audit('referral_verified','referral',r.id::text,jsonb_build_object('referrer_id',r.referrer_id,'reason',trim(p_reason)));
end
$$;

create or replace function public.admin_approve_withdrawal(p_id bigint,p_notes text default null)
returns void language plpgsql security definer set search_path=pg_catalog, public
as $$
declare v public.withdrawals;
begin
 if not public.is_admin() then raise exception 'Admin authorization required'; end if;
 select * into v from public.withdrawals where id=p_id for update;
 if not found or v.status<>'pending' then raise exception 'Only pending withdrawals can be approved'; end if;
 update public.withdrawals set status='approved',reviewed_at=now(),approved_at=now(),admin_notes=coalesce(p_notes,admin_notes) where id=p_id;
 perform public.audit('withdrawal_approved','withdrawal',p_id::text,jsonb_build_object('notes',p_notes));
end $$;

create or replace function public.admin_reject_withdrawal(p_id bigint,p_notes text)
returns void language plpgsql security definer set search_path=pg_catalog, public
as $$
declare v public.withdrawals;
begin
 if not public.is_admin() then raise exception 'Admin authorization required'; end if;
 if length(trim(coalesce(p_notes,'')))<3 then raise exception 'Rejection reason is required'; end if;
 select * into v from public.withdrawals where id=p_id for update;
 if not found or v.status not in('pending','approved') then raise exception 'Withdrawal cannot be rejected in this state'; end if;
 update public.withdrawals set status='rejected',reviewed_at=now(),rejected_at=now(),admin_notes=trim(p_notes) where id=p_id;
 perform public.audit('withdrawal_rejected','withdrawal',p_id::text,jsonb_build_object('notes',trim(p_notes)));
end $$;

create or replace function public.admin_refund_withdrawal(p_id bigint,p_notes text default null)
returns void language plpgsql security definer set search_path=pg_catalog, public
as $$
declare v public.withdrawals;
begin
 if not public.is_admin() then raise exception 'Admin authorization required'; end if;
 select * into v from public.withdrawals where id=p_id for update;
 if not found or v.status<>'rejected' then raise exception 'Only rejected withdrawals can be refunded'; end if;
 update public.withdrawals set status='refunded',refunded_at=now(),admin_notes=coalesce(p_notes,admin_notes) where id=p_id;
 perform public.apply_wallet_tx(v.user_id,'withdrawal_refund',v.amount_pkr,v.amount_pkr,-v.amount_pkr,0,'withdrawal',p_id::text,jsonb_build_object('reason',p_notes));
 perform public.audit('withdrawal_refunded','withdrawal',p_id::text,jsonb_build_object('notes',p_notes));
end $$;

create or replace function public.admin_mark_withdrawal_paid(p_id bigint,p_payment_reference text,p_notes text default null)
returns void language plpgsql security definer set search_path=pg_catalog, public
as $$
declare v public.withdrawals;
begin
 if not public.is_admin() then raise exception 'Admin authorization required'; end if;
 select * into v from public.withdrawals where id=p_id for update;
 if not found or v.status<>'approved' then raise exception 'Only approved withdrawals can be marked paid'; end if;
 if length(trim(coalesce(p_payment_reference,'')))<2 or trim(p_payment_reference) ~ '[[:cntrl:]]' then raise exception 'Payment reference required'; end if;
 update public.withdrawals set status='paid',paid_at=now(),payment_reference=trim(p_payment_reference),admin_notes=coalesce(p_notes,admin_notes) where id=p_id;
 perform public.apply_wallet_tx(v.user_id,'withdrawal_paid',v.amount_pkr,0,-v.amount_pkr,0,'withdrawal',p_id::text,jsonb_build_object('payment_reference',trim(p_payment_reference)));
 perform public.audit('withdrawal_paid','withdrawal',p_id::text,jsonb_build_object('payment_reference',trim(p_payment_reference),'notes',p_notes));
end $$;

create or replace function public.admin_set_user_status(p_user_id uuid,p_status text)
returns void language plpgsql security definer set search_path=pg_catalog, public
as $$
begin
 if not public.is_admin() then raise exception 'Admin authorization required'; end if;
 if p_status not in('active','suspended','closed') then raise exception 'Invalid status'; end if;
 if p_user_id=auth.uid() and p_status<>'active' then raise exception 'You cannot suspend or close your own admin account'; end if;
 update public.profiles set account_status=p_status where id=p_user_id;
 if not found then raise exception 'User not found'; end if;
 perform public.audit('user_status_changed','user',p_user_id::text,jsonb_build_object('status',p_status));
end $$;

create or replace function public.admin_adjust_wallet(p_user_id uuid,p_amount numeric,p_reason text)
returns void language plpgsql security definer set search_path=pg_catalog, public
as $$
begin
 if not public.is_admin() then raise exception 'Admin authorization required'; end if;
 if p_amount is null or p_amount=0 then raise exception 'Adjustment cannot be zero'; end if;
 if length(trim(coalesce(p_reason,'')))<5 or trim(p_reason) ~ '[[:cntrl:]]' then raise exception 'Reason is required'; end if;
 perform public.apply_wallet_tx(p_user_id,'admin_adjustment',abs(p_amount),p_amount,0,case when p_amount>0 then p_amount else 0 end,'admin_adjustment',p_user_id::text,jsonb_build_object('reason',trim(p_reason),'direction',case when p_amount>0 then 'credit' else 'debit' end));
 perform public.audit('wallet_adjusted','user',p_user_id::text,jsonb_build_object('amount_pkr',p_amount,'reason',trim(p_reason)));
end $$;

create or replace function public.admin_upsert_task(
 p_id bigint,p_type public.task_type,p_title text,p_description text,p_reward numeric,p_daily_limit integer,p_active boolean,p_config jsonb,p_event_id bigint default null)
returns public.tasks language plpgsql security definer set search_path=pg_catalog, public
as $$
declare v public.tasks; cfg jsonb:=coalesce(p_config,'{}'::jsonb);
begin
 if not public.is_admin() then raise exception 'Admin authorization required'; end if;
 if length(trim(coalesce(p_title,'')))<2 then raise exception 'Task title is required'; end if;
 if p_reward<0 or p_daily_limit<1 then raise exception 'Invalid task configuration'; end if;
 if p_type='daily_spin' then
   if p_daily_limit<>1 or p_reward<>0 then raise exception 'Daily spin must use limit 1 and server-generated reward'; end if;
 elsif p_active then
   raise exception 'This task type has no verified reward engine and cannot be activated';
 end if;
 if p_id is null then
  insert into public.tasks(type,title,description,reward_pkr,daily_limit,active,config,event_id)
  values(p_type,trim(p_title),p_description,p_reward,p_daily_limit,p_active,cfg,p_event_id) returning * into v;
 else
  update public.tasks set type=p_type,title=trim(p_title),description=p_description,reward_pkr=p_reward,daily_limit=p_daily_limit,active=p_active,config=cfg,event_id=p_event_id where id=p_id returning * into v;
  if not found then raise exception 'Task not found'; end if;
 end if;
 perform public.audit('task_upserted','task',v.id::text,jsonb_build_object('active',v.active,'type',v.type));
 return v;
end $$;

create or replace function public.admin_set_event(p_id bigint,p_slug text,p_title text,p_description text,p_active boolean,p_starts timestamptz,p_ends timestamptz,p_config jsonb)
returns public.events language plpgsql security definer set search_path=pg_catalog, public
as $$
declare v public.events; slug_clean text:=lower(trim(coalesce(p_slug,''))); title_clean text:=trim(coalesce(p_title,''));
begin
 if not public.is_admin() then raise exception 'Admin authorization required'; end if;
 if slug_clean !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception 'Invalid event slug'; end if;
 if length(title_clean)<2 then raise exception 'Event title is required'; end if;
 if p_active and (p_starts is null or p_ends is null or p_ends<=p_starts) then raise exception 'Active event requires valid start and end dates'; end if;
 if p_starts is not null and p_ends is not null and p_ends<=p_starts then raise exception 'End must be after start'; end if;
 if p_id is null then
   insert into public.events(slug,title,description,active,starts_at,ends_at,config)
   values(slug_clean,title_clean,p_description,p_active,p_starts,p_ends,coalesce(p_config,'{}'))
   returning * into v;
 else
   update public.events set slug=slug_clean,title=title_clean,description=p_description,active=p_active,starts_at=p_starts,ends_at=p_ends,config=coalesce(p_config,'{}') where id=p_id returning * into v;
   if not found then raise exception 'Event not found'; end if;
 end if;
 perform public.audit('event_upserted','event',v.id::text,jsonb_build_object('active',v.active,'slug',v.slug));
 return v;
exception when unique_violation then raise exception 'Event slug already exists';
end $$;

-- Explicit RPC permissions: no anonymous execution; legitimate user RPCs require auth.
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;
revoke all on function public.audit(text,text,text,jsonb) from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.apply_wallet_tx(uuid,text,numeric,numeric,numeric,numeric,text,text,jsonb) from public, anon, authenticated;
revoke all on function public.claim_daily_spin() from public, anon, authenticated;
grant execute on function public.claim_daily_spin() to authenticated;
revoke all on function public.request_withdrawal(numeric,text,text) from public, anon, authenticated;
grant execute on function public.request_withdrawal(numeric,text,text) to authenticated;
revoke all on function public.admin_verify_referral(bigint,text) from public, anon, authenticated;
grant execute on function public.admin_verify_referral(bigint,text) to authenticated;
revoke all on function public.admin_approve_withdrawal(bigint,text) from public, anon, authenticated;
grant execute on function public.admin_approve_withdrawal(bigint,text) to authenticated;
revoke all on function public.admin_reject_withdrawal(bigint,text) from public, anon, authenticated;
grant execute on function public.admin_reject_withdrawal(bigint,text) to authenticated;
revoke all on function public.admin_refund_withdrawal(bigint,text) from public, anon, authenticated;
grant execute on function public.admin_refund_withdrawal(bigint,text) to authenticated;
revoke all on function public.admin_mark_withdrawal_paid(bigint,text,text) from public, anon, authenticated;
grant execute on function public.admin_mark_withdrawal_paid(bigint,text,text) to authenticated;
revoke all on function public.admin_set_user_status(uuid,text) from public, anon, authenticated;
grant execute on function public.admin_set_user_status(uuid,text) to authenticated;
revoke all on function public.admin_adjust_wallet(uuid,numeric,text) from public, anon, authenticated;
grant execute on function public.admin_adjust_wallet(uuid,numeric,text) to authenticated;
revoke all on function public.admin_upsert_task(bigint,public.task_type,text,text,numeric,integer,boolean,jsonb,bigint) from public, anon, authenticated;
grant execute on function public.admin_upsert_task(bigint,public.task_type,text,text,numeric,integer,boolean,jsonb,bigint) to authenticated;
revoke all on function public.admin_set_event(bigint,text,text,text,boolean,timestamptz,timestamptz,jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_event(bigint,text,text,text,boolean,timestamptz,timestamptz,jsonb) to authenticated;
