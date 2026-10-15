# Resumo 22 — Observabilidade com CloudWatch

## Conceitos explicados (não reexplicar depois)
- CloudWatch: logs, métricas, alarmes, dashboards, traces (X-Ray), SLOs; tabela pergunta → ferramenta
- log event/stream/group (analogia tabela); ingestão ~US$ 0,50/GB, armazenamento ~0,03/GB-mês, Infrequent Access 0,25; 5 GB grátis
- Logs Insights: pipe, campos JSON descobertos (até 1.000), 50 grupos, 60 min, cobra por volume escaneado; `@log`, `pct()`, `bin()`
- métrica: namespace, dimensões, período, estatística; métricas AWS grátis; custom ~US$ 0,30; EMF (linha de log vira métrica; `print`, não `logging`, com formato JSON da Lambda)
- alarme: OK/ALARM/INSUFFICIENT_DATA, M de N, treat missing data (missing/notBreaching/breaching/ignore); 10 grátis, depois ~US$ 0,10
- trace, span, trace ID, `traceparent` vs `X-Amzn-Trace-Id`; SDK/Daemon X-Ray manutenção 25/02/2026, fim 25/02/2027 → OpenTelemetry/ADOT
- Transaction Search: conta inteira, `aws/spans`, ~US$ 0,35/GB, 1% indexado grátis
- SLO, SLI, error budget (99% de 2.016 períodos 5 min/semana ≈ 20 períodos), burn rate (sexta = 100); Application Signals; disponibilidade = (1 − faults 5xx) × 100

## Estado do Rangô ao fim
- `logs.py`: chaves `timestamp/level/message/logger`, `trace_id`, `erro` (exc_info); `pedido criado` e `iniciar_fluxo` com `pedido_id`
- Lambdas: `logging` com `extra`, `LoggingFormat.JSON`, `Tracing.ACTIVE`; `confirmar_restaurante` publica EMF `Rango/SegundosAteConfirmar` (dimensão `Servico=fluxo-pedido`)
- stack: `grupo_de_logs` → `/rango/producao/api` e `/rango/producao/lambda/{nome}` (10); `taxa_5xx` (MathExpression) no `ErrosApi` (5%, 2 de 3); alarmes DLQs (3), `AlarmeResumo`, `AlarmeVarredura` (2 períodos), `AlarmeConexoesDb` (>90, 3 de 5), `AlarmeDiscoDb` (FreeStorageSpace < 2 GiB) → `rango-producao-alertas` (8 + cobrança + burn rate = 10 grátis); dashboard `rango-producao`; `tracing_enabled` na máquina; ADOT na API (`opentelemetry-instrument` no CMD, env OTEL_*, exclui health, amostragem 100%), `AWSXrayWriteOnlyPolicy`, endpoint `XRay`
- `scripts/consultar-logs.sh`
- console: Transaction Search ativo, `aws/spans` retenção 30 d, SLO `rango-confirmacao-5min` (p90 ≤ 300 s, 5 min, 7 d, 99%) + alarme burn rate 1 h > 10
- custo ~US$ 15/mês (endpoint X-Ray ~US$ 14,60)
- fim: `cdk destroy RangoProducao`, workflows desabilitados

## Casos reais e exemplos usados (não repetir)
- sexta 20h29→21h07: ConnectTimeoutError no StartExecution + varredura sem conexão no pico (20h25–21h00)
- quinta 10h50–11h25 provedor de e-mail: 7 na DLQ, resumo timeout
- demo FALHA_AVISOS=1 → alarme DLQ
- Slack 4/jan/2021 (dashboards/alertas caíram juntos)

## Promessas feitas
- ponte: segunda 8h40, 41 mil 401 de poucos IPs numa rota com senha às 3h17; fila `rango-producao-sms` apagada, ninguém lembra → CloudTrail, GuardDuty, WAF, várias contas (cap. 23)
- conexões do Postgres esgotadas sem correção definitiva; custo endpoints: cap. 24
