-- Correção: quem é do mesmo calendário precisa ver o nome dos colegas (autoria de comentários e decisões).
-- A política anterior consultava calendar_members, que o revisor só enxerga para si mesmo.
-- A função abaixo faz a checagem sem passar pelas permissões da tabela e só responde verdadeiro ou falso.
create or replace function public.shares_calendar(other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.calendar_members a
    join public.calendar_members b on b.calendar_id = a.calendar_id
    where a.user_id = auth.uid() and b.user_id = other
  )
$$;

drop policy profiles_ler on public.profiles;
create policy profiles_ler on public.profiles for select to authenticated
  using (id = auth.uid() or public.shares_calendar(id));
