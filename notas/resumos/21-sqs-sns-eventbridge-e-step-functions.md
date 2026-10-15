# Resumo 21 — SQS, SNS, EventBridge e Step Functions

## Conceitos explicados (não reexplicar depois)
- SQS: receber não remove; visibility timeout = `SET NX EX` na mensagem; resolve pendentes órfãos; redrive policy/DLQ, `ApproximateReceiveCount`; 1 MiB, 4/14 dias, 30 s/12 h, delay 15 min, lote 10; standard vs FIFO (`MessageGroupId`, 300 TPS, alta vazão 70.000 us-east-1 / 4.500 sa-east-1)
- Lambda + SQS: event source mapping, long polling 20 s, `ReportBatchItemFailures`, visibility ≥ 6× timeout, maxReceiveCount 5
- SNS: tópico, assinaturas, SNS na frente + SQS atrás, filter policy por atributo, raw message delivery, SNS→SQS sem cobrança SNS; SMS real = End User Messaging (sandbox)
- EventBridge: source/detail-type/detail, barramento default (eventos AWS grátis), regras/padrões, US$ 1/M custom; tabela SNS vs EventBridge; Pipes US$ 0,40/M; Scheduler com fuso, 14 M grátis
- Step Functions: ASL, estados, Retry/Catch com JitterStrategy FULL, saga/compensação, callback `.waitForTaskToken`, analogia reducer React; tabela Standard vs Express; StartExecution idempotente (nome + entrada)
- tabela "idempotência peça por peça"

## Estado do Rangô ao fim
- removidos: stream Valkey, `app/worker.py`, `STREAM_PEDIDOS`, serviços `Worker_*`, 3 `events.Rule` do resumo
- Valkey só idempotência + cache
- status: recebido → pago → confirmado → entregue; saídas cancelado/estornado; `iniciar` e `entrega_concluida` exigem `confirmado`
- código: `fluxo.py` (lambdas e `backend/app/`, item `ESPERA#{id}#{etapa}` token/resultado), `guardar_token.py`, `confirmar_restaurante.py` (`ErroTemporario`, env FALHA_RESTAURANTE/RECUSAR), `cancelar_pedido.py` (chave `estorno-{id}`), `avisos.py` (`AVISO#...` condicional), `varredura.py`; `main.py` `iniciar_fluxo` (name = id)
- stack: `TabelaFluxo`, endpoint `StepFunctions`, tópico `rango-producao-pedidos`, filas `rango-producao-{email,sms}` + `-dlq`, `rango-producao-entregas-dlq` (on_failure Stream), máquina `rango-producao-pedido` (Standard, pagamento 15 min, entregador 2 h, teto 6 h), Lambdas guardar-token/avisos-* fora da VPC, schedules `VarreduraPedidos` (5 min) e `Resumo{11,15,23}h` America/Sao_Paulo, tópico `rango-producao-alertas` + regra `FluxoFalhou`; context `email_alertas`
- custo ~+US$ 8/mês (1.000 pedidos/dia)
- fim: executions paradas, `cdk destroy RangoProducao` (snapshot novo), workflows desabilitados

## Casos reais e exemplos usados (não repetir)
- terça 20h40 botijão Sabor do Sertão, 6 pedidos, estorno duplo R$ 62,40 / faltou R$ 48,00; 3 e-mails perdidos no deploy
- Kinesis us-east-1 25/nov/2020 (threads)
- demos: recusa via `RECUSAR` (drift proposital), mensagem sem `tipo` → DLQ, `start-message-move-task`

## Promessas feitas
- ponte: cliente 21h10, pedido 40 min para confirmar; 10 grupos de logs, DLQ com 7 mensagens descoberta por acaso, resumo das 11h falhou quinta → CloudWatch Logs/Insights, métricas, alarmes (DLQ), dashboards, logs FastAPI, X-Ray/OpenTelemetry, SLOs (cap. 22)
