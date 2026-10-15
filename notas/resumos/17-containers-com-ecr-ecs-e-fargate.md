# Resumo 17 — Containers com ECR, ECS e Fargate

## Conceitos explicados (não reexplicar depois)
- ECR: registry privado, IAM; tag + digest; tags imutáveis (hash commit); scan on push; lifecycle (sem tag 1 d, 30 mais recentes); ~US$ 0,10/GB-mês; login token 12 h
- ECS: orquestrador, sem custo; modo EC2 vs Fargate (sem servidor, SO da AWS, imagem sua)
- cluster (nome lógico), task definition (entrada do compose, revisões `rango-api:7`, pod spec), task (execução), service (Deployment + Service K8s, papel do ASG)
- `awsvpc`: ENI + IP + SG por task; TG tipo `ip`
- execution role (imagem, segredos, logs) vs task role (código, boto3)
- `secrets` na task definition, formato `valueFrom` `:password::`, também ARN SSM; lido só no start; platform 1.4.0
- deploy rolling min 100%/max 200%; circuit breaker rollback; SIGTERM, 30 s
- Fargate ARM ~20% mais barato; por segundo, mín. 1 min, desde download; combinações CPU/memória; 20 GB efêmero
- EKS: control plane US$ 0,10/h, 14 + 12 meses, extended US$ 0,60/h; Auto Mode; quando vale; Express Mode (nov/2025) dica

## Estado do Rangô ao fim
- `backend/rds-ca.pem` + `COPY` no Dockerfile; build `buildx --platform linux/arm64`, tag `git rev-parse --short HEAD`
- `app.py`: `env` compartilhado, stack `RangoRegistro` (`registro_stack.py`, repo `rango-api`, RETAIN) MANTIDA; `versao_api` via `-c`
- `RangoProducao`: removidos user data, `configurar.sh`, LT, ASG, `role_api`, ALB manual, `ApiA`, `AsgNome`; `parametros` virou dict; endpoints EcrApi/EcrDocker/Logs (5 interface total); cluster `rango-producao`; LogGroup `LogsApp` 30 d; `RoleApp` (fotos/*); `ApplicationLoadBalancedFargateService` `ServicoApi` (512/1024, 2–6 tasks, 600 req/min, /health, `api.rango.com.br`); workers `Worker_restaurante`/`Worker_email` (256/512, sem task role); `sg_api` compartilhado; saídas Cluster, ServicoApiNome, SegredoAppArn
- `--force-new-deployment` após rotação; demo circuit breaker amd64
- AMI `rango-api-20261015` + snapshot apagados; `cdk context --clear`
- `cdk destroy RangoProducao`; snapshot novo; chave KMS PendingDeletion

## Casos reais e exemplos usados (não repetir)
- Bruno: fuso UTC, 1 linha = 1h40 via AMI `rango-api-20261103`
- OpenSSL AL2023 hipotético
- custo: API ~US$ 29, workers ~US$ 14, endpoints novos ~US$ 44, 5 endpoints ~US$ 73 ≈ 2 NAT
- erro `ResourceInitializationError: unable to pull secrets or registry auth`

## Promessas feitas
- ponte: sexta 18h, Bruno pede correção da taxa de entrega, você no aniversário da sobrinha; quem garante imagem do commit do CI → GitHub Actions, OIDC, push ECR, deploy ECS, blue/green nativo com rollback por alarme (cap. 18)
- force-new-deployment semanal até pipeline; workers → SQS: cap. 21; Fargate Spot: cap. 24 (homologação); logs: cap. 22
