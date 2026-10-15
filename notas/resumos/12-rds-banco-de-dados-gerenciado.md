# Resumo 12 — RDS: banco de dados gerenciado

## Conceitos explicados (não reexplicar depois)
- RDS: AWS cuida SO, instalação, backup, patch, failover; cliente: esquema, queries, usuários, rede, config; sem SSH/SSM; mestre = `rds_superuser`
- classes `db.` (mesmas letras EC2); T3/T4g RDS em unlimited, US$ 0,075/vCPU-h
- standard support → Extended Support pago automático (PG 12 us-east-2 US$ 0,100 → 0,200/vCPU-h); PG 18 até 28/fev/2031; minor auto na janela de manutenção; Blue/Green Deployments citado
- storage autoscaling (<10% livre, 5 min, 6 h entre aumentos), nunca diminui
- backup automático 1–35 dias, logs a cada 5 min, `LatestRestorableTime`; PITR cria instância nova; snapshot manual sobrevive; automáticos somem com instância
- Multi-AZ instance (standby síncrona, não lê, gerador de hospital, sem tempo oficial) vs Multi-AZ cluster (2 standbys legíveis, <35 s) vs read replica (assíncrona, `ReplicaLag`); tabela comparativa; Rangô sem Multi-AZ por custo, volta no cap. 24
- parameter group (família `postgres18`, default não editável, trocar exige reboot); `rds.force_ssl` 1 no 15+; `max_connections` = LEAST(mem/9531392, 5000)
- Aurora: volume cluster 6 cópias/3 AZs; Serverless v2 0 ACU, pausa 300 s padrão, resume ~15 s, conexão aberta impede
- ElastiCache: nós vs Serverless Valkey (US$ 0,084/GB-h, 0,0023/M ECPU, piso ~US$ 6/mês); TLS obrigatório, cluster mode com nó virtual único, CROSSSLOT

## Estado do Rangô ao fim
- criados/testados: subnet group `rango-db-subnets`, parameter group `rango-pg18` (log_min_duration_statement 500), `rango-db` PG 18.4 db.t4g.micro gp3 20→100 GiB, senha mestre `rango_admin` no Secrets Manager, usuário app `rango`; SG `rango-cache` (6379 de `rango-web`); serverless cache `rango-cache`
- repo: `backend/sql/001_pedidos.sql`, `backend/app/banco.py` (psycopg_pool max 5, dict_row), `requirements.txt` + `psycopg[binary,pool]`; `POST /pedidos` faz INSERT; `GET /pedidos/{id}`; idempotência e stream seguem no Valkey
- servidor: `/etc/rango/rds-ca.pem`, `api.env` com DATABASE_URL (verify-full), PGPASSWORD, REDIS_URL `rediss://`
- destruídos: `rango-db` (snapshot final `rango-db-final-cap12` MANTIDO), `rango-db-resgate`, `rango-cache`, `rango-api-01`; mantidos subnet group, parameter group, SG `rango-cache`
- local: Compose `postgres:18-alpine` (volume em `/var/lib/postgresql`, `down -v`), `api` em `rango-api:0.7.0` + DATABASE_URL/PGPASSWORD via `DB_PASSWORD`
- pendente: tirar `valkey` do user-data e `Wants=valkey.service`

## Casos reais e exemplos usados (não repetir)
- hipotético sábado 2h47: WAL por replication slot, `PANIC ... No space left on device`, cron de backup falhando 12 dias
- DELETE sem WHERE + PITR + `\copy`; failover forçado com `dig` 10.20.10.84 → 10.20.11.37 e 500 no meio

## Promessas feitas
- ponte: API sem estado; especial de TV com Cantina da Nona no sábado; dez cópias, quem distribui, tira a travada, cria mais → ALB + Auto Scaling (cap. 13); recriar banco do snapshot
- pool testar conexões + retry: cap. 13; `FreeStorageSpace` alarme: cap. 22; senha fora do api.env, por que Secrets Manager (rotação) e resto no Parameter Store: cap. 16; outbox/escrita dupla: cap. 21
