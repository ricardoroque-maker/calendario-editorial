-- =============================================================================
-- Teste da etapa 2: estrutura e permissões.
-- Roda dentro de uma transação que é desfeita no final: nada fica gravado.
-- Cada linha do resultado começa com OK ou FALHOU.
-- =============================================================================
do $$
declare
  adm  uuid := gen_random_uuid();
  ed   uuid := gen_random_uuid();
  rv   uuid := gen_random_uuid();
  fora uuid := gen_random_uuid();
  p1 uuid; p2 uuid; p3 uuid;
  n int; b boolean; t text;
  r text[] := '{}';
  res text;
begin
  -- Usuários de teste (o perfil deve nascer sozinho) ----------------------------
  insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at) values
    (adm,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'teste.admin@example.com',   '{"full_name":"Admin Teste"}',  now(), now()),
    (ed,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'teste.editor@example.com',  '{"full_name":"Editora Teste"}', now(), now()),
    (rv,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'teste.revisor@example.com', '{"full_name":"Revisor Teste"}', now(), now()),
    (fora, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'teste.fora@example.com',    '{}', now(), now());
  select count(*) into n from public.profiles where id in (adm, ed, rv, fora);
  r := r || (case when n = 4 then 'OK     · ' else 'FALHOU · ' end || 'perfil criado automaticamente para cada usuário novo (' || n || '/4)');
  select full_name into t from public.profiles where id = fora;
  r := r || (case when t = 'teste.fora' then 'OK     · ' else 'FALHOU · ' end || 'sem nome informado, o perfil usa o início do e-mail (' || coalesce(t, 'vazio') || ')');

  -- Dados de teste --------------------------------------------------------------
  insert into public.calendars (id, name) values ('teste-outro', 'Outro cliente');
  insert into public.calendar_members (calendar_id, user_id, role, cargo) values
    ('loy4biz', adm, 'admin', null), ('loy4biz', ed, 'editor', null), ('loy4biz', rv, 'reviewer', 'Gerência');
  insert into public.posts (calendar_id, theme, publish_date, publish_time, network, format, caption, export_id)
    values ('loy4biz', 'Post visível', '2026-11-27', '10:00', 'linkedin', 'image', 'Legenda', 'teste-exp-1') returning id into p1;
  insert into public.posts (calendar_id, theme, publish_date, publish_time, network, format, trashed)
    values ('loy4biz', 'Post na lixeira', '2026-11-28', '09:30', 'instagram', 'carousel', '{"at":"2026-11-12T12:00:00Z"}') returning id into p2;
  insert into public.posts (calendar_id, theme, publish_date, publish_time, network, format)
    values ('teste-outro', 'Post de outro cliente', '2026-11-29', '11:00', 'instagram', 'video') returning id into p3;
  insert into public.post_comments (post_id, kind, version, body, author_id, actor) values
    (p1, 'comment', 1, 'Comentário visível', rv, '{"name":"Revisor Teste","cargo":"Gerência"}'),
    (p2, 'comment', 1, 'Comentário em post na lixeira', ed, '{"name":"Editora Teste"}');

  -- Regras de formato ---------------------------------------------------------------
  b := false;
  begin
    insert into public.posts (calendar_id, theme, publish_date, publish_time, network, format) values ('loy4biz', 'x', '2026-12-01', '10:00', 'tiktok', 'image');
  exception when check_violation then b := true; end;
  r := r || (case when b then 'OK     · ' else 'FALHOU · ' end || 'rede fora da lista (tiktok) é recusada');
  b := false;
  begin
    insert into public.posts (calendar_id, theme, publish_date, publish_time, network, format) values ('loy4biz', repeat('T', 121), '2026-12-01', '10:00', 'linkedin', 'image');
  exception when check_violation then b := true; end;
  r := r || (case when b then 'OK     · ' else 'FALHOU · ' end || 'tema com mais de 120 caracteres é recusado (sem cortar)');
  b := false;
  begin
    insert into public.posts (calendar_id, theme, publish_date, publish_time, network, format, export_id) values ('loy4biz', 'Duplicado', '2026-12-02', '10:00', 'linkedin', 'image', 'teste-exp-1');
  exception when unique_violation then b := true; end;
  r := r || (case when b then 'OK     · ' else 'FALHOU · ' end || 'mesmo exportId no mesmo calendário não duplica');
  b := false;
  begin
    insert into public.calendar_members (calendar_id, user_id, role) values ('teste-outro', fora, 'reviewer');
  exception when check_violation then b := true; end;
  r := r || (case when b then 'OK     · ' else 'FALHOU · ' end || 'revisor precisa ter cargo');
  select publish_date::text || ' ' || to_char(publish_time, 'HH24:MI') into t from public.posts where id = p1;
  r := r || (case when t = '2026-11-27 10:00' then 'OK     · ' else 'FALHOU · ' end || 'data e horário guardados sem conversão de fuso (' || t || ')');

  -- Editora -----------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', ed, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.posts;
  r := r || (case when n = 2 then 'OK     · ' else 'FALHOU · ' end || 'editora vê os 2 posts da Loy4biz, inclusive o da lixeira (' || n || ')');
  select count(*) into n from public.posts where calendar_id = 'teste-outro';
  r := r || (case when n = 0 then 'OK     · ' else 'FALHOU · ' end || 'editora não vê posts de outro cliente');
  select count(*) into n from public.calendar_members;
  r := r || (case when n = 1 then 'OK     · ' else 'FALHOU · ' end || 'editora vê só o próprio acesso (' || n || ')');
  b := false;
  begin
    insert into public.posts (calendar_id, theme, publish_date, publish_time, network, format) values ('loy4biz', 'Direto', '2026-12-03', '10:00', 'linkedin', 'image');
  exception when insufficient_privilege then b := true; end;
  r := r || (case when b then 'OK     · ' else 'FALHOU · ' end || 'gravação direta bloqueada até para a editora (só pelas funções da etapa 3)');
  b := false;
  begin
    insert into storage.objects (bucket_id, name) values ('artes', 'loy4biz/' || p1 || '/teste.png');
    b := true;
  exception when others then b := false; t := sqlerrm; end;
  r := r || (case when b then 'OK     · ' else 'FALHOU · ' end || 'editora pode enviar arte para a pasta da Loy4biz' || case when b then '' else ' (' || coalesce(t, '') || ')' end);
  reset role;

  -- Admin --------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.calendar_members;
  r := r || (case when n = 3 then 'OK     · ' else 'FALHOU · ' end || 'admin vê todos os acessos do calendário (' || n || ')');
  reset role;

  -- Revisor -------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', rv, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.posts;
  r := r || (case when n = 1 then 'OK     · ' else 'FALHOU · ' end || 'revisor vê só o post fora da lixeira (' || n || ')');
  select count(*) into n from public.post_comments;
  r := r || (case when n = 1 then 'OK     · ' else 'FALHOU · ' end || 'revisor vê só comentários de posts visíveis (' || n || ')');
  select count(*) into n from public.profiles;
  r := r || (case when n = 3 then 'OK     · ' else 'FALHOU · ' end || 'revisor vê os nomes de quem é do mesmo calendário (' || n || ')');
  b := false;
  begin
    insert into storage.objects (bucket_id, name) values ('artes', 'loy4biz/' || p1 || '/revisor.png');
  exception when insufficient_privilege then b := true; end;
  r := r || (case when b then 'OK     · ' else 'FALHOU · ' end || 'revisor não pode enviar arte');
  b := false;
  begin
    update public.posts set status = 'approved' where id = p1;
    get diagnostics n = row_count;
    b := (n = 0);
  exception when insufficient_privilege then b := true; end;
  r := r || (case when b then 'OK     · ' else 'FALHOU · ' end || 'revisor não altera status direto (aprovação só pela função)');
  reset role;

  -- Pessoa de fora ----------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', fora, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.posts;
  r := r || (case when n = 0 then 'OK     · ' else 'FALHOU · ' end || 'usuário sem acesso não vê nenhum post');
  select count(*) into n from public.calendars;
  r := r || (case when n = 0 then 'OK     · ' else 'FALHOU · ' end || 'usuário sem acesso não vê nenhum calendário');
  reset role;

  -- Visitante sem login -------------------------------------------------------------------
  perform set_config('request.jwt.claims', '', true);
  set local role anon;
  select count(*) into n from public.posts;
  r := r || (case when n = 0 then 'OK     · ' else 'FALHOU · ' end || 'sem login, nenhum post é visível');
  select count(*) into n from public.profiles;
  r := r || (case when n = 0 then 'OK     · ' else 'FALHOU · ' end || 'sem login, nenhum nome é visível');
  reset role;

  -- Bucket ---------------------------------------------------------------------------------
  select not public into b from storage.buckets where id = 'artes';
  r := r || (case when coalesce(b, false) then 'OK     · ' else 'FALHOU · ' end || 'bucket "artes" existe e é privado');

  foreach res in array r loop raise notice '%', res; end loop;
end $$;
