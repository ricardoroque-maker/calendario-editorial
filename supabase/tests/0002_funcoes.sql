-- =============================================================================
-- Teste da etapa 3: funções de gravação e regras do fluxo de aprovação.
-- Roda dentro de uma transação que é desfeita no final: nada fica gravado.
-- Cada linha do resultado começa com OK ou FALHOU.
-- =============================================================================
create schema teste;
grant usage on schema teste to public;

-- Executa uma chamada e devolve 'ok' ou o código do erro (hint).
create function teste.tentar(q text) returns text language plpgsql as $$
declare h text; m text;
begin
  execute q;
  return 'ok';
exception when others then
  get stacked diagnostics h = pg_exception_hint, m = message_text;
  return coalesce(nullif(h, ''), 'erro: ' || m);
end $$;

create function teste.check(cond boolean, label text) returns void language plpgsql as $$
begin
  raise notice '%', case when coalesce(cond, false) then 'OK     · ' else 'FALHOU · ' end || label;
end $$;

create function teste.como(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
$$;
grant execute on all functions in schema teste to public;

do $$
declare
  adm  uuid := gen_random_uuid();
  ed   uuid := gen_random_uuid();
  rv   uuid := gen_random_uuid();
  fora uuid := gen_random_uuid();
  pid  uuid := gen_random_uuid();
  pid2 uuid := gen_random_uuid();
  imp  uuid := gen_random_uuid();
  j jsonb; t text; n int; req uuid := gen_random_uuid(); cmt uuid;
  base jsonb := '{"theme":"Post de teste","date":"2026-12-10","time":"10:00","network":"linkedin","format":"image","title":"Título","subtitle":"","caption":"","visual":""}';
begin
  -- Pessoas e arquivos de teste (como administrador do banco) -----------------------
  insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at) values
    (adm,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'teste.admin@example.com',   '{"full_name":"Admin Teste"}',   now(), now()),
    (ed,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'teste.editor@example.com',  '{"full_name":"Editora Teste"}', now(), now()),
    (rv,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'teste.revisor@example.com', '{"full_name":"Revisor Teste"}', now(), now()),
    (fora, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'teste.fora@example.com',    '{}', now(), now());
  insert into public.calendar_members (calendar_id, user_id, role, cargo) values
    ('loy4biz', adm, 'admin', null), ('loy4biz', ed, 'editor', null), ('loy4biz', rv, 'reviewer', 'Gerência');
  insert into storage.objects (bucket_id, name) values
    ('artes', 'loy4biz/' || pid || '/arte-1.png'),
    ('artes', 'loy4biz/' || pid || '/arte-2.png'),
    ('artes', 'loy4biz/' || pid2 || '/outra.png'),
    ('artes', 'loy4biz/' || imp || '/importada.png');

  set local role authenticated;

  -- Sem acesso ---------------------------------------------------------------------
  perform teste.como(fora);
  perform teste.check(teste.tentar($q$select public.list_posts('loy4biz')$q$) = 'NOT_FOUND', 'quem não é do calendário não lista posts');
  perform teste.check(jsonb_array_length(public.my_access() -> 'calendars') = 0, 'quem não é do calendário não tem nenhum acesso');

  -- Criação -----------------------------------------------------------------------------
  perform teste.como(rv);
  perform teste.check(teste.tentar(format('select public.create_post(%L, %L, %L)', 'loy4biz', gen_random_uuid(), base)) = 'FORBIDDEN', 'revisor não cria publicação');
  perform teste.como(ed);
  perform teste.check(teste.tentar(format('select public.create_post(%L, %L, %L)', 'loy4biz', gen_random_uuid(), base || '{"theme":"   "}')) = 'INVALID', 'tema vazio é recusado');
  perform teste.check(teste.tentar(format('select public.create_post(%L, %L, %L)', 'loy4biz', gen_random_uuid(), base || '{"date":"2026-02-30"}')) = 'INVALID', 'data que não existe (30/02) é recusada');
  perform teste.check(teste.tentar(format('select public.create_post(%L, %L, %L)', 'loy4biz', gen_random_uuid(), base || '{"time":"25:00"}')) = 'INVALID', 'horário inválido é recusado');
  perform teste.check(teste.tentar(format('select public.create_post(%L, %L, %L)', 'loy4biz', gen_random_uuid(), base || '{"network":"tiktok"}')) = 'INVALID', 'rede fora da lista é recusada');
  perform teste.check(teste.tentar(format('select public.create_post(%L, %L, %L)', 'loy4biz', pid,
    base || jsonb_build_object('art', jsonb_build_array(jsonb_build_object('path', 'loy4biz/' || pid2 || '/outra.png'))))) = 'INVALID',
    'arte de outra pasta é recusada');
  perform teste.check(teste.tentar(format('select public.create_post(%L, %L, %L)', 'loy4biz', pid,
    base || jsonb_build_object('art', jsonb_build_array(jsonb_build_object('path', 'loy4biz/' || pid || '/nao-existe.png'))))) = 'INVALID',
    'arte que não foi enviada ao armazenamento é recusada');
  perform teste.check(teste.tentar(format('select public.create_post(%L, %L, %L)', 'teste-nao-existe', gen_random_uuid(), base)) = 'FORBIDDEN', 'não cria em calendário sem acesso');

  j := public.create_post('loy4biz', pid, base || jsonb_build_object('time', '9', 'art', jsonb_build_array(
         jsonb_build_object('path', 'loy4biz/' || pid || '/arte-1.png', 'name', 'arte-1.png', 'mime', 'image/png', 'w', 1080, 'h', 1350, 'size', 1234))));
  perform teste.check(j ->> 'status' = 'draft' and (j ->> 'version')::int = 1 and j ->> 'time' = '09:00', 'editora cria rascunho v1 (horário "9" vira 09:00)');
  perform teste.check(jsonb_array_length(j -> 'art') = 1 and j -> 'art' -> 0 ->> 'kind' = 'remote' and (j -> 'art' -> 0 ->> 'w')::int = 1080, 'arte fica ligada à publicação');
  perform teste.check(j ->> 'createdBy' = 'Editora Teste' and j -> 'history' -> 0 ->> 'type' = 'created', 'autoria e histórico registrados');
  perform teste.check(teste.tentar(format('select public.create_post(%L, %L, %L)', 'loy4biz', pid, base)) = 'INVALID', 'mesmo identificador não cria duas vezes');

  -- Envio e retirada --------------------------------------------------------------------
  perform teste.como(rv);
  perform teste.check(teste.tentar(format('select public.submit_post(%L)', pid)) = 'FORBIDDEN', 'revisor não envia para aprovação');
  perform teste.como(ed);
  perform teste.check(teste.tentar(format('select public.submit_post(%L)', pid)) = 'INCOMPLETE', 'sem legenda não envia');
  j := public.update_post(pid, (public.list_posts('loy4biz') -> 0) || '{"caption":"Legenda pronta"}');
  perform teste.check(j ->> 'effect' = 'saved', 'editar rascunho só salva');
  j := public.submit_post(pid);
  perform teste.check(j ->> 'status' = 'pending' and (j ->> 'version')::int = 1 and jsonb_array_length(j -> 'versions') = 1, 'envio cria a v1 aguardando aprovação');
  perform teste.check(teste.tentar(format('select public.update_post(%L, %L)', pid, j || '{"caption":"Outra"}')) = 'NEEDS_ACK', 'editar post aguardando aprovação pede confirmação');
  j := public.update_post(pid, j || '{"caption":"Outra legenda"}', false, true);
  perform teste.check(j ->> 'effect' = 'withdrawn' and j -> 'post' ->> 'status' = 'draft'
    and j -> 'post' -> 'versions' -> 0 -> 'decision' ->> 'type' = 'withdrawn', 'com confirmação, volta para Rascunho e a v1 fica como retirada');
  j := public.submit_post(pid);
  perform teste.check((j ->> 'version')::int = 2 and j -> 'history' -> -1 ->> 'type' = 'resubmitted', 'reenvio cria a v2');

  -- Decisões ------------------------------------------------------------------------------
  perform teste.check(teste.tentar(format('select public.decide_post(%L, %L)', pid, 'approved')) = 'FORBIDDEN', 'editora não aprova');
  perform teste.como(rv);
  perform teste.check(teste.tentar(format('select public.decide_post(%L, %L, null, 1)', pid, 'approved')) = 'STALE', 'decidir sobre versão antiga é recusado');
  perform teste.check(teste.tentar(format('select public.decide_post(%L, %L, %L, 2)', pid, 'changes', '   ')) = 'COMMENT_REQUIRED', 'pedir ajustes exige comentário');
  j := public.decide_post(pid, 'changes', '  Trocar a imagem.  ', 2, req);
  perform teste.check(j ->> 'status' = 'changes' and j -> 'versions' -> 1 -> 'decision' ->> 'commentId' = req::text, 'revisor pede ajustes na v2');
  j := public.decide_post(pid, 'changes', 'Trocar a imagem.', 2, req);
  select count(*) into n from jsonb_array_elements(j -> 'comments') c where c ->> 'kind' = 'changes';
  perform teste.check(n = 1, 'clique repetido não duplica o pedido de ajustes');
  perform teste.check((j -> 'comments' -> 0 ->> 'text') = 'Trocar a imagem.' and j -> 'comments' -> 0 -> 'actor' ->> 'cargo' = 'Gerência', 'comentário guarda texto limpo e o cargo de quem pediu');

  perform teste.como(ed);
  j := public.update_post(pid, (public.list_posts('loy4biz') -> 0) || jsonb_build_object('art', jsonb_build_array(
         jsonb_build_object('path', 'loy4biz/' || pid || '/arte-2.png', 'name', 'arte-2.png', 'mime', 'image/png'))));
  perform teste.check(j ->> 'effect' = 'saved' and j -> 'post' -> 'history' -> -1 -> 'fields' ? 'art', 'troca da arte em "ajustes" salva e registra o campo');
  j := public.submit_post(pid);
  perform teste.como(rv);
  j := public.decide_post(pid, 'approved', 'Pode seguir.', 3, gen_random_uuid());
  perform teste.check(j ->> 'status' = 'approved' and (j -> 'approval' ->> 'version')::int = 3 and j -> 'approval' -> 'actor' ->> 'cargo' = 'Gerência', 'revisor aprova a v3 com nome e cargo');
  perform teste.check(teste.tentar(format('select public.decide_post(%L, %L, null, 3)', pid, 'approved')) = 'ALREADY_DECIDED', 'segunda decisão na mesma versão é recusada');

  -- Edição de aprovado ------------------------------------------------------------------
  perform teste.como(ed);
  j := public.update_post(pid, (public.list_posts('loy4biz') -> 0) || '{"theme":"Tema novo"}');
  perform teste.check(j ->> 'effect' = 'saved' and j -> 'post' ->> 'status' = 'approved', 'trocar só o tema não invalida a aprovação');
  perform teste.check(teste.tentar(format('select public.update_post(%L, %L)', pid, (j -> 'post') || '{"date":"2026-12-11"}')) = 'NEEDS_ACK', 'mudar a data de aprovado pede confirmação');
  j := public.update_post(pid, (j -> 'post') || '{"date":"2026-12-11"}', true, false);
  perform teste.check(j ->> 'effect' = 'invalidated' and j -> 'post' ->> 'status' = 'draft' and (j -> 'post' -> 'invalidated' ->> 'version')::int = 3
    and j -> 'post' -> 'versions' -> 2 ->> 'invalidatedAt' is not null, 'com confirmação, a aprovação da v3 é invalidada e fica no histórico');

  -- Comentários ---------------------------------------------------------------------------
  perform teste.como(rv);
  cmt := gen_random_uuid();
  j := public.add_comment(pid, 'Comentário do revisor', null, cmt);
  j := public.add_comment(pid, 'Comentário do revisor', null, cmt);
  select count(*) into n from jsonb_array_elements(j -> 'comments') c where c ->> 'kind' = 'comment';
  perform teste.check(n = 1, 'comentário com clique repetido entra uma vez só');
  perform teste.como(ed);
  j := public.add_comment(pid, 'Resposta da editora', cmt);
  perform teste.check(j -> 'comments' -> -1 ->> 'kind' = 'reply' and j -> 'comments' -> -1 ->> 'parentId' = cmt::text, 'resposta fica ligada ao comentário');
  perform teste.check(teste.tentar(format('select public.add_comment(%L, %L, %L)', pid, 'x', gen_random_uuid())) = 'INVALID', 'resposta a comentário inexistente é recusada');
  perform teste.check(teste.tentar(format('select public.add_comment(%L, %L)', pid, '   ')) = 'INVALID', 'comentário vazio é recusado');
  perform teste.como(fora);
  perform teste.check(teste.tentar(format('select public.add_comment(%L, %L)', pid, 'Oi')) = 'NOT_FOUND', 'quem é de fora não comenta');

  -- Lixeira ------------------------------------------------------------------------------
  perform teste.como(rv);
  perform teste.check(teste.tentar(format('select public.trash_post(%L)', pid)) = 'FORBIDDEN', 'revisor não exclui');
  perform teste.como(ed);
  perform teste.check(teste.tentar(format('select public.purge_post(%L)', pid)) = 'FORBIDDEN', 'excluir de vez só a partir da lixeira');
  j := public.trash_post(pid);
  perform teste.check(j -> 'trashed' ->> 'status' = 'draft' and jsonb_array_length(public.list_posts('loy4biz')) = 0
    and jsonb_array_length(public.list_posts('loy4biz', true)) = 1, 'excluir move para a lixeira');
  perform teste.como(rv);
  perform teste.check(jsonb_array_length(public.list_posts('loy4biz')) = 0, 'revisor não vê o post da lixeira');
  perform teste.check(teste.tentar($q$select public.list_posts('loy4biz', true)$q$) = 'FORBIDDEN', 'revisor não abre a lixeira');
  perform teste.check(teste.tentar(format('select public.add_comment(%L, %L)', pid, 'Oi')) = 'NOT_FOUND', 'post na lixeira não recebe comentário');
  perform teste.como(adm);
  j := public.restore_post(pid);
  perform teste.check(j -> 'trashed' = 'null'::jsonb and j ->> 'status' = 'draft' and j -> 'history' -> -1 ->> 'type' = 'restored', 'admin restaura do jeito que estava');
  j := public.trash_post(pid);
  j := public.purge_post(pid);
  perform teste.check((j ->> 'ok')::boolean and j ->> 'folder' = 'loy4biz/' || pid, 'admin exclui de vez e recebe a pasta das artes para apagar');
  perform teste.check(teste.tentar(format('select public.restore_post(%L)', pid)) = 'NOT_FOUND', 'post excluído de vez não volta');

  -- Importação ---------------------------------------------------------------------------
  perform teste.como(ed);
  perform teste.check(teste.tentar(format('select public.import_post(%L, %L, %L, %L)', 'loy4biz', imp, base || '{"caption":"Legenda","visual":"Ideia"}',
    '{"schemaVersion":1,"exportId":"exp-teste-1","calendarId":"outro","timezone":"America/Sao_Paulo"}')) = 'INVALID', 'importação de outro calendário é recusada');
  perform teste.check(teste.tentar(format('select public.import_post(%L, %L, %L, %L)', 'loy4biz', imp, base,
    '{"schemaVersion":1,"exportId":"exp-teste-1","calendarId":"loy4biz","timezone":"America/Sao_Paulo"}')) = 'INVALID', 'importação sem legenda é recusada');
  j := public.import_post('loy4biz', imp, base || jsonb_build_object('caption', 'Legenda', 'art', jsonb_build_array(
         jsonb_build_object('path', 'loy4biz/' || imp || '/importada.png', 'name', 'importada.png'))),
       '{"schemaVersion":1,"exportId":"exp-teste-1","calendarId":"loy4biz","timezone":"America/Sao_Paulo","sourceName":"teste.json"}');
  perform teste.check(j ->> 'status' = 'draft' and j -> 'origin' ->> 'exportId' = 'exp-teste-1' and j -> 'history' -> 0 ->> 'type' = 'imported', 'importação cria rascunho com a origem');
  perform teste.check(public.find_import('loy4biz', 'exp-teste-1') ->> 'id' = imp::text, 'busca pelo exportId encontra a publicação');
  perform teste.check(teste.tentar(format('select public.import_post(%L, %L, %L, %L)', 'loy4biz', gen_random_uuid(), base || '{"caption":"x","visual":"y"}',
    '{"schemaVersion":1,"exportId":"exp-teste-1","calendarId":"loy4biz","timezone":"America/Sao_Paulo"}')) = 'DUPLICATE', 'mesmo exportId não duplica');
  perform teste.como(rv);
  perform teste.check(teste.tentar($q$select public.find_import('loy4biz', 'exp-teste-1')$q$) = 'FORBIDDEN', 'revisor não importa');

  -- Nome e acesso ------------------------------------------------------------------------
  j := public.set_my_name('  Maria   Revisora  ');
  perform teste.check(j ->> 'name' = 'Maria Revisora' and j -> 'calendars' -> 0 ->> 'role' = 'reviewer' and j -> 'calendars' -> 0 ->> 'cargo' = 'Gerência', 'revisor ajusta o próprio nome e vê seu papel e cargo');
  perform teste.check(teste.tentar($q$select public.set_my_name('   ')$q$) = 'INVALID', 'nome vazio é recusado');
  update public.profiles set full_name = 'Hacker' where id = rv;
  get diagnostics n = row_count;
  perform teste.check(n = 0, 'nome não muda por gravação direta na tabela');

  reset role;
  select actor ->> 'name' into t from public.post_comments where post_id = imp limit 1;
  perform teste.check(t is null, 'post importado ainda sem comentários');

  -- Sem login ----------------------------------------------------------------------------
  perform set_config('request.jwt.claims', '', true);
  set local role anon;
  perform teste.check(teste.tentar($q$select public.list_posts('loy4biz')$q$) like 'erro:%permission denied%', 'sem login, nenhuma função responde');
  reset role;
end $$;
