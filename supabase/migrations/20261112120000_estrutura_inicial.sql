-- =============================================================================
-- Calendário editorial · Etapa 2: estrutura, permissões e armazenamento de artes
-- -----------------------------------------------------------------------------
-- • Um calendário por cliente (calendars). Quem acessa cada um e com qual papel
--   fica em calendar_members: admin e editor gerenciam; reviewer comenta e decide.
-- • Data e horário são guardados como data e hora locais de Brasília, sem fuso,
--   para nunca mudar o dia por conversão. O fuso fica registrado no calendário.
-- • Nesta etapa a aplicação só LÊ pelas permissões abaixo. Toda gravação virá na
--   etapa 3 por funções no banco, que conferem papel e regras de aprovação.
-- =============================================================================

-- Calendários (um por cliente) -------------------------------------------------
create table public.calendars (
  id          text primary key check (id ~ '^[a-z0-9][a-z0-9-]{1,40}$'),
  name        text not null check (char_length(name) between 1 and 80),
  theme       jsonb not null default '{}'::jsonb,
  timezone    text not null default 'America/Sao_Paulo',
  created_at  timestamptz not null default now()
);

-- Perfis (nome exibido em comentários e decisões) ------------------------------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null default '',
  created_at  timestamptz not null default now()
);

-- Acessos por calendário --------------------------------------------------------
create table public.calendar_members (
  calendar_id text not null references public.calendars(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        text not null check (role in ('admin', 'editor', 'reviewer')),
  cargo       text check (cargo in ('Coordenação', 'Gerência', 'Diretoria')),
  created_at  timestamptz not null default now(),
  primary key (calendar_id, user_id),
  constraint revisor_tem_cargo check (role <> 'reviewer' or cargo is not null)
);
create index calendar_members_user on public.calendar_members (user_id);

-- Publicações -------------------------------------------------------------------
create table public.posts (
  id               uuid primary key default gen_random_uuid(),
  calendar_id      text not null references public.calendars(id) on delete restrict,
  theme            text not null check (char_length(theme) between 1 and 120),
  publish_date     date not null,
  publish_time     time(0) not null,
  network          text not null check (network in ('instagram', 'linkedin')),
  format           text not null check (format in ('image', 'carousel', 'video')),
  title            text not null default '' check (char_length(title) <= 160),
  subtitle         text not null default '' check (char_length(subtitle) <= 200),
  caption          text not null default '',
  visual           text not null default '',
  status           text not null default 'draft' check (status in ('draft', 'pending', 'changes', 'approved')),
  version          int  not null default 1 check (version >= 1),
  approval         jsonb,            -- { version, actor, at }
  invalidated      jsonb,            -- última aprovação invalidada por edição
  trashed          jsonb,            -- { at, actor, status } quando está na lixeira
  origin           jsonb,            -- { type: 'import' | 'drive', exportId, sourceName, importedAt, actor }
  export_id        text check (export_id is null or char_length(export_id) between 3 and 120),
  is_sample        boolean not null default false,
  created_by       uuid references auth.users(id) on delete set null,
  created_by_actor jsonb,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
-- exportId é único por calendário: base para "atualizar em vez de duplicar"
create unique index posts_export_id_unico on public.posts (calendar_id, export_id) where export_id is not null;
create index posts_calendario_data on public.posts (calendar_id, publish_date);

-- Arquivos da arte atual (a ordem é a position) ---------------------------------
create table public.post_assets (
  id           uuid primary key default gen_random_uuid(),
  post_id      uuid not null references public.posts(id) on delete cascade,
  position     int  not null check (position >= 0),
  storage_path text not null,
  name         text not null default '',
  mime         text not null default '',
  width        int,
  height       int,
  size_bytes   bigint,
  created_at   timestamptz not null default now(),
  unique (post_id, position)
);

-- Versões enviadas para aprovação (cópia imutável a cada envio) -----------------
create table public.post_versions (
  post_id         uuid not null references public.posts(id) on delete cascade,
  version         int  not null check (version >= 1),
  submitted_at    timestamptz not null default now(),
  submitted_actor jsonb not null,
  snapshot        jsonb not null,
  decision        jsonb,            -- { type: approved | changes | withdrawn, actor, at, commentId }
  invalidated_at  timestamptz,
  primary key (post_id, version)
);

-- Comentários (com cópia de nome e cargo no momento da ação) --------------------
create table public.post_comments (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.posts(id) on delete cascade,
  parent_id   uuid references public.post_comments(id) on delete cascade,
  kind        text not null check (kind in ('comment', 'reply', 'changes', 'approval')),
  version     int  not null,
  body        text not null check (char_length(btrim(body)) > 0),
  author_id   uuid references auth.users(id) on delete set null,
  actor       jsonb not null,
  created_at  timestamptz not null default now()
);
create index post_comments_post on public.post_comments (post_id, created_at);

-- Histórico (trilha de auditoria) -----------------------------------------------
create table public.post_events (
  id          bigint generated always as identity primary key,
  post_id     uuid not null references public.posts(id) on delete cascade,
  type        text not null,
  version     int  not null,
  details     jsonb not null default '{}'::jsonb,
  actor       jsonb not null,
  created_at  timestamptz not null default now()
);
create index post_events_post on public.post_events (post_id, created_at);

-- Execuções da importação automática (Google Drive) ------------------------------
create table public.import_runs (
  id          bigint generated always as identity primary key,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  status      text not null default 'running' check (status in ('running', 'ok', 'partial', 'error')),
  summary     jsonb not null default '{}'::jsonb
);

-- updated_at automático -----------------------------------------------------------
create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;
create trigger posts_touch_updated_at before update on public.posts
  for each row execute function public.touch_updated_at();

-- Perfil criado junto com o usuário ----------------------------------------------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''), split_part(coalesce(new.email, ''), '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Funções de apoio às permissões (security definer evita recursão nas políticas) --
create or replace function public.member_role(cal text) returns text
language sql stable security definer set search_path = '' as $$
  select m.role from public.calendar_members m where m.calendar_id = cal and m.user_id = auth.uid()
$$;
create or replace function public.is_member(cal text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.calendar_members m where m.calendar_id = cal and m.user_id = auth.uid())
$$;
create or replace function public.can_manage(cal text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.calendar_members m where m.calendar_id = cal and m.user_id = auth.uid() and m.role in ('admin', 'editor'))
$$;

-- Permissões de leitura ------------------------------------------------------------
alter table public.calendars        enable row level security;
alter table public.profiles         enable row level security;
alter table public.calendar_members enable row level security;
alter table public.posts            enable row level security;
alter table public.post_assets      enable row level security;
alter table public.post_versions    enable row level security;
alter table public.post_comments    enable row level security;
alter table public.post_events      enable row level security;
alter table public.import_runs      enable row level security;

create policy calendars_ler on public.calendars for select to authenticated
  using (public.is_member(id));

create policy profiles_ler on public.profiles for select to authenticated
  using (
    id = auth.uid()
    or exists (
      select 1 from public.calendar_members a
      join public.calendar_members b on b.calendar_id = a.calendar_id
      where a.user_id = auth.uid() and b.user_id = profiles.id
    )
  );
create policy profiles_editar_proprio on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy membros_ler on public.calendar_members for select to authenticated
  using (user_id = auth.uid() or public.member_role(calendar_id) = 'admin');

-- Quem é do calendário vê as publicações; a lixeira só quem gerencia
create policy posts_ler on public.posts for select to authenticated
  using (public.is_member(calendar_id) and (trashed is null or public.can_manage(calendar_id)));

-- Arquivos, versões, comentários e histórico seguem a visibilidade da publicação
create policy assets_ler on public.post_assets for select to authenticated
  using (exists (select 1 from public.posts p where p.id = post_assets.post_id));
create policy versions_ler on public.post_versions for select to authenticated
  using (exists (select 1 from public.posts p where p.id = post_versions.post_id));
create policy comments_ler on public.post_comments for select to authenticated
  using (exists (select 1 from public.posts p where p.id = post_comments.post_id));
create policy events_ler on public.post_events for select to authenticated
  using (exists (select 1 from public.posts p where p.id = post_events.post_id));

create policy import_runs_ler on public.import_runs for select to authenticated
  using (exists (select 1 from public.calendar_members m where m.user_id = auth.uid() and m.role in ('admin', 'editor')));

-- Sem políticas de insert/update/delete: gravação direta fica bloqueada para todos.

-- Armazenamento das artes ------------------------------------------------------------
-- Caminho dos arquivos: <calendario>/<publicacao>/<arquivo>. Limite de 50 MB (teto do plano gratuito).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('artes', 'artes', false, 52428800,
        array['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'video/mp4', 'video/quicktime', 'video/webm'])
on conflict (id) do nothing;

create policy artes_ler on storage.objects for select to authenticated
  using (bucket_id = 'artes' and public.is_member((storage.foldername(name))[1]));
create policy artes_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'artes' and public.can_manage((storage.foldername(name))[1]));
create policy artes_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'artes' and public.can_manage((storage.foldername(name))[1]));

-- Primeiro cliente ---------------------------------------------------------------------
insert into public.calendars (id, name) values ('loy4biz', 'Loy4biz') on conflict (id) do nothing;
