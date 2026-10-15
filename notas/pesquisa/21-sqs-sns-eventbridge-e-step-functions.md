# Pesquisa 21 — SQS, SNS, EventBridge e Step Functions

## Pontos conferidos
- SQS tamanho máx mensagem: 1.048.576 bytes (1 MiB), mín 1 byte. Não é mais 256 KB. fonte: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/quotas-messages.html
- SQS acima de 1 MiB: Extended Client Library (Java e Python), payload no S3, máx 2 GB, só clientes síncronos. fonte: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/quotas-messages.html
- SQS retenção: padrão 4 dias, mín 60 s, máx 1.209.600 s (14 dias). fonte: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/quotas-messages.html
- SQS visibility timeout: padrão 30 s, mín 0, máx 12 h. fonte: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/quotas-messages.html
- SQS delay (message timer): padrão 0, máx 15 min. fonte: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/quotas-messages.html
- SQS batch: máx 10 mensagens por requisição (Send/Delete/Receive). fonte: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/quotas-messages.html
- SQS atributos: máx 10 por mensagem. fonte: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/quotas-messages.html
- SQS standard: throughput quase ilimitado por ação (SendMessage, ReceiveMessage, DeleteMessage). fonte: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/quotas-messages.html
- SQS FIFO sem high throughput: 300 TPS por partição por ação; com batch 3.000 msg/s (300 chamadas x 10). fonte: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/quotas-messages.html
- SQS FIFO high throughput, sem batch: us-east-1, us-west-2, eu-west-1 até 70.000 TPS; us-east-2 e eu-central-1 19.000; ap-south-1/ap-southeast-1/ap-southeast-2/ap-northeast-1/eu-south-2 (Spain) 9.000; eu-west-2 e sa-east-1 4.500; demais 2.400. Com batch: 700.000 msg/s em us-east-1. fonte: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/quotas-messages.html
- SQS FIFO: MessageGroupId obrigatório, máx 128 caracteres; mensagens do mesmo grupo processadas em ordem, grupos diferentes em paralelo. fonte: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/quotas-messages.html
- SQS standard também aceita MessageGroupId: habilita "fair queues" (recurso novo, vizinho barulhento entre tenants). fonte: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/quotas-messages.html
- Lambda + SQS: visibility timeout da fila = 6x timeout da função + MaximumBatchingWindowInSeconds. Timeout da função > visibility timeout da fila gera erro ao criar/atualizar event source mapping. fonte: https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html
- Lambda + SQS: ReportBatchItemFailures devolve só as mensagens falhas; sem ele, erro devolve o lote inteiro. fonte: https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html
- Lambda + SQS: AWS recomenda maxReceiveCount >= 5 na redrive policy da fila de origem. fonte: https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html
- SNS para SQS: sem cobrança de SNS na entrega; paga só o SQS. fonte: https://aws.amazon.com/sns/pricing/ (via resultado de busca, não lida)
- EventBridge Scheduler: 14.000.000 invocações/mês grátis (todas as regiões exceto GovCloud); depois US$ 1,00 por milhão. fonte: https://aws.amazon.com/eventbridge/pricing/
- EventBridge: eventos de gerenciamento da AWS ingeridos grátis; eventos custom US$ 1,00 por milhão; entrega a serviço na mesma conta US$ 0,00; entrega a outro bus US$ 1,00 por milhão; cross-account US$ 1,00 por milhão. fonte: https://aws.amazon.com/eventbridge/pricing/
- EventBridge: cada 64 KB de payload conta como 1 evento (custom events, Pipes, API destinations). Schema Discovery usa 8 KB. fonte: https://aws.amazon.com/eventbridge/pricing/
- EventBridge Pipes: US$ 0,40 por milhão de requisições após filtro. fonte: https://aws.amazon.com/eventbridge/pricing/
- EventBridge archive/replay: publicação US$ 1,00 por milhão; processamento US$ 0,10/GB; armazenamento US$ 0,023/GB-mês. fonte: https://aws.amazon.com/eventbridge/pricing/
- EventBridge tem modelo "enhanced" novo de custom event bus cobrado por GB (ingress US$ 0,18/GB, egress US$ 0,05/GB). Livro: usar o modelo clássico por evento, citar só de passagem. fonte: https://aws.amazon.com/eventbridge/pricing/
- Step Functions Standard: US$ 0,000025 por transição de estado (US$ 0,025 por 1.000). Retry conta como transição extra. Distributed Map: 1 transição por iteração. fonte: https://aws.amazon.com/step-functions/pricing/
- Step Functions Standard free tier: 4.000 transições/mês, não expira após 12 meses. fonte: https://aws.amazon.com/step-functions/pricing/
- Step Functions Express: US$ 1,00 por milhão de execuções iniciadas, mais duração (arredondada para 100 ms, memória em blocos de 64 MB). Sem free tier citado. fonte: https://aws.amazon.com/step-functions/pricing/

## Preços e limites (us-east-1, out/2026)
- SQS: 1 milhão de requisições/mês grátis. fonte: https://aws.amazon.com/sqs/pricing/ (resultado de busca)
- SQS standard US$ 0,40 por milhão; FIFO US$ 0,50 por milhão (valores de fontes secundárias, março/2026). fonte: https://aws.amazon.com/sqs/pricing/
- SQS: cada 64 KB de payload conta como 1 requisição; requisição de 1 MiB = 16 requisições. fonte: https://aws.amazon.com/sqs/pricing/
- SNS standard: 1 milhão de requisições grátis/mês; depois US$ 0,50 por milhão; cada 64 KB = 1 requisição. fonte: https://aws.amazon.com/sns/pricing/ (fontes secundárias)
- Exemplo ilustrativo Step Functions: 100 mil execuções x 5 estados = cerca de US$ 12,50 em Standard. Conta: 500.000 x 0,000025 = US$ 12,50. fonte: https://aws.amazon.com/step-functions/pricing/

## Não confirmado
- Preços de SQS e SNS: só fontes secundárias; a página oficial não foi lida. Conferir antes de citar valores exatos.
- SNS FIFO: preços divergem entre fontes (publicação US$ 0,30 por milhão? payload por GB?); não usar. Sem free tier segundo uma fonte.
- SNS HTTP/S (100.000 grátis, US$ 0,60 por milhão) e e-mail (1.000 grátis): fonte secundária.
- Janela de deduplicação do SQS FIFO (5 minutos, por MessageDeduplicationId): não verificada nesta pesquisa.
- Lambda + SQS: parâmetro de maximum concurrency do event source mapping (ScalingConfig.MaximumConcurrency): existência confirmada só por blogs; valor mínimo (2) e máximo não conferidos. Escala padrão citada: +300 invocações concorrentes por minuto até 1.250 (fonte secundária, pode ter mudado).
- Step Functions: limite de 256 KiB de payload entre estados e semântica de Express síncrono (at-most-once) vs assíncrono (at-least-once): só fontes secundárias. Duração máx Standard 1 ano e Express 5 min: não verificado.
- Tarifa de duração do Express: página mostra valores inconsistentes entre exemplos (US$ 0,06 por GB-hora em faixas vs US$ 0,00001667 por GB-segundo). Não citar.
- Limites de EventBridge (regras por bus, targets por regra = 5, tamanho de evento 256 KB) e sintaxe de padrões de evento: não pesquisados.
