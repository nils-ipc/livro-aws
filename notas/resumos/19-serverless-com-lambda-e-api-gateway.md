# Resumo 19 — Serverless com Lambda e API Gateway

## Conceitos explicados (não reexplicar depois)
- Lambda: `handler(event, context)`, analogia view Django com request = dicionário; cobra chamada + GB-s
- ambiente de execução (Firecracker): INIT / INVOKE / SHUTDOWN; congelado entre chamadas; globais, conexão, /tmp sobrevivem
- cold start = INIT + 1ª chamada; warm start; 1 chamada por ambiente; concorrência = ambientes ocupados
- memória 128–10.240 MB, CPU proporcional, 1.769 MB = 1 vCPU; VPC sem cold start extra desde 2019
- INIT cobrado desde 1/ago/2025 (aparece em Billed Duration)
- provisioned concurrency; SnapStart Python 3.12+ (nov/2024), sem container, conexão não sobrevive
- tabela limites: 900 s, payload 6 MB/1 MB, zip 50/250 MB, imagem 10 GB, 5 layers, /tmp, env 4 KB, 1.000 concorrência/região, 1.000 ambientes/10 s; API GW 10.000 req/s vs 1.000
- runtimes python3.12/3.13/3.14 AL2023; 3.12 dep. 31/out/2028; arm64 ~20% mais barato
- layer → `/opt/python`; versões imutáveis; empacotar boto3
- chamada síncrona, assíncrona (2 retries), event source mapping (cap. 21); Managed Instances/durable functions só citadas
- API Gateway: tabela HTTP API (US$ 1,00/M) vs REST API (US$ 3,50/M); function URLs citadas; HTTP API 30 s integração, 10 MB; payload 2.0
- reserva concorrência exige 100 não reservadas
- quando vale: conta 50 req/s ≈ US$ 240/mês Lambda vs ~US$ 29 ECS; critérios; RDS Proxy citado; Lambda Web Adapter citado

## Estado do Rangô ao fim
- repo: `backend/lambdas/camada/requirements.txt` (psycopg[binary], boto3), `backend/lambdas/rango_lambda/` (banco.py, resumo_vendas.py, webhook_pagamento.py HMAC `X-Assinatura`, rds-ca.pem)
- stack `RangoProducao`: `CamadaBanco` (bundling python:3.12-slim, pip --platform aarch64), `SgLambdas`, `rango-producao-resumo-vendas` (512 MB, 60 s, retry 0, 3 regras cron UTC 14/18/2h com `{"horas": 12/4/8}`), `rango-producao-webhook-pagamento` (256 MB, 10 s, reserva 10), `SegredoWebhook` (CMK), HttpApi `rango-producao-webhooks` POST `/webhooks/pagamento`; saídas UrlWebhooks, SegredoWebhookArn
- deploy pelo pipeline; fim: `cdk destroy RangoProducao` (snapshot novo), workflows desabilitados

## Casos reais e exemplos usados (não repetir)
- worker 24 h para 6 s/dia; PIX via webhook; REPORT Init 477 ms → warm 39 ms
- armadilhas: `no pq wrapper available`, timeout 3 s, log group eterno, laço recursivo S3, estado global vazando (hipotético), cron UTC

## Promessas feitas
- ponte: rastreamento entregadores a cada 5 s, 200 entregadores = 40 gravações/s no `db.t4g.micro`, Lambdas com conexões → DynamoDB (cap. 20), inclusive quando não usar
- EventBridge Scheduler com fuso, SQS com Lambda: cap. 21; alarme de falha do resumo: cap. 22; WAF: cap. 23
