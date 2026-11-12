-- =============================================================================
-- Calendário editorial · Etapa 3: funções de gravação
-- -----------------------------------------------------------------------------
-- O site nunca grava direto nas tabelas. Cada ação passa por uma função que
-- confere quem está pedindo (auth.uid()), o papel no calendário e as regras do
-- fluxo de aprovação, as mesmas do protótipo:
--   • admin e editor criam, editam, enviam, excluem e restauram;
--   • reviewer comenta, aprova e solicita ajustes (os três cargos têm as mesmas permissões);
--   • editar um post aprovado invalida a aprovação; editar um post aguardando
--     aprovação o retira da fila (as duas coisas pedem confirmação);
--   • cada envio cria uma versão imutável; decisões conferem a versão esperada.
-- Erros: o código vai em "hint" (NOT_FOUND, FORBIDDEN, INVALID, NEEDS_ACK, INCOMPLETE,
-- ALREADY_DECIDED, STALE, COMMENT_REQUIRED, DUPLICATE) e a mensagem já vem em português.
-- =============================================================================

create schema if not exists app;
revoke all on schema app from public;

-- Apoio ------------------------------------------------------------------------
create or replace function app.fail(code text, msg text, extra text default null) returns void
language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = 'P0001', message = msg, hint = code, detail = coalesce(extra, '');
end $$;

-- Quem está agindo, copiado em cada registro (trocar o nome depois não muda a autoria).
create or replace function app.actor(cal text) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', m.user_id,
    'name', coalesce(nullif(btrim(p.full_name), ''), 'Sem nome'),
    'cargo', m.cargo,
    'role', case when m.role = 'reviewer' then 'reviewer' else 'editor' end)
  from public.calendar_members m
  left join public.profiles p on p.id = m.user_id
  where m.calendar_id = cal and m.user_id = auth.uid()
$$;

create or replace function app.require_manager(cal text) returns void
language plpgsql set search_path = '' as $$
begin
  if not public.can_manage(cal) then
    perform app.fail('FORBIDDEN', 'Só quem edita o calendário pode fazer isso.');
  end if;
end $$;

-- Busca e trava a publicação. Quem não é do calendário recebe "não encontrada".
create or replace function app.lock_post(pid uuid, include_trashed boolean default false) returns public.posts
language plpgsql set search_path = '' as $$
declare p public.posts;
begin
  select * into p from public.posts where id = pid for update;
  if not found or not public.is_member(p.calendar_id) or (p.trashed is not null and not include_trashed) then
    perform app.fail('NOT_FOUND', 'Publicação não encontrada neste calendário. Ela pode ter sido excluída.');
  end if;
  return p;
end $$;

create or replace function app.event(pid uuid, typ text, ver int, who jsonb, details jsonb default '{}'::jsonb) returns void
language sql set search_path = '' as $$
  insert into public.post_events (post_id, type, version, details, actor)
  values (pid, typ, ver, coalesce(details, '{}'::jsonb), who)
$$;

-- Confere e normaliza os campos de conteúdo. Nada é cortado: texto acima do limite é recusado.
create or replace function app.read_content(d jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v_theme text; v_date text; v_time text; v_net text; v_fmt text;
  v_title text; v_sub text; v_cap text; v_vis text;
  dd date; h int; mi int;
begin
  if d is null or jsonb_typeof(d) <> 'object' then
    perform app.fail('INVALID', 'Dados da publicação ausentes.');
  end if;
  v_theme := btrim(coalesce(d ->> 'theme', ''));
  v_date  := btrim(coalesce(d ->> 'date', ''));
  v_time  := btrim(coalesce(d ->> 'time', ''));
  v_net   := coalesce(d ->> 'network', '');
  v_fmt   := coalesce(d ->> 'format', '');
  v_title := coalesce(d ->> 'title', '');
  v_sub   := coalesce(d ->> 'subtitle', '');
  v_cap   := coalesce(d ->> 'caption', '');
  v_vis   := coalesce(d ->> 'visual', '');

  if v_theme = '' then perform app.fail('INVALID', 'Informe o tema ou nome interno.'); end if;
  if char_length(v_theme) > 120 then perform app.fail('INVALID', format('O tema tem %s caracteres e o limite é 120. Encurte o texto.', char_length(v_theme))); end if;
  if char_length(v_title) > 160 then perform app.fail('INVALID', format('O título tem %s caracteres e o limite é 160. Encurte o texto.', char_length(v_title))); end if;
  if char_length(v_sub) > 200 then perform app.fail('INVALID', format('O subtítulo tem %s caracteres e o limite é 200. Encurte o texto.', char_length(v_sub))); end if;
  if char_length(v_cap) > 10000 then perform app.fail('INVALID', 'A legenda passa de 10.000 caracteres.'); end if;
  if char_length(v_vis) > 10000 then perform app.fail('INVALID', 'A proposta visual passa de 10.000 caracteres.'); end if;

  dd := null;
  if v_date ~ '^\d{4}-\d{2}-\d{2}$' then
    begin dd := v_date::date; exception when others then dd := null; end;
  end if;
  if dd is null or to_char(dd, 'YYYY-MM-DD') <> v_date or extract(year from dd) not between 2000 and 2100 then
    perform app.fail('INVALID', 'Escolha uma data válida.');
  end if;

  if v_time !~ '^\d{1,2}(:\d{2})?$' then perform app.fail('INVALID', 'Escolha um horário válido.'); end if;
  h := split_part(v_time, ':', 1)::int;
  mi := coalesce(nullif(split_part(v_time, ':', 2), '')::int, 0);
  if h > 23 or mi > 59 then perform app.fail('INVALID', 'Escolha um horário válido.'); end if;

  if v_net not in ('instagram', 'linkedin') then perform app.fail('INVALID', 'Escolha a rede: Instagram ou LinkedIn.'); end if;
  if v_fmt not in ('image', 'carousel', 'video') then perform app.fail('INVALID', 'Escolha o formato: imagem, carrossel ou vídeo.'); end if;

  return jsonb_build_object('theme', v_theme, 'date', v_date, 'time', lpad(h::text, 2, '0') || ':' || lpad(mi::text, 2, '0'),
    'network', v_net, 'format', v_fmt, 'title', v_title, 'subtitle', v_sub, 'caption', v_cap, 'visual', v_vis);
end $$;

-- Arquivos da arte: só caminhos dentro da pasta da própria publicação e que já existem no armazenamento.
create or replace function app.set_art(pid uuid, cal text, art jsonb) returns void
language plpgsql set search_path = '' as $$
declare
  item jsonb; pos int := 0; path text;
  prefix text := cal || '/' || pid::text || '/';
begin
  if art is null or jsonb_typeof(art) = 'null' then art := '[]'::jsonb; end if;
  if jsonb_typeof(art) <> 'array' then perform app.fail('INVALID', 'Lista de arquivos da arte inválida.'); end if;
  if jsonb_array_length(art) > 30 then perform app.fail('INVALID', 'Uma publicação pode ter no máximo 30 arquivos.'); end if;
  delete from public.post_assets where post_id = pid;
  for item in select e.value from jsonb_array_elements(art) with ordinality as e(value, ord) order by e.ord loop
    path := item ->> 'path';
    if path is null or left(path, char_length(prefix)) <> prefix or position('..' in path) > 0 then
      perform app.fail('INVALID', 'Arquivo da arte fora da pasta desta publicação.');
    end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'artes' and o.name = path) then
      perform app.fail('INVALID', format('O arquivo “%s” não foi encontrado no armazenamento. Anexe de novo.', coalesce(nullif(item ->> 'name', ''), path)));
    end if;
    if exists (select 1 from public.post_assets a where a.post_id = pid and a.storage_path = path) then
      perform app.fail('INVALID', 'O mesmo arquivo aparece duas vezes na arte.');
    end if;
    insert into public.post_assets (post_id, position, storage_path, name, mime, width, height, size_bytes)
    values (pid, pos, path, left(coalesce(item ->> 'name', ''), 255), left(coalesce(item ->> 'mime', ''), 100),
      case when item ->> 'w' ~ '^\d{1,6}$' then (item ->> 'w')::int end,
      case when item ->> 'h' ~ '^\d{1,6}$' then (item ->> 'h')::int end,
      case when item ->> 'size' ~ '^\d{1,12}$' then (item ->> 'size')::bigint end);
    pos := pos + 1;
  end loop;
end $$;

-- Montagem da publicação no formato que a tela usa ------------------------------------------
create or replace function app.art_json(pid uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.storage_path, 'kind', 'remote', 'path', a.storage_path, 'name', a.name, 'mime', a.mime,
      'w', coalesce(a.width, 0), 'h', coalesce(a.height, 0), 'size', coalesce(a.size_bytes, 0))
    order by a.position), '[]'::jsonb)
  from public.post_assets a where a.post_id = pid
$$;

create or replace function app.snapshot(pid uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('theme', p.theme, 'date', to_char(p.publish_date, 'YYYY-MM-DD'), 'time', to_char(p.publish_time, 'HH24:MI'),
    'network', p.network, 'format', p.format, 'title', p.title, 'subtitle', p.subtitle, 'caption', p.caption, 'visual', p.visual,
    'art', app.art_json(p.id))
  from public.posts p where p.id = pid
$$;

create or replace function app.post_json(pid uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'calendarId', p.calendar_id, 'isSample', p.is_sample,
    'theme', p.theme, 'date', to_char(p.publish_date, 'YYYY-MM-DD'), 'time', to_char(p.publish_time, 'HH24:MI'),
    'network', p.network, 'format', p.format, 'title', p.title, 'subtitle', p.subtitle, 'caption', p.caption, 'visual', p.visual,
    'art', app.art_json(p.id),
    'status', p.status, 'version', p.version, 'approval', p.approval, 'invalidated', p.invalidated,
    'trashed', p.trashed, 'origin', p.origin,
    'createdAt', p.created_at, 'updatedAt', p.updated_at,
    'createdBy', p.created_by_actor ->> 'name', 'createdByActor', p.created_by_actor,
    'versions', coalesce((select jsonb_agg(jsonb_build_object(
        'version', v.version, 'submittedAt', v.submitted_at, 'submittedBy', v.submitted_actor ->> 'name',
        'submittedActor', v.submitted_actor, 'snapshot', v.snapshot, 'decision', v.decision, 'invalidatedAt', v.invalidated_at)
      order by v.version) from public.post_versions v where v.post_id = p.id), '[]'::jsonb),
    'comments', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'at', c.created_at, 'author', c.actor ->> 'name', 'role', c.actor ->> 'role', 'actor', c.actor,
        'kind', c.kind, 'version', c.version, 'text', c.body, 'parentId', c.parent_id)
      order by c.created_at, c.id) from public.post_comments c where c.post_id = p.id), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(e.details || jsonb_build_object(
        'id', e.id, 'at', e.created_at, 'by', e.actor ->> 'name', 'role', e.actor ->> 'role', 'actor', e.actor,
        'type', e.type, 'version', e.version)
      order by e.id) from public.post_events e where e.post_id = p.id), '[]'::jsonb))
  from public.posts p where p.id = pid
$$;

create or replace function app.insert_post(cal text, pid uuid, d jsonb, orig jsonb, evtype text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  c jsonb := app.read_content(d);
  who jsonb := app.actor(cal);
  new_id uuid := coalesce(pid, gen_random_uuid());
begin
  if exists (select 1 from public.posts where id = new_id) then
    perform app.fail('INVALID', 'Esta publicação já foi salva. Atualize a página.');
  end if;
  insert into public.posts (id, calendar_id, theme, publish_date, publish_time, network, format, title, subtitle, caption, visual,
                            origin, export_id, created_by, created_by_actor)
  values (new_id, cal, c ->> 'theme', (c ->> 'date')::date, (c ->> 'time')::time, c ->> 'network', c ->> 'format',
          c ->> 'title', c ->> 'subtitle', c ->> 'caption', c ->> 'visual', orig, orig ->> 'exportId', auth.uid(), who);
  perform app.set_art(new_id, cal, d -> 'art');
  perform app.event(new_id, evtype, 1, who,
    case when orig is null then '{}'::jsonb else jsonb_build_object('exportId', orig ->> 'exportId') end);
  return app.post_json(new_id);
end $$;

revoke all on all functions in schema app from public;

-- Funções chamadas pelo site --------------------------------------------------------------------

-- Acesso de quem entrou: nome e calendários com papel e cargo.
create or replace function public.my_access() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'userId', auth.uid(),
    'name', (select pr.full_name from public.profiles pr where pr.id = auth.uid()),
    'calendars', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name, 'theme', c.theme, 'timezone', c.timezone, 'role', m.role, 'cargo', m.cargo)
      order by c.name)
      from public.calendar_members m join public.calendars c on c.id = m.calendar_id
      where m.user_id = auth.uid()), '[]'::jsonb))
$$;

create or replace function public.set_my_name(p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
begin
  if auth.uid() is null then perform app.fail('FORBIDDEN', 'Entre de novo para continuar.'); end if;
  if n = '' then perform app.fail('INVALID', 'Informe seu nome.'); end if;
  if char_length(n) > 80 then perform app.fail('INVALID', 'O nome pode ter até 80 caracteres.'); end if;
  insert into public.profiles (id, full_name) values (auth.uid(), n)
  on conflict (id) do update set full_name = excluded.full_name;
  return public.my_access();
end $$;

create or replace function public.list_posts(p_calendar text, p_trashed boolean default false) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_member(p_calendar) then
    perform app.fail('NOT_FOUND', 'Calendário não encontrado ou sem acesso.');
  end if;
  if p_trashed and not public.can_manage(p_calendar) then
    perform app.fail('FORBIDDEN', 'Só quem edita o calendário vê a lixeira.');
  end if;
  return coalesce((select jsonb_agg(app.post_json(p.id) order by p.publish_date, p.publish_time)
    from public.posts p where p.calendar_id = p_calendar and (p.trashed is not null) = coalesce(p_trashed, false)), '[]'::jsonb);
end $$;

create or replace function public.create_post(p_calendar text, p_id uuid, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_manager(p_calendar);
  return app.insert_post(p_calendar, p_id, p_data, null, 'created');
end $$;

create or replace function public.update_post(p_id uuid, p_data jsonb, p_ack_invalidation boolean default false, p_ack_withdraw boolean default false)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p public.posts; c jsonb; who jsonb; old jsonb;
  fields text[] := '{}'; f text; old_art text; new_art text;
  theme_changed boolean; effect text := 'saved';
begin
  p := app.lock_post(p_id);
  perform app.require_manager(p.calendar_id);
  c := app.read_content(p_data);
  old := app.snapshot(p.id);
  foreach f in array array['date', 'time', 'network', 'format', 'title', 'subtitle', 'caption', 'visual'] loop
    if coalesce(old ->> f, '') <> coalesce(c ->> f, '') then fields := fields || f; end if;
  end loop;
  select coalesce(string_agg(a.storage_path, '|' order by a.position), '') into old_art from public.post_assets a where a.post_id = p.id;
  select coalesce(string_agg(e.value ->> 'path', '|' order by e.ord), '') into new_art
    from jsonb_array_elements(case when jsonb_typeof(p_data -> 'art') = 'array' then p_data -> 'art' else '[]'::jsonb end) with ordinality as e(value, ord);
  if old_art <> new_art then fields := fields || 'art'::text; end if;
  theme_changed := (c ->> 'theme') <> p.theme;

  if cardinality(fields) = 0 and not theme_changed then
    return jsonb_build_object('post', app.post_json(p.id), 'effect', 'none');
  end if;
  if cardinality(fields) > 0 and p.status = 'approved' and not coalesce(p_ack_invalidation, false) then
    perform app.fail('NEEDS_ACK', 'Esta alteração invalida a aprovação. Confirme para salvar.');
  end if;
  if cardinality(fields) > 0 and p.status = 'pending' and not coalesce(p_ack_withdraw, false) then
    perform app.fail('NEEDS_ACK', 'Esta alteração retira a publicação da aprovação. Confirme para salvar.');
  end if;

  who := app.actor(p.calendar_id);
  update public.posts set theme = c ->> 'theme', publish_date = (c ->> 'date')::date, publish_time = (c ->> 'time')::time,
    network = c ->> 'network', format = c ->> 'format', title = c ->> 'title', subtitle = c ->> 'subtitle',
    caption = c ->> 'caption', visual = c ->> 'visual'
  where id = p.id;
  if 'art' = any(fields) then perform app.set_art(p.id, p.calendar_id, p_data -> 'art'); end if;
  perform app.event(p.id, 'edited', p.version, who,
    jsonb_build_object('fields', to_jsonb(case when theme_changed then fields || 'theme'::text else fields end)));

  if cardinality(fields) > 0 and p.status = 'approved' then
    update public.post_versions set invalidated_at = now() where post_id = p.id and version = (p.approval ->> 'version')::int;
    update public.posts set status = 'draft', approval = null, invalidated = jsonb_build_object(
        'version', (p.approval ->> 'version')::int, 'at', now(), 'by', who ->> 'name', 'actor', who, 'fields', to_jsonb(fields),
        'approvedBy', p.approval ->> 'by', 'approvedActor', p.approval -> 'actor')
      where id = p.id;
    perform app.event(p.id, 'approval_invalidated', p.version, who, jsonb_build_object('fields', to_jsonb(fields)));
    effect := 'invalidated';
  elsif cardinality(fields) > 0 and p.status = 'pending' then
    update public.post_versions set decision = jsonb_build_object('type', 'withdrawn', 'at', now(), 'by', who ->> 'name', 'actor', who)
      where post_id = p.id and version = (select max(v.version) from public.post_versions v where v.post_id = p.id);
    update public.posts set status = 'draft' where id = p.id;
    perform app.event(p.id, 'withdrawn', p.version, who, jsonb_build_object('fields', to_jsonb(fields)));
    effect := 'withdrawn';
  end if;
  return jsonb_build_object('post', app.post_json(p.id), 'effect', effect);
end $$;

create or replace function public.submit_post(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p public.posts; who jsonb; v int; missing text[] := '{}';
begin
  p := app.lock_post(p_id);
  perform app.require_manager(p.calendar_id);
  if p.status = 'pending' then perform app.fail('FORBIDDEN', 'Esta publicação já está aguardando aprovação.'); end if;
  if p.status = 'approved' then perform app.fail('FORBIDDEN', 'Esta publicação já foi aprovada. Edite para enviar uma nova versão.'); end if;
  if btrim(p.caption) = '' then missing := missing || 'legenda'::text; end if;
  if btrim(p.visual) = '' and not exists (select 1 from public.post_assets a where a.post_id = p.id) then
    missing := missing || 'arte ou descrição visual'::text;
  end if;
  if cardinality(missing) > 0 then
    perform app.fail('INCOMPLETE', 'Para enviar, preencha: ' || array_to_string(missing, ' e ') || '.');
  end if;
  who := app.actor(p.calendar_id);
  select count(*)::int + 1 into v from public.post_versions where post_id = p.id;
  insert into public.post_versions (post_id, version, submitted_actor, snapshot) values (p.id, v, who, app.snapshot(p.id));
  update public.posts set status = 'pending', version = v, invalidated = null where id = p.id;
  perform app.event(p.id, case when v > 1 then 'resubmitted' else 'submitted' end, v, who);
  return app.post_json(p.id);
end $$;

-- Decisão do revisor. Uma aprovação basta. A versão esperada impede decidir sobre conteúdo que mudou,
-- e o identificador do pedido evita registro duplicado por clique repetido.
create or replace function public.decide_post(p_id uuid, p_decision text, p_text text default null,
                                              p_expected_version int default null, p_request_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p public.posts; who jsonb; last_v public.post_versions; cid uuid;
  note text := btrim(coalesce(p_text, ''));
begin
  p := app.lock_post(p_id);
  if p_request_id is not null and exists (select 1 from public.post_comments c where c.id = p_request_id and c.post_id = p.id) then
    return app.post_json(p.id);
  end if;
  if coalesce(public.member_role(p.calendar_id), '') <> 'reviewer' then
    perform app.fail('FORBIDDEN', 'Só quem revisa o calendário pode aprovar ou solicitar ajustes.');
  end if;
  select * into last_v from public.post_versions v where v.post_id = p.id order by v.version desc limit 1 for update;
  if p.status <> 'pending' or last_v.version is null or last_v.decision is not null then
    perform app.fail('ALREADY_DECIDED', 'Esta versão já recebeu uma decisão.');
  end if;
  if p_expected_version is not null and p_expected_version <> p.version then
    perform app.fail('STALE', 'A publicação mudou enquanto você revisava. Reabra para ver a versão atual.');
  end if;
  if char_length(note) > 5000 then perform app.fail('INVALID', 'O comentário passa de 5.000 caracteres.'); end if;
  who := app.actor(p.calendar_id);

  if p_decision = 'approved' then
    update public.post_versions set decision = jsonb_build_object('type', 'approved', 'at', now(), 'by', who ->> 'name', 'actor', who)
      where post_id = p.id and version = last_v.version;
    update public.posts set status = 'approved',
      approval = jsonb_build_object('version', p.version, 'by', who ->> 'name', 'byId', auth.uid(), 'actor', who, 'at', now())
      where id = p.id;
    if note <> '' then
      insert into public.post_comments (id, post_id, kind, version, body, author_id, actor)
      values (coalesce(p_request_id, gen_random_uuid()), p.id, 'approval', p.version, note, auth.uid(), who);
    end if;
    perform app.event(p.id, 'approved', p.version, who);
  elsif p_decision = 'changes' then
    if note = '' then perform app.fail('COMMENT_REQUIRED', 'Escreva o que precisa ser ajustado. O comentário é obrigatório.'); end if;
    cid := coalesce(p_request_id, gen_random_uuid());
    insert into public.post_comments (id, post_id, kind, version, body, author_id, actor)
    values (cid, p.id, 'changes', p.version, note, auth.uid(), who);
    update public.post_versions set decision = jsonb_build_object('type', 'changes', 'at', now(), 'by', who ->> 'name', 'actor', who, 'commentId', cid)
      where post_id = p.id and version = last_v.version;
    update public.posts set status = 'changes' where id = p.id;
    perform app.event(p.id, 'changes_requested', p.version, who);
  else
    perform app.fail('INVALID', 'Decisão desconhecida.');
  end if;
  return app.post_json(p.id);
end $$;

create or replace function public.add_comment(p_id uuid, p_text text, p_parent_id uuid default null, p_request_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p public.posts; who jsonb; body text := btrim(coalesce(p_text, ''));
begin
  p := app.lock_post(p_id);
  if p_request_id is not null and exists (select 1 from public.post_comments c where c.id = p_request_id and c.post_id = p.id) then
    return app.post_json(p.id); /* clique repetido: já registrado */
  end if;
  if body = '' then perform app.fail('INVALID', 'Escreva o comentário antes de enviar.'); end if;
  if char_length(body) > 5000 then perform app.fail('INVALID', 'O comentário passa de 5.000 caracteres. Divida em partes menores.'); end if;
  if p_parent_id is not null and not exists (select 1 from public.post_comments c where c.id = p_parent_id and c.post_id = p.id) then
    perform app.fail('INVALID', 'Comentário original não encontrado.');
  end if;
  who := app.actor(p.calendar_id);
  insert into public.post_comments (id, post_id, parent_id, kind, version, body, author_id, actor)
  values (coalesce(p_request_id, gen_random_uuid()), p.id, p_parent_id,
          case when p_parent_id is null then 'comment' else 'reply' end, p.version, body, auth.uid(), who);
  return app.post_json(p.id);
end $$;

-- Lixeira: status, aprovação, versões, comentários e histórico ficam intactos.
create or replace function public.trash_post(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p public.posts; who jsonb;
begin
  p := app.lock_post(p_id);
  perform app.require_manager(p.calendar_id);
  who := app.actor(p.calendar_id);
  perform app.event(p.id, 'trashed', p.version, who);
  update public.posts set trashed = jsonb_build_object('at', now(), 'by', who ->> 'name', 'actor', who, 'status', p.status) where id = p.id;
  return app.post_json(p.id);
end $$;

create or replace function public.restore_post(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p public.posts;
begin
  p := app.lock_post(p_id, true);
  perform app.require_manager(p.calendar_id);
  if p.trashed is null then perform app.fail('INVALID', 'Esta publicação não está na lixeira.'); end if;
  update public.posts set trashed = null where id = p.id;
  perform app.event(p.id, 'restored', p.version, app.actor(p.calendar_id));
  return app.post_json(p.id);
end $$;

-- Exclusão definitiva: só a partir da lixeira. Devolve a pasta das artes para o site apagar os arquivos.
create or replace function public.purge_post(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p public.posts;
begin
  p := app.lock_post(p_id, true);
  perform app.require_manager(p.calendar_id);
  if p.trashed is null then perform app.fail('FORBIDDEN', 'Mova a publicação para a lixeira antes de excluir de vez.'); end if;
  delete from public.posts where id = p.id;
  return jsonb_build_object('ok', true, 'folder', p.calendar_id || '/' || p.id::text);
end $$;

-- Importação manual (a etapa 4 troca "duplicado" por "atualizar").
create or replace function public.find_import(p_calendar text, p_export_id text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_manager(p_calendar);
  return (select jsonb_build_object('id', p.id, 'theme', p.theme, 'date', to_char(p.publish_date, 'YYYY-MM-DD'),
                                    'time', to_char(p.publish_time, 'HH24:MI'), 'status', p.status, 'trashed', p.trashed is not null)
          from public.posts p where p.calendar_id = p_calendar and p.export_id = btrim(coalesce(p_export_id, '')));
end $$;

create or replace function public.import_post(p_calendar text, p_id uuid, p_data jsonb, p_origin jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  o jsonb := coalesce(p_origin, '{}'::jsonb);
  eid text := btrim(coalesce(o ->> 'exportId', ''));
  errs text[] := '{}'; c jsonb; dup jsonb; n_art int;
begin
  perform app.require_manager(p_calendar);
  if (o -> 'schemaVersion') is distinct from '1'::jsonb then
    errs := errs || 'Versão de formato não suportada. Este calendário aceita "schemaVersion": 1.'::text;
  end if;
  if char_length(eid) not between 3 and 120 or eid ~ '\s' or eid ~ '[[:cntrl:]]' then
    errs := errs || 'O "exportId" precisa ser um texto de 3 a 120 caracteres, sem espaços.'::text;
  end if;
  if coalesce(o ->> 'calendarId', '') <> p_calendar then
    errs := errs || format('Este arquivo é do calendário "%s", não deste.', coalesce(o ->> 'calendarId', ''));
  end if;
  if coalesce(o ->> 'timezone', '') <> 'America/Sao_Paulo' then
    errs := errs || 'Fuso horário não aceito. Use "America/Sao_Paulo" (horário de Brasília).'::text;
  end if;
  if cardinality(errs) > 0 then perform app.fail('INVALID', array_to_string(errs, ' ')); end if;

  dup := public.find_import(p_calendar, eid);
  if dup is not null then perform app.fail('DUPLICATE', 'Esta exportação já foi importada.', dup::text); end if;

  c := app.read_content(p_data);
  n_art := case when jsonb_typeof(p_data -> 'art') = 'array' then jsonb_array_length(p_data -> 'art') else 0 end;
  if btrim(c ->> 'caption') = '' then errs := errs || 'Falta a legenda.'::text; end if;
  if btrim(c ->> 'visual') = '' and n_art = 0 then errs := errs || 'Inclua a descrição visual ou anexe a arte.'::text; end if;
  if cardinality(errs) > 0 then perform app.fail('INVALID', array_to_string(errs, ' ')); end if;

  return app.insert_post(p_calendar, p_id, p_data, jsonb_build_object(
    'type', 'import', 'exportId', eid, 'schemaVersion', 1, 'calendarId', p_calendar, 'timezone', 'America/Sao_Paulo',
    'sourceName', left(coalesce(o ->> 'sourceName', ''), 255), 'importedAt', now(), 'importedBy', app.actor(p_calendar)), 'imported');
end $$;

-- Só quem fez login chama as funções ------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.my_access()', 'public.set_my_name(text)', 'public.list_posts(text, boolean)',
    'public.create_post(text, uuid, jsonb)', 'public.update_post(uuid, jsonb, boolean, boolean)',
    'public.submit_post(uuid)', 'public.decide_post(uuid, text, text, int, uuid)',
    'public.add_comment(uuid, text, uuid, uuid)', 'public.trash_post(uuid)', 'public.restore_post(uuid)',
    'public.purge_post(uuid)', 'public.find_import(text, text)', 'public.import_post(text, uuid, jsonb, jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- O nome passa a ser alterado só pela função set_my_name (com limite de tamanho).
drop policy if exists profiles_editar_proprio on public.profiles;
