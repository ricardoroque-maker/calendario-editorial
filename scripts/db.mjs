// Aplica as migrações e roda os testes do banco no Supabase.
//
// A conexão vem de SUPABASE_DB_URL, lida do arquivo calendario-editorial.env na pasta do usuário
// (fora do OneDrive e fora do repositório) ou de uma variável de ambiente com o mesmo nome.
// O endereço e a senha nunca são impressos.
//
//   node scripts/db.mjs check            confere a conexão
//   node scripts/db.mjs migrate          aplica as migrações pendentes de supabase/migrations
//   node scripts/db.mjs test [arquivo]   roda os testes (ou um arquivo) e desfaz tudo no final
import pg from 'pg';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const ENV_FILE = process.env.CALENDARIO_ENV_FILE || join(homedir(), 'calendario-editorial.env');

function readEnvFile(path) {
  if (!existsSync(path)) return {};
  const out = {};
  for (const line of readFileSync(path, 'utf8').replace(/^﻿/, '').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
  return out;
}

function connectionString() {
  const url = process.env.SUPABASE_DB_URL || readEnvFile(ENV_FILE).SUPABASE_DB_URL;
  if (!url) {
    console.error(`Não encontrei SUPABASE_DB_URL. Crie o arquivo ${ENV_FILE} com a linha:\nSUPABASE_DB_URL=postgresql://...`);
    process.exit(2);
  }
  if (/\[YOUR-PASSWORD\]/i.test(url)) {
    console.error(`No arquivo ${ENV_FILE}, troque [YOUR-PASSWORD] pela senha do banco (sem os colchetes).`);
    process.exit(2);
  }
  return url;
}

// Certificado raiz do Supabase (público), baixado no painel: Project Settings → Database → SSL Configuration.
const CA_PATHS = [process.env.SUPABASE_DB_CA, join(ROOT, 'supabase', 'prod-ca-2021.crt'), join(homedir(), 'prod-ca-2021.crt'), join(homedir(), 'Downloads', 'prod-ca-2021.crt')].filter(Boolean);

function certificate() {
  const path = CA_PATHS.find(p => existsSync(p));
  if (!path) {
    console.error(`Falta o certificado do Supabase. No painel, abra Project Settings → Database → SSL Configuration,\nclique em "Download certificate" e salve o arquivo prod-ca-2021.crt na pasta Downloads.`);
    process.exit(2);
  }
  return readFileSync(path, 'utf8');
}

async function connect() {
  // Conexão criptografada com verificação completa do certificado do Supabase.
  const client = new pg.Client({ connectionString: connectionString(), ssl: { ca: certificate(), rejectUnauthorized: true }, application_name: 'calendario-editorial-scripts' });
  client.on('notice', n => console.log(n.message));
  try { await client.connect(); }
  catch (e) { console.error(`Não consegui conectar ao banco: ${e.message}`); process.exit(3); }
  return client;
}

async function check() {
  const c = await connect();
  const { rows } = await c.query(`select current_user as usuario, split_part(version(), ' ', 2) as postgres,
    to_regclass('public.posts') is not null as tem_estrutura`);
  const host = new URL(connectionString()).hostname; /* só o servidor; usuário e senha nunca são impressos */
  console.log(`Conectado a ${host}. PostgreSQL ${rows[0].postgres} · estrutura do calendário: ${rows[0].tem_estrutura ? 'instalada' : 'ainda não instalada'}`);
  await c.end();
}

async function migrate() {
  const c = await connect();
  c.removeAllListeners('notice'); /* avisos de "já existe" na preparação não interessam */
  await c.query(`create schema if not exists ops;
    create table if not exists ops.migrations (name text primary key, applied_at timestamptz not null default now());`);
  c.on('notice', n => console.log(n.message));
  const done = new Set((await c.query('select name from ops.migrations')).rows.map(r => r.name));
  const dir = join(ROOT, 'supabase', 'migrations');
  const files = readdirSync(dir).filter(f => f.endsWith('.sql')).sort();
  let applied = 0;
  for (const f of files) {
    if (done.has(f)) continue;
    const sql = readFileSync(join(dir, f), 'utf8');
    try {
      await c.query('begin');
      await c.query(sql);
      await c.query('insert into ops.migrations (name) values ($1)', [f]);
      await c.query('commit');
      console.log(`Aplicada: ${f}`);
      applied++;
    } catch (e) {
      await c.query('rollback');
      console.error(`Erro em ${f}: ${e.message}${e.position ? ` (posição ${e.position})` : ''}. Nada desta migração foi gravado.`);
      await c.end();
      process.exit(4);
    }
  }
  console.log(applied ? `${applied} migração(ões) aplicada(s).` : 'Nenhuma migração pendente.');
  await c.end();
}

async function test(only) {
  const c = await connect();
  const dir = join(ROOT, 'supabase', 'tests');
  const files = only ? [only] : readdirSync(dir).filter(f => f.endsWith('.sql')).sort().map(f => join(dir, f));
  let failed = false;
  for (const f of files) {
    console.log(`\n▶ ${basename(f)}`);
    const out = [];
    const onNotice = n => out.push(n.message);
    c.removeAllListeners('notice'); c.on('notice', onNotice);
    try {
      await c.query('begin');
      await c.query(readFileSync(f, 'utf8'));
    } catch (e) {
      out.push(`FALHOU · erro ao rodar o teste: ${e.message}`);
    } finally {
      await c.query('rollback'); /* nada do teste fica gravado */
    }
    out.forEach(l => console.log(l));
    if (out.some(l => l.startsWith('FALHOU')) || !out.length) failed = true;
  }
  await c.end();
  console.log(failed ? '\nAlgum teste falhou.' : '\nTodos os testes passaram.');
  process.exit(failed ? 1 : 0);
}

async function status() {
  const c = await connect();
  const { rows: [s] } = await c.query(`select
    (select count(*) from public.calendars) as calendarios,
    (select string_agg(id, ', ' order by id) from public.calendars) as ids,
    (select count(*) from public.posts) as posts,
    (select count(*) from public.calendar_members) as acessos,
    (select count(*) from auth.users) as usuarios,
    (select count(*) from storage.objects where bucket_id = 'artes') as arquivos,
    (select string_agg(name, ', ' order by name) from ops.migrations) as migracoes`);
  console.log(`Calendários: ${s.calendarios} (${s.ids || '—'}) · posts: ${s.posts} · acessos: ${s.acessos} · usuários: ${s.usuarios} · arquivos de arte: ${s.arquivos}`);
  console.log(`Migrações aplicadas: ${s.migracoes || 'nenhuma'}`);
  await c.end();
}

const [cmd, arg] = process.argv.slice(2);
if (cmd === 'status') await status();
else if (cmd === 'check') await check();
else if (cmd === 'migrate') await migrate();
else if (cmd === 'test') await test(arg);
else { console.log('Uso: node scripts/db.mjs check | migrate | test [arquivo]'); process.exit(1); }
