# Resumo 04 — Arquitetura que escala

## Conceitos explicados (não reexplicar depois)
- conta de capacidade: 80 ms/req → ~12 req/s por processo; 250 req/s → ~21 processos; lentidão aumenta fila
- escala vertical (scale up) vs horizontal (scale out); ponto único de falha (SPOF)
- GIL: 1 processo Python ≈ 1 núcleo; mais vCPUs só com `--workers` ou mais containers; 3.13 sem GIL experimental
- load balancer: DNS com vários IPs falha por TTL; proxy reverso com vários backends = balanceador
- camada 4 (TCP, sem ler HTTP) vs camada 7 (HTTP, roteia por path/Host); AWS tem os dois (cap. 13)
- round robin, least connections, hash (sticky)
- health check ativo vs passivo; readinessProbe = ativo; health check profundo derruba tudo
- stateful vs stateless (analogia função pura); estado escondido: sessões, uploads, lru_cache, tarefas agendadas
- sticky sessions = remendo (perde carrinhos, CGNAT); JWT citado
- cache, Redis (dicionário em rede com TTL), Valkey fork 2024; cache-aside (analogia @lru_cache); invalidação TTL + explícita; preço no checkout sempre da origem; cache stampede, TTL com jitter
- monolito vs microsserviços; monolito modular; serverless conceito, cold start (cap. 19)
- gargalos: pool SQLAlchemy 5+10, Postgres max_connections 100, `FATAL: sorry, too many clients already`, PgBouncer; LB como SPOF; auto scaling leva minutos, pré-escalar; chamadas lentas a terceiros

## Estado do Rangô ao fim
- só local, sem AWS
- main.py: middleware header `X-Rango-Instancia` (socket.gethostname()); `Item` (prato, quantidade); POST `/carrinho/{usuario}/itens`, GET `/carrinho/{usuario}` em Redis hash `carrinho:{usuario}` (HINCRBY, EXPIRE 3600); `/restaurantes` cache-aside chave `restaurantes`, ex=60+randint(0,10), `buscar_restaurantes()` com sleep 0.3 simulando Postgres
- requirements.txt com `redis`; env `REDIS_URL=redis://redis:6379/0`
- compose.yaml: api `rango-api:0.3.0` (`--scale api=3`), redis `redis:7.4-alpine` sem portas, proxy igual
- nginx/rango.conf: `upstream rango_api` (`server api:8000 max_fails=2 fail_timeout=10s`), proxy_connect_timeout 2s, proxy_next_upstream error timeout
- Nginx resolve `api` só ao iniciar → `docker compose restart proxy`
- tudo derrubado com `docker compose down`

## Casos reais e exemplos usados (não repetir)
- TV quinta 21h14: 5 → 250 req/s, 12 s, OOM 21h19; Ana e carrinho em 3 instâncias
- Pokémon GO jul/2016: 50× referência, 10× pior caso
- Prime Video 2023: Step Functions+Lambda → ECS, custo −90%
- k6, Locust citados

## Promessas feitas
- ponte: TV de novo, 6 instâncias ok; `POST /pedidos` síncrono: pagamento 2,5 s, restaurante 2 s, e-mail 1 s → e-mail 20 s, processos presos, listagem para, clique duplo cobra 2×; "por que e-mail atrasado derruba confirmação?" → filas e eventos (cap. 5)
- idempotência (Nginx não reenvia POST): cap. 5; alarmes e réplicas: cap. 6; ALB/auto scaling: cap. 13; ElastiCache/Valkey: cap. 12; Lambda: cap. 19; agendamentos: caps. 19 e 21
