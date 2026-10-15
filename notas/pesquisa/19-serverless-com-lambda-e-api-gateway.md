# Pesquisa 19 — Serverless com Lambda e API Gateway

Consulta: out/2026. Fontes oficiais priorizadas; ressalvas em "Não confirmado".

## Pontos conferidos
- Timeout máx Lambda: 900 s (15 min). Event Functions async/event source mapping com Lambda Managed Instances: até 5.400 s (90 min). fonte: https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- Memória: 128 MB a 10.240 MB, passos de 1 MB. CPU proporcional à memória. 1.769 MB = 1 vCPU. fonte: https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- Payload síncrono: 6 MB request + 6 MB response. Async: 1 MB. Streamed response: 200 MB (banda 2 MBps após 6 MB). fonte: https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- Deploy zip: 50 MB zipado (API/SDK e console); 250 MB descompactado incluindo layers. Imagem de container: 10 GB. fonte: https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- Layers: máx 5 por função. fonte: https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- /tmp: 512 MB a 10.240 MB. Env vars: 4 KB no total. fonte: https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- Concorrência padrão: 1.000 execuções simultâneas por Região (soft limit). Contas novas têm cota reduzida; AWS eleva automaticamente conforme uso. fonte: https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- Escala por função: 1.000 ambientes de execução a cada 10 s. Invocação síncrona: até 10 req/s por ambiente (total = 10 × concorrência). fonte: https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- Descompasso citado na doc: API Gateway throttle padrão 10.000 req/s vs Lambda concorrência 1.000. Solução: pedir aumento de concorrência. fonte: https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- Novidades na doc de cotas (out/2026): "Lambda Managed Instances", "Lambda MicroVMs", "Lambda Web Functions", "durable functions". Doc agora chama funções tradicionais de "Event Functions". Livro: mencionar no máximo em uma frase, sem detalhar. fonte: https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- Durable functions: até 30.000 operações por execução; 100 MB de estado por execução. Só citar como existente. fonte: https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- Runtimes Python GA: `python3.14`, `python3.13` (dep. 30/jun/2029), `python3.12` (dep. 31/out/2028), todos Amazon Linux 2023. fonte: https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html
- `python3.11` ainda AL2, dep. 30/jun/2027. `python3.10` dep. 31/out/2026. `python3.9` já deprecado (15/dez/2025). fonte: https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html
- `python3.15` e `nodejs26.x` em public preview (sem SLA, não usar em produção); GA previsto nov/2026. fonte: https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html
- Node.js: `nodejs24.x` (dep. 30/abr/2028), `nodejs22.x` (30/abr/2027). `nodejs20.x` deprecado 30/abr/2026. fonte: https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html
- Todos os runtimes gerenciados suportam x86_64 e arm64. Lambda só lança runtime novo quando a versão da linguagem entra em LTS. fonte: https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html
- Recomendação oficial: empacotar o SDK (boto3) no deploy/layer em vez de depender do SDK embutido no runtime. fonte: https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html
- Cobrança da fase INIT (cold start) desde 1/ago/2025 para todas as configurações (antes não cobrada para zip + runtime gerenciado + on-demand). Cobrada no preço de duração padrão; aparece em Billed Duration na linha REPORT. Impacto esperado pequeno. fonte: https://aws.amazon.com/blogs/compute/aws-lambda-standardizes-billing-for-init-phase/
- SnapStart para Python: GA desde nov/2024, Python 3.12+. Não suporta imagens de container. Para latência estrita, a doc recomenda provisioned concurrency. fonte: https://aws.amazon.com/about-aws/whats-new/2024/11/aws-lambda-snapstart-python-net-functions/
- Lambda Web Adapter (rodar FastAPI sem alterar código) tem hooks opcionais HTTP para SnapStart (antes do snapshot / após restore). fonte: https://aws.github.io/aws-lambda-web-adapter/features/snapstart.html
- API Gateway: REST API tem mais recursos (API keys, throttling por cliente, validação de request, integração com WAF, endpoints privados, cache). HTTP API é mais enxuta e mais barata; autorizadores: JWT, Lambda, IAM. fonte: https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-vs-rest.html

## Preços e limites (us-east-1, out/2026)
- API Gateway HTTP API: US$ 1,00 por milhão de chamadas (primeira faixa). fonte: https://aws.amazon.com/api-gateway/pricing/
- API Gateway REST API: US$ 3,50 por milhão de chamadas (primeira faixa). fonte: https://aws.amazon.com/api-gateway/pricing/
- Free tier API Gateway: 1 M chamadas REST + 1 M HTTP por mês, por até 12 meses (regra antiga). Contas novas desde 15/jul/2025: plano gratuito 6 meses com até US$ 200 em créditos. fonte: https://aws.amazon.com/api-gateway/pricing/
- API Gateway REST com cache: cobrado por hora conforme tamanho (exemplo 1,6 GB = US$ 0,038/h). Data transfer out do exemplo: US$ 0,09/GB. fonte: https://aws.amazon.com/api-gateway/pricing/
- Lambda: US$ 0,20 por milhão de requests; US$ 0,0000166667 por GB-s (x86); US$ 0,0000133334 por GB-s (arm64, ~20% menor). Free tier mensal: 1 M requests + 400.000 GB-s. Valores vindos de fontes secundárias/snippets da página oficial; conferir antes de publicar. fonte: https://aws.amazon.com/lambda/pricing/

## Não confirmado
- Timeout de integração do API Gateway (29 s padrão REST, 30 s HTTP) e limite de payload (10 MB): não verificados nesta rodada. Conferir em https://docs.aws.amazon.com/apigateway/latest/developerguide/limits.html antes de afirmar.
- HTTP API: só endpoints regionais? Não verificado.
- Preços de provisioned concurrency e armazenamento efêmero acima de 512 MB: não encontrados.
- Preço de Lambda em tiers de duração por volume: fontes divergem.
- Mangum e Powertools for AWS Lambda (Python): nada encontrado; não afirmar detalhes de API.
- Preços do API Gateway acima da primeira faixa e metering de HTTP API (blocos de 512 KB): só inferido de exemplo.
