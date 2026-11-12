# Calendário editorial

Calendário editorial da Supply Marketing para planejar, revisar e aprovar publicações de clientes. O primeiro cliente é a Loy4biz.

## Estado atual (etapa 3)

- Site estático em `public/index.html`: HTML, CSS e JavaScript puro, sem framework e sem etapa de build.
- Login por link no e-mail (sem senha). Quem não tem acesso liberado não vê nenhum calendário.
- Publicações, comentários, decisões, versões e histórico ficam no banco do Supabase. As artes ficam no armazenamento privado do Supabase e são lidas por links temporários.
- Toda gravação passa por funções no banco que conferem o papel de quem pede e as regras de aprovação. O site só mostra ou esconde botões.

## Modo de demonstração

`https://calendario-editorial-blue.vercel.app/?demo` (ou o `public/index.html` aberto direto no navegador) abre o protótipo antigo: exemplos, troca de visão editor/aprovador e dados só no navegador. Serve para mostrar o visual sem login.

## Como as pessoas entram

1. A pessoa abre o site, digita o e-mail e recebe um link (o e-mail do Supabase chega em inglês).
2. No primeiro acesso, ela entra mas vê "Falta liberar seu acesso".
3. Quem administra libera o acesso a partir deste computador:

```
npm run db:acesso -- pessoa@empresa.com admin
npm run db:acesso -- pessoa@empresa.com editor
npm run db:acesso -- pessoa@empresa.com revisor Gerência
npm run db:acesso -- pessoa@empresa.com remover
npm run db:acessos
```

Papéis: **admin** e **editor** criam, editam, enviam, importam, excluem e restauram. **revisor** comenta, aprova e pede ajustes; o cargo (Coordenação, Gerência ou Diretoria) aparece junto do nome.

Para o link do e-mail funcionar, o Supabase precisa conhecer o endereço do site: Authentication → URL Configuration → Site URL `https://calendario-editorial-blue.vercel.app` e, em Redirect URLs, `https://calendario-editorial-blue.vercel.app/**`.

## Publicação

A Vercel publica só a pasta `public` (padrão dela quando a pasta existe). Scripts e estrutura do banco não ficam acessíveis pelo site. O `vercel.json` só adiciona cabeçalhos de segurança e impede a indexação por buscadores.

## Próximas etapas

| Etapa | O que entra |
|---|---|
| 4 | Importação manual (JSON + PNG) com atualização pelo `exportId`: reimportar atualiza o post e volta para Rascunho |
| 5 | Rotina que lê a pasta "Calendário — Entrada" do Google Drive e cria os posts como Rascunho |
| 6 | Agendamento da rotina a cada 15 minutos pelo Supabase |

Depois: vários clientes no mesmo projeto, cada um com suas cores, logo e acessos.

## Banco de dados (Supabase)

- `supabase/migrations/`: estrutura, permissões, armazenamento das artes e funções de gravação, em ordem.
- `supabase/tests/`: testes das permissões e das regras de aprovação. Rodam numa transação desfeita no final, então nada fica gravado.

Para aplicar e testar a partir deste computador (Node 20 ou mais novo):

1. Crie o arquivo `calendario-editorial.env` na sua pasta de usuário (fora do OneDrive), com a linha `SUPABASE_DB_URL=` seguida da conexão "Session pooler" do Supabase, já com a senha.
2. O certificado público do Supabase já está em `supabase/prod-ca-2021.crt`. A conexão é verificada com ele.
3. Rode `npm install`, depois `npm run db:check`, `npm run db:migrate`, `npm run db:test` e, para ver o estado do banco, `npm run db:status`.

Projeto Supabase na região São Paulo (`sa-east-1`). O endereço do projeto e a chave publishable ficam no próprio `public/index.html`: são públicos por natureza, e quem decide o acesso são as permissões do banco.

## Segurança

Chaves secretas e senhas nunca entram no repositório. Elas ficam nas variáveis de ambiente da Vercel e do Supabase, ou no arquivo `.env` fora do OneDrive.

Pendências combinadas para antes de convidar clientes:

- Trocar a senha do banco (Project Settings → Database) e atualizar o `calendario-editorial.env`.
- Configurar envio de e-mail próprio (SMTP do Gmail). Sem isso, o Supabase só manda o link para quem é da equipe do projeto, no máximo 2 por hora.
- Desligar "Allow new users to sign up" (Authentication → Sign In / Providers) depois que os convites estiverem feitos.
