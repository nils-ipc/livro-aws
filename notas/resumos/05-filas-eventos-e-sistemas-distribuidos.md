# Resumo 05 — Filas, eventos e sistemas distribuídos

## Conceitos explicados (não reexplicar depois)
- síncrono vs assíncrono: garçom/comanda no trilho; `async def` não tira trabalho da requisição; rota `def` = pool 40 threads/processo
- critério: cliente precisa do resultado para resposta? pagamento sim; restaurante e e-mail não
- fila: produtor, consumidor/worker, broker (RabbitMQ, Kafka, Redis; SQS cap. 21); desacoplamento no tempo, absorção de picos (caixa d'água), competing consumers; métrica = idade da mensagem mais antiga
- pub/sub: evento no passado (`pedido.criado`), comando vs evento, analogia eventos do navegador/React; fan-out; tabela fila vs pub/sub
- ack; at-most-once vs at-least-once; exactly-once = letras miúdas
- idempotência: `status = "pago"` vs `saldo -=`; GET/PUT/DELETE idempotentes; idempotency key gerada pelo cliente; proteção perto do efeito
- retry storm; backoff exponencial + full jitter + limite
- poison message, DLQ (sem alarme não serve)
- consistência eventual, ordem não garantida (versão), escrita dupla, transactional outbox
- 8 falácias (Deutsch 1994, Gosling 8ª)

## Estado do Rangô ao fim
- só local, sem AWS
- `backend/app/externos.py`: cobrar_cartao/avisar_restaurante/enviar_email simulados, env `ATRASO_*`, `FALHA_*`
- `POST /pedidos` status 202, header `Idempotency-Key`; `SET idem:{chave} NX EX 86400`, 409 se "processando"; chave repassada ao gateway; pedido em hash `pedido:{id}` (Redis provisório, Postgres/RDS cap. 12); `XADD eventos:pedidos`
- `backend/app/worker.py` (`python -m app.worker <grupo>`): grupos `restaurante`, `email`; lê "0" depois ">"; marca `feito:{grupo}:{id}`; 5 tentativas; DLQ `eventos:pedidos:dlq`
- compose: imagem `rango-api:0.4.0`, serviços worker-restaurante, worker-email
- CORS `allow_methods=["GET", "POST"]`
- `frontend/src/ConfirmarPedido.tsx`: `useState(() => crypto.randomUUID())`
- tempo: 24,5 s → 2,5 s; tudo derrubado com `docker compose down`

## Casos reais e exemplos usados (não repetir)
- quinta 21h22 continuação; 37 reembolsos; Ana, Bruno (Sabor do Sertão)
- AWS us-east-1 7/dez/2021 (retentativas, backoff com defeito latente)
- Stripe Idempotency-Key; Brooker backoff/jitter citado nas referências
- comandos: XPENDING, XRANGE, docker compose kill/start, uuidgen

## Promessas feitas
- ponte: sábado 3h12 disco do Postgres falha, tabela de pedidos corrompida; backup no notebook de dev que saiu em março, último .sql de 3 semanas, nunca testado; quantos pedidos perder? quanto tempo fora? saber antes do cliente? deploy sexta 18h → cap. 6 (backups, réplicas, RPO/RTO, IaC, deploy, observabilidade)
- alarme DLQ: cap. 6 e 22; SQS/SNS/EventBridge/visibility timeout/Step Functions: cap. 21; `ApproximateAgeOfOldestMessage`: cap. 22; tráfego de saída: cap. 24
