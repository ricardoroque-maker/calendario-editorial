# Calendário editorial

Calendário editorial da Supply Marketing para planejar, revisar e aprovar publicações de clientes. O primeiro cliente é a Loy4biz.

## Estado atual (etapa 1)

- Site estático: `index.html` com HTML, CSS e JavaScript puro, sem framework e sem etapa de build.
- Os dados ficam **só no navegador** de quem usa (localStorage e IndexedDB). Nada é compartilhado entre pessoas ou computadores.
- Não há login. As visões de editor e aprovador são uma simulação.

## Como abrir no computador

Abra o `index.html` no navegador, ou sirva a pasta com qualquer servidor estático.

## Publicação

A Vercel publica este repositório sem configuração extra: o `index.html` na raiz é a página inicial. O `vercel.json` só adiciona cabeçalhos de segurança e impede a indexação por buscadores.

## Próximas etapas

| Etapa | O que entra |
|---|---|
| 2 | Banco de dados e armazenamento de imagens no Supabase (tabelas, permissões, bucket) |
| 3 | Login por e-mail para convidados e dados salvos no Supabase |
| 4 | Importação manual (JSON + PNG) gravando no Supabase, com atualização pelo `exportId` |
| 5 | Rotina que lê a pasta "Calendário — Entrada" do Google Drive e cria os posts como Rascunho |
| 6 | Agendamento da rotina a cada 15 minutos pelo Supabase |

Depois: vários clientes no mesmo projeto, cada um com suas cores, logo e acessos.

## Banco de dados (Supabase)

- `supabase/migrations/`: estrutura do banco, permissões e armazenamento das artes, em ordem.
- `supabase/tests/`: testes das permissões. Rodam numa transação desfeita no final, então nada fica gravado.
- `supabase/config.public.json`: endereço do projeto e chave publishable, que são públicos.

Para aplicar e testar a partir deste computador (Node 20 ou mais novo):

1. Crie o arquivo `calendario-editorial.env` na sua pasta de usuário (fora do OneDrive), com a linha `SUPABASE_DB_URL=` seguida da conexão "Session pooler" do Supabase, já com a senha.
2. O certificado público do Supabase já está em `supabase/prod-ca-2021.crt`. A conexão é verificada com ele.
3. Rode `npm install`, depois `npm run db:check`, `npm run db:migrate`, `npm run db:test` e, para ver o estado do banco, `npm run db:status`.

Projeto Supabase na região São Paulo (`sa-east-1`).

## Segurança

Chaves e credenciais nunca entram no repositório. Elas ficam nas variáveis de ambiente da Vercel e do Supabase, ou em um `.env.local` que o `.gitignore` já bloqueia.
