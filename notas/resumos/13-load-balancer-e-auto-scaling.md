# Resumo 13 — Load Balancer e Auto Scaling

## Conceitos explicados (não reexplicar depois)
- ELB: ALB (L7) vs NLB (L4); GWLB e Classic só citados; ALB = nós por AZ, nome DNS, nunca IP
- listener, regras, target group (analogia `APIRouter`; TG = `upstream` Nginx); round robin padrão, least outstanding requests
- health check padrão 30 s/5 s/5 sucessos; fail open; deregistration delay 300 s padrão, `draining`
- Launch Template = receita versionada (analogia serviço no compose.yaml); launch configurations bloqueadas em contas desde 1/out/2024
- ASG: mín/máx/desejada, reconciliação (analogia K8s), `--health-check-type ELB`, grace period (console 300 s, CLI 0), default instance warmup
- target tracking (termostato) `ALBRequestCountPerTarget` + `ResourceLabel`; ação agendada para pré-escalar
- golden AMI vs user data; sticky sessions `AWSALB` (remendo)
- estado escondido restante: pendentes do stream com hostname de instância removida (XAUTOCLAIM/SQS cap. 21), logs no journal (cap. 22)
- preço ALB US$ 0,0225/h + US$ 0,008/LCU-h + IPv4 por nó (~US$ 23/mês parado)

## Estado do Rangô ao fim
- repo: user-data.sh sem valkey; `banco.py` com `check=ConnectionPool.check_connection`; `infra/asg/launch-template.json`, `infra/asg/politica-requisicoes.json`; `carga/tv.js` (k6, 30 VUs)
- units sem `valkey.service`; api.env ganhou FOTOS_BUCKET, AWS_REGION
- MANTIDOS: AMI `rango-api-20261015` (contém api.env com PGPASSWORD; deploy key removida), Launch Template `rango-api`, SG `rango-alb` (80 público), `rango-web` agora só 80 de `rango-alb`; snapshot `rango-db-final-cap13`
- criados e destruídos: `rango-db` (restaurado de cap12, snapshot cap12 apagado), `rango-cache`, `rango-base`, ALB `rango-alb`, TG `rango-api` (/health, 10 s, 2/2, delay 30 s), ASG `rango-api` (2–6, privadas, grace 90, warmup 60), política alvo 600, ações `especial-tv-inicio/fim` (datas via `date -u -d 'next saturday'`, GNU; macOS: CloudShell/`gdate`; cap. 14 recria)

## Casos reais e exemplos usados (não repetir)
- plano das 10 instâncias à mão; SG esquecido → `Target.Timeout` + ciclo de substituição
- terminate-instance-in-auto-scaling-group sem erro; k6 → 2 para 6
- hipotético grace period 0 via CLI
- ELB 24/dez/2012 us-east-1 (6,8%, Netflix)
- máx. 6 por conexões RDS (`too many clients`)

## Promessas feitas
- ponte: endereço `rango-alb-...elb.amazonaws.com` em http, React local longe da região → Route 53 `rango.com.br`, ACM no ALB, CloudFront (cap. 14)
- senha fora da AMI: cap. 16; logs: cap. 22; WAF: cap. 23; SQS: cap. 21
