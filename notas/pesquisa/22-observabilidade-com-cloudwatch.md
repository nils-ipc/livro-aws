# Pesquisa 22 — Observabilidade com CloudWatch

## Pontos conferidos
- X-Ray SDKs e X-Ray Daemon: maintenance mode desde 25/02/2026; end of support 25/02/2027. fonte: https://aws.amazon.com/blogs/mt/announcing-aws-x-ray-sdks-daemon-end-of-support-and-opentelemetry-migration
- Maintenance mode: só correções críticas e de segurança. fonte: mesma URL
- X-Ray segue aceitando traces dos SDKs/Daemon antigos; console igual. fonte: mesma URL
- AWS recomenda OpenTelemetry (ADOT ou instrumentação OTel manual/zero-code) enviando a X-Ray. fonte: mesma URL
- Ressalva: SDKs OTel podem não ter paridade total de recursos com SDKs X-Ray. fonte: mesma URL
- Transaction Search: configuração por conta inteira; move ingestão de spans do X-Ray para preço de coleta do CloudWatch. fonte: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Enable-TransactionSearch.html
- Transaction Search: 1% dos spans indexado grátis como trace summary por padrão; percentual ajustável (console/API). fonte: mesma URL
- Spans no endpoint OTel do X-Ray: formato semantic convention, trace IDs W3C, log group `aws/spans`. fonte: mesma URL
- Lambda + Transaction Search: pode capturar 100% dos spans, independente do flag sampled. fonte: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Enable-Lambda-TransactionSearch.html (via busca; não aberto)
- Application Signals coleta Latency e Availability por serviço/operação descobertos; wizard de SLO usa direto. fonte: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-ServiceLevelObjectives.html
- SLO pode usar qualquer métrica CloudWatch ou metric expression como SLI. fonte: mesma URL
- Availability = (1 − Fault Rate) × 100; Fault = 5xx; 4xx conta como sucesso. fonte: mesma URL
- SLO por intervalo/período: meta 99%, intervalo de 1 dia, período de 1 min = threshold atingido em 99% dos períodos de 1 min do dia. fonte: mesma URL
- Burn rate 1 = consome error budget exatamente no ritmo que zera ao fim da janela; >1 esgota antes. fonte: mesma URL
- Burn rate para SLOs lançado nov/2024; alarmes com várias janelas de look-back; 28 regiões comerciais (sem Calgary e Malásia). fonte: https://aws.amazon.com/about-aws/whats-new/2024/11/application-signals-burn-rate-application-performance-goals
- Logs Insights: até 50 log groups por consulta (antes 20); timeout 60 min (antes 15), desde 2023. fonte: https://aws.amazon.com/about-aws/whats-new/2023/02/amazon-cloudwatch-increased-quotas-logs-insights
- Logs Insights QL: 100 consultas concorrentes por conta (antes 30), anúncio mar/2026, só em algumas regiões; StartQuery 10 TPS, GetQueryResults 10 TPS. fonte: https://aws.amazon.com/about-aws/whats-new/2026/03/amazon-cloudwatch-logs-increased-limits
- Logs Insights descobre no máximo 1000 campos por log group. fonte: https://docs.aws.eu/AmazonCloudWatch/latest/logs/cloudwatch_limits_cwl.html
- Anomaly detectors de log: 10 por conta, cota não ajustável. fonte: mesma URL
- Alarm treat missing data: `missing` (padrão, vira INSUFFICIENT_DATA), `notBreaching`, `breaching`, `ignore`. CDK: `TreatMissingData.MISSING` padrão. fonte: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_cloudwatch/TreatMissingData.html
- Métricas esparsas (ex.: ALB `HTTPCode_ELB_5XX_Count` sem dado quando zero): usar `notBreaching`. Fonte secundária, validar. fonte: https://www.repost.aws/articles/ARtfXuUalKQLycBz2IfuVavQ/understanding-cloudwatch-alarm-evaluation-why-alarms-delay-fire-unexpectedly-or-get-stuck

## Preços e limites (us-east-1, consulta out/2026; página oficial diz que valores são exemplos, conferir região)
- Free tier mensal Logs: 5 GB (ingestão, storage de arquivo, scans do Logs Insights); 1.800 min Live Tail. fonte: https://aws.amazon.com/cloudwatch/pricing/
- Free tier métricas: 10 custom/detailed monitoring; 1 milhão de requests de API (GetMetricData, GetMetricWidgetImage sempre cobrados). fonte: mesma URL
- Free tier: 3 dashboards custom (até 50 métricas cada); 10 alarmes standard-resolution. fonte: mesma URL
- Free tier X-Ray: 100.000 traces gravados; 1.000.000 recuperados/escaneados. fonte: mesma URL
- Free tier Application Signals: 3 meses (100 GB com spans ou 100M signals). fonte: mesma URL
- Custom metrics: $0,30 (primeiras 10.000); $0,10 (próximas 240.000); $0,05 (acima de 250.000), por métrica/mês. fonte: mesma URL
- Alarme standard: $0,10 por alarm metric/mês; high-resolution: $0,30; composite: $0,50; anomaly detection: ~$0,30 (métrica + 2 bandas). fonte: mesma URL
- Logs ingestão Standard: $0,50/GB; Infrequent Access: $0,25/GB; armazenamento arquivado: $0,03/GB. fonte: mesma URL
- Live Tail: $0,01/min após 1.800 grátis. fonte: mesma URL
- Contributor Insights: $0,50/regra (após a primeira); $0,02 por milhão de eventos (após 1 milhão). fonte: mesma URL
- X-Ray: $0,000005/trace gravado; $0,0000005/trace recuperado ou escaneado. fonte: mesma URL
- Transaction Search: ingestão $0,35/GB (0–10 TB); spans indexados $0,75 por milhão (após 1% grátis). fonte: mesma URL
- Application Signals: $1,50 por milhão de signals (primeiros 100M). fonte: mesma URL
- PutMetricData: página inconsistente ($0,01/M no texto vs $0,01 por 1.000 requests no exemplo). Não citar. fonte: mesma URL
- Logs Insights $0,005/GB escaneado e dashboard $3/mês: só fonte terceira (CloudBurn, fev/2026). fonte: https://cloudburn.io/tools/amazon-cloudwatch-pricing-calculator

## Não confirmado
- Preço oficial Logs Insights por GB escaneado ($0,005 só em fonte terceira).
- Preço oficial de dashboard custom além do free tier ($3 só em fonte terceira).
- Preço de GetMetricData e de EMF como item separado.
- Limite de resultados por consulta do Logs Insights (10.000 linhas) não verificado.
- Sintaxe exata de criação de SLO por API/CDK não verificada.
- Notas sobre Powertools for AWS Lambda / logging estruturado em FastAPI não pesquisadas (tópico estável; usar conhecimento próprio).
