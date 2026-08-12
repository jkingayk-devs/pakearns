-- 004_v81_reconciliation.sql
-- V8.1 post-migration repair and reconciliation helpers.

create or replace function public.reconcile_wallet(p_user_id uuid)
returns table(user_id uuid, wallet_balance numeric, ledger_balance numeric, wallet_reserved numeric, ledger_reserved numeric, wallet_total_earned numeric, ledger_total_earned numeric, balanced boolean)
language sql stable security definer set search_path=pg_catalog, public
as $$
  select p_user_id,
         w.balance_pkr,
         coalesce(sum(t.available_delta_pkr),0),
         w.reserved_pkr,
         coalesce(sum(t.reserved_delta_pkr),0),
         w.total_earned_pkr,
         coalesce(sum(t.total_earned_delta_pkr),0),
         (w.balance_pkr=coalesce(sum(t.available_delta_pkr),0)
          and w.reserved_pkr=coalesce(sum(t.reserved_delta_pkr),0)
          and w.total_earned_pkr=coalesce(sum(t.total_earned_delta_pkr),0))
  from public.wallets w
  left join public.wallet_transactions t on t.user_id=w.user_id
  where w.user_id=p_user_id
    and (auth.uid()=p_user_id or public.is_admin())
  group by w.user_id,w.balance_pkr,w.reserved_pkr,w.total_earned_pkr
$$;
revoke all on function public.reconcile_wallet(uuid) from public, anon, authenticated;
grant execute on function public.reconcile_wallet(uuid) to authenticated;
