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

## Segurança

Chaves e credenciais nunca entram no repositório. Elas ficam nas variáveis de ambiente da Vercel e do Supabase, ou em um `.env.local` que o `.gitignore` já bloqueia.
