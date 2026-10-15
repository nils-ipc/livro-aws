# Resumo 06 — Produção de verdade

## Conceitos explicados (não reexplicar depois)
- backup lógico (pg_dump, retrato) vs físico + WAL → PITR (analogia `git log`/checkout); regra 3-2-1; restore testado automático, mede RTO
- RPO (quanto dado perder) / RTO (quanto tempo fora); Rangô: RPO 5 min, RTO 1 h
- replicação primária/réplica, síncrona vs assíncrona, replication lag; réplica de leitura (ler da primária o que usuário acabou de escrever); failover, split brain; réplica copia DROP TABLE
- HA vs DR; tabela noves (99,9% ≈ 43,8 min/mês, 99,99% ≈ 4,4 min); disponibilidade em série multiplica; DR: backup/restore, pilot light, warm standby, ativo-ativo
- segredos: fora de código/imagem, por ambiente, rotação; Compose secrets `/run/secrets/`
- IaC = migration da infraestrutura; declarativa vs imperativa; drift; console somente leitura
- CI, entrega contínua vs deploy contínuo, pipeline, tag = hash do commit
- rolling, blue/green, canary, feature flags; expand/contract em migrations
- observabilidade: logs estruturados, métricas (4 sinais de ouro, p99), traces, OpenTelemetry; alertas sobre sintomas; alerta DLQ
- incidente: papéis, rollback antes de investigar; postmortem blameless

## Estado do Rangô ao fim
- só local, sem AWS; pedidos ainda no Redis
- compose: serviço `db` postgres:17-alpine, `POSTGRES_PASSWORD_FILE`, secret `secrets/db_password.txt`, volume `dados-db`, tabela `pedidos` de teste (5000 linhas); `api-canario` (`rango-api:0.5.0`, hostname `canario`)
- `.gitignore`: secrets/, backups/
- `scripts/backup.sh` (pg_dump --format=custom dentro do container), `scripts/testar-restore.sh` (container descartável, pg_isready -h 127.0.0.1)
- nginx upstream: `api` weight=3 (×3 IPs) + `api-canario` weight=1 → 10%
- `backend/app/logs.py` (FormatoJson); middleware `registrar_requisicao`, header `X-Request-ID`
- `backend/requirements-dev.txt` (pytest, httpx), `backend/tests/test_saude.py`
- `.github/workflows/ci.yaml`: jobs testes (redis service) e imagem (docker build, tag github.sha); sem deploy
- derrubado com `docker compose down` (volume mantido)

## Casos reais e exemplos usados (não repetir)
- sábado 3h40: dump 3 semanas, restore até 6h15, cliente no Instagram; 37 pedidos perdidos na demo
- GitLab 31/jan/2017; Knight Capital 1º/ago/2012 (>460 mi USD, SEC); CrowdStrike 19/jul/2024 (~8,5 mi máquinas)

## Promessas feitas
- ponte: lista enorme de infraestrutura; Parte I mostrou o que precisa existir, Parte II responde onde e como; abrir conta AWS e alarme de cobrança antes de qualquer servidor (cap. 7)
- RDS/PITR/Multi-AZ: cap. 12; CDK: cap. 15; Parameter Store/Secrets Manager: cap. 16; ECR/ECS/OIDC: cap. 18; CloudWatch/Logs Insights/OpenTelemetry: cap. 22; AWS Backup: cap. 23; S3 destino de backup
