# Resumo 14 — Route 53, CloudFront e certificados

## Conceitos explicados (não reexplicar depois)
- Route 53: autoritativo; hosted zone pública/privada; 4 NS em TLDs diferentes; registrador (Registro.br) ≠ provedor DNS
- alias: A/AAAA apontando recurso AWS, resolve CNAME no apex; analogia property Python; consultas alias ELB/CloudFront grátis; sem TTL; `EvaluateTargetHealth`; CloudFront zone ID `Z2FDTNDATAQYW2`
- health checks (30 s/10 s, >18% verificadores); políticas simples, ponderada, latência, failover (DR no DNS)
- ACM: CA + Certbot, chave privada nunca sai; validação DNS (CNAME `_x.acm-validations.aws.`), HTTP sem curinga; 198 dias desde fev/2026, renova 45 d antes; CloudFront só cert em us-east-1
- CloudFront: edge location, distribuição, origens, comportamentos, `x-cache`, `x-amz-cf-pop` (GRU); OAC (SigV4, policy `AWS:SourceArn`), OAI legado, website endpoint incompatível
- pay-as-you-go (1 TB + 10 M req grátis/mês) vs planos fixos (Free US$ 0, 1 M req/100 GB)
- SPA: assets hash `max-age=31536000, immutable`, index `no-cache`, assets antes do index, sem `--delete`; 403/404 → /index.html 200 (S3 dá 403 sem ListBucket); invalidação (1.000 caminhos/mês grátis)
- ALB listener HTTPS (`ELBSecurityPolicy-TLS13-1-2-2021-06`) + 80 redirect 301

## Estado do Rangô ao fim
- MANTIDOS: hosted zone `rango.com.br` (NS no Registro.br) com CNAMEs ACM, alias A/AAAA `rango.com.br`/`www` → CloudFront; cert ACM (apex, www, api) us-east-1; bucket `rango-front-<conta>` + policy; OAC `rango-front-oac`; distribuição `E1ABCDEF2GHIJK` (PriceClass_All, http2and3); LT `rango-api` v2 default (user data com REDIS_URL antigo + CORS); SG `rango-alb` 80+443; snapshot `rango-db-final-cap14`; CORS fotos com rango.com.br/www
- repo: `infra/asg/user-data-config.sh`, `infra/cloudfront/rango-front.json`, `infra/s3/rango-front-policy.json`, `frontend/.env.production` (`VITE_API_URL=https://api.rango.com.br`)
- destruídos: ASG, ALB, TG, cache, `rango-db`, snapshot cap13, health check, registro `api.rango.com.br`

## Casos reais e exemplos usados (não repetir)
- produtora do especial pede endereço quinta 15h; especial sábado narrado (ações recriadas, 4→6 inst., pico 7.800 req/min, CF 97% hit, 1.140 pedidos, 0 erro); desmonte domingo; RTT Recife–us-east-1 120–150 ms (hipotético)
- erro CNAME apex `InvalidChangeBatch`; `CNAMEAlreadyExists`; `InvalidViewerCertificate`; MIME text/html; subdomain takeover
- Ericsson/O2/SoftBank 6/dez/2018 (certificado vencido SGSN-MME)

## Promessas feitas
- ponte: "ninguém lembra o que foi clicado, recriar virou arqueologia"; homologação idêntica → CDK Python sobre CloudFormation, `cdk deploy`/`cdk destroy` (cap. 15); distribuição antiga precisa liberar nome (CNAMEAlreadyExists)
- config/senha via Parameter Store no boot: cap. 16; invalidação no pipeline: cap. 18; alarmes health check: cap. 22; WAF: cap. 23
