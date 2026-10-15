# Resumo 07 — Bem-vindo à AWS

## Conceitos explicados (não reexplicar depois)
- nuvem: infra alugada por API, autosserviço, cobrança por uso ("paga pelo que deixou ligado"), elasticidade; console/CLI/IaC = clientes da mesma API; IaaS/PaaS citados
- tabela mapa Parte II: necessidade da Parte I → serviço → capítulo
- responsabilidade compartilhada: segurança *da* nuvem (AWS) vs *na* nuvem (você); analogia Django (CSRF vs view sem checar usuário); tabela EC2/RDS/Lambda; acesso/portas/dados sempre do cliente
- Region (código us-east-1, sa-east-1) e AZ; 39 regiões, 124 AZs (out/2026); sa-east-1 desde 2011, 3 AZs; HA = várias AZs, DR = outra região; nomes de AZ embaralhados por conta, AZ ID (use1-az1); Local Zones só citadas
- por que us-east-1: padrão da doc, métricas de billing, ACM p/ CloudFront, serviços novos; sa-east-1 mais cara
- Free plan vs Paid plan (contas desde 15/jul/2025), créditos até US$ 200, suspensão + 90 dias; modelo 750 h antigo
- root user: analogia superusuário `postgres`; MFA obrigatório desde jun/2025, passkey/FIDO > TOTP, ≥2 dispositivos (até 8), só pelo console, SMS fora
- alarme de cobrança: `EstimatedCharges`, `AWS/Billing`, só us-east-1, sem projeção, assinatura SNS precisa confirmação
- AWS Budgets: previsão; templates Monthly cost e Zero spend; monitorar grátis
- console vs CLI vs CloudShell; JMESPath `--query` ≈ list comprehension; CLI v2 (pip awscli = v1)

## Estado do Rangô ao fim
- app ainda só local (Compose)
- conta AWS criada (alias `aws-root@rango.com.br`, nome `rango-estudos`, suporte Basic), account ID exemplo 123456789012
- root com MFA (2 dispositivos), sem access keys; alternate contacts; IAM access to Billing ativado
- billing alerts habilitados; tópico SNS `alertas-cobranca` (e-mail confirmado); alarme `cobranca-acima-de-10-usd` (Maximum, 21600 s, > 10 USD)
- budgets `rango-mensal` (US$ 20) + Zero spend
- AWS CLI v2 local, sem credenciais (`Unable to locate credentials`); nada a destruir

## Casos reais e exemplos usados (não repetir)
- hipotético: desenvolvedora esquece cluster + NAT Gateway, fatura 4 dígitos
- incidente DynamoDB DNS us-east-1 19–20/out/2025
- armadilhas: recurso em outra região, IPv4 US$ 0,005/h, Free plan expira, e-mail de quem saiu
- comandos: sts get-caller-identity, ec2 describe-availability-zones, cloudwatch describe-alarms/put-metric-alarm, sns create-topic/subscribe

## Promessas feitas
- ponte: CLI sem credenciais; `aws configure` pede Access Key; atalho = chave do root em `~/.aws/credentials` → `.env` → commit; robôs varrem GitHub; cap. 8: conta com chave vazada, IAM por dentro, CLI com SSO e credenciais temporárias
- NAT Gateway: cap. 10; buckets expostos: cap. 11; ACM/CloudFront: cap. 14; várias contas: cap. 23; CloudWatch: cap. 22
