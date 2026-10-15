# Resumo 20 — DynamoDB

## Conceitos explicados (não reexplicar depois)
- DynamoDB: chave-valor gerenciado, HTTPS + SigV4 + IAM, sem conexão; analogia dicionário de dicionários
- item, atributos livres fora da chave; partition key = hash → partição (analogia `hash()` do dict), 3 AZs; sort key ordena item collection
- teto partição ~3.000 RCU / 1.000 WCU; adaptive capacity; hot partition (pk = data)
- GetItem/PutItem/UpdateItem/DeleteItem, Query, Scan; filter expression cobra antes de filtrar; Count vs ScannedCount
- leitura eventual (padrão, 0,5) vs forte (dobro); condition expression, `ConditionalCheckFailedException`
- unidades: escrita 1 KB, leitura 4 KB, transação 2×; on-demand (~US$ 0,625/M WRU, 0,125/M RRU, out/2026; corte 50% nov/2024) vs provisionado (RCU/WCU, auto scaling, 27 reduções/dia); free tier só provisionado 25/25 + 25 GB
- padrões de acesso primeiro; single-table design (`pk`/`sk`, `PEDIDO#`, `POS#` com 13 dígitos zero-padded); regra Rangô: uma tabela por domínio
- GSI assíncrono, sempre eventual; índice esparso; projeção ALL/KEYS_ONLY/INCLUDE, escrita no índice cobrada; LSI só citado; chaves multiatributo GSI (nov/2025) dica
- palavras reservadas (`status` → `#st`); boto3 exige Decimal (`TypeError: Float types...`)
- TTL: Number epoch s, apaga em até dias, item expirado ainda lido → filtrar; LGPD
- Streams 24 h, 4 view types, outbox pronto; event source mapping, filtro, bisect, 2 leitores/shard
- quando não usar: relatórios/GROUP BY, padrões mutáveis, relações/constraints, tabela pequena

## Estado do Rangô ao fim
- `backend/app/entregas.py` (iniciar, posicao, GET atual, trajeto, `/restaurantes/{r}/entregas`, concluir); env `TABELA_ENTREGAS` (padrão `rango-entregas-local`); router em main.py; hook React `usePosicaoEntregador`
- `backend/lambdas/rango_lambda/entrega_concluida.py` (UPDATE status 'entregue' WHERE 'pago')
- stack: `TabelaEntregas` on-demand, TTL `expira_em`, stream NEW_AND_OLD_IMAGES, GSI `por-restaurante` (restaurante/iniciada_em), DESTROY; gateway endpoint `DynamoDb`; `grant_read_write_data(role_app)`; Lambda `rango-producao-entrega-concluida` com filtro em_rota→entregue, retry 5
- painel: `TabelaPainel` (pk `USUARIO#email` hash Argon2 + `restaurante`; `SESSAO#sha256(token)` TTL 8 h), `backend/app/painel.py` `POST /painel/entrar` → token Bearer, dependência `restaurante_logado`; `/restaurantes/{r}/entregas` exige sessão do próprio restaurante (403 outro); usuária `ana@cantinadanona.com.br` via `put-item`, recriar após destroy; sem MFA/limite de tentativas (cap. 23)
- rotas do entregador SEM autenticação (pendente)
- custo estimado ~US$ 33/mês (200 entregadores, 4 h/dia)
- fim: `cdk destroy RangoProducao` (snapshot novo), workflows desabilitados

## Casos reais e exemplos usados (não repetir)
- DynamoDB us-east-1 20/set/2015 (metadados, GSIs, ~55% erros)
- posição fora de ordem recusada (204); 576 mil posições/noite

## Promessas feitas
- ponte: pedido espalhado (POST síncrono, stream Valkey com pendentes órfãos, webhook Lambda, Stream descarta após 5 falhas); restaurante recusa pago, quem estorna? SMS do Bruno → SQS/DLQ, SNS, EventBridge, Step Functions (cap. 21)
- login de entregador: não prometido capítulo
