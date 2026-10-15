# SQS, SNS, EventBridge e Step Functions

No capítulo anterior, o rastreamento das entregas saiu do Postgres e foi para o DynamoDB, e o Stream da tabela passou a avisar uma Lambda quando a entrega termina. Na despedida, olhamos o caminho de um pedido e vimos um quebra-cabeça: chamada síncrona na API, um stream no Valkey com mensagens órfãs, um webhook numa Lambda, um Stream que descarta registros depois de cinco falhas. Neste capítulo, o pedido ganha um fluxo único, que alguém consegue enxergar de ponta a ponta.

## Terça, 20h40, sem gás na cozinha

O botijão do Sabor do Sertão acabou no meio do jantar. O Bruno ligou para o restaurante, confirmou que a cozinha só voltaria no dia seguinte e foi olhar os pedidos. Eram seis, todos pagos por PIX, todos com status `pago` no banco, e nenhum ia sair.

O worker `restaurante` tinha avisado o restaurante e marcado a mensagem como feita. Ninguém no sistema sabe o que fazer quando o restaurante recusa, então o Bruno abriu o painel do gateway e estornou os seis pagamentos à mão, um por um. Errou um deles: estornou duas vezes o mesmo pedido de R$ 62,40 e não estornou o de R$ 48,00.

Na mesma noite, um deploy da API substituiu as tasks do worker de e-mail. Três mensagens ficaram pendentes no stream do Valkey, presas ao nome de uma task que já não existia, e três clientes nunca receberam a confirmação. Ninguém ficou sabendo até a reclamação chegar pelo Instagram.

E o Bruno quer mais. Ele pediu um SMS para o cliente quando o entregador sair, e a única forma de fazer isso hoje é pendurar mais uma chamada no meio do código, com mais um jeito de falhar.

Os conceitos você já tem desde o capítulo 5. Falta a versão gerenciada de cada um e uma peça nova: alguém que conduza o pedido passo a passo e saiba desfazer o que já foi feito quando um passo falha.

## Quatro serviços, quatro trabalhos

A AWS tem um serviço para cada papel do capítulo 5, e a confusão mais comum é achar que eles competem entre si. Eles se completam:

| Pergunta | Serviço | Analogia do capítulo 5 |
|----------|---------|------------------------|
| Quem guarda o trabalho até alguém processar? | Amazon SQS | a fila, a comanda no trilho |
| Como avisar vários interessados de uma vez? | Amazon SNS | pub/sub, fan-out |
| Como rotear eventos pelo conteúdo e agendar tarefas? | Amazon EventBridge | barramento de eventos, cron |
| Quem conduz um processo de vários passos, com espera e compensação? | AWS Step Functions | (novo) o orquestrador |

### Amazon SQS: a fila

O Amazon SQS (Simple Queue Service) é a fila gerenciada mais antiga da AWS. Você cria uma fila, produtores mandam mensagens, consumidores pedem mensagens. Sem servidor, sem cluster, sem versão para atualizar.

O detalhe que muda tudo é como o consumidor confirma o processamento. No SQS, receber uma mensagem não a remove da fila. Ela fica invisível para os outros consumidores durante um prazo, o *visibility timeout*. Se o consumidor terminar e chamar `DeleteMessage` dentro do prazo, a mensagem some. Se ele morrer, travar ou demorar demais, o prazo vence e a mensagem reaparece para qualquer outro consumidor.

Você já usou essa ideia no capítulo 5, com outro nome: é um `SET NX EX` aplicado à mensagem, um lock com expiração. E ela resolve sozinha o problema dos pendentes órfãos do Valkey. No stream, a mensagem pendente pertencia a um consumidor com nome, e se esse consumidor desaparecesse alguém precisava rodar `XAUTOCLAIM`. No SQS, a mensagem não pertence a ninguém; o prazo vence e ela volta para a fila.

O prazo padrão é de 30 segundos e vai de zero a 12 horas. Ele precisa ser maior que o tempo de processamento, ou a mesma mensagem vai ser processada duas vezes em paralelo.

Cada mensagem guarda um contador, o `ApproximateReceiveCount`. Na fila, você configura uma *redrive policy*: depois de N recebimentos sem `DeleteMessage`, a mensagem vai para outra fila, a dead letter queue. É a DLQ do capítulo 5, agora como recurso de configuração em vez de código seu.

Alguns números para ter na cabeça (aproximados, conferidos em outubro de 2026):

| Item | Valor |
|------|-------|
| Tamanho máximo da mensagem | 1 MiB (era 256 KB até pouco tempo) |
| Retenção | padrão de 4 dias, de 60 segundos a 14 dias |
| Visibility timeout | padrão de 30 segundos, máximo de 12 horas |
| Atraso na entrega (*delay*) | até 15 minutos |
| Lote | até 10 mensagens por chamada |

Para mensagens maiores, guarde o conteúdo no S3 e mande só a referência. No Rangô, a mensagem carrega só o ID do pedido.

Existem dois tipos de fila. A *standard* tem vazão praticamente ilimitada e entrega cada mensagem pelo menos uma vez, sem garantia de ordem. A *FIFO* ordena dentro de um grupo: mensagens com o mesmo `MessageGroupId` saem em ordem, e grupos diferentes andam em paralelo. O preço é a vazão: sem o modo de alta vazão, 300 chamadas por segundo por ação; com ele, até 70.000 em us-east-1 e 4.500 em sa-east-1. Para o Rangô, a standard basta: ordem entre e-mails de pedidos diferentes não importa, e a duplicata, possível nos dois tipos, a idempotência resolve.

O consumidor mais simples de uma fila é uma Lambda, pelo *event source mapping* prometido no capítulo 19: um processo da AWS consulta a fila com *long polling* (a consulta espera até 20 segundos por mensagens), monta lotes e chama a função. Sem erro, o mapping apaga o lote. Com exceção, o lote inteiro volta para a fila, e uma mensagem estragada faz as outras nove serem processadas de novo. A saída é o `ReportBatchItemFailures`: a função devolve a lista das que falharam, e só elas voltam. A documentação da Lambda ainda pede um visibility timeout de pelo menos seis vezes o timeout da função, mais a janela de agrupamento do lote.

### Amazon SNS: um aviso, vários interessados

O Amazon SNS (Simple Notification Service) faz pub/sub. Você cria um *tópico*, publica mensagens nele, e cada *assinatura* recebe uma cópia. Assinaturas podem ser filas SQS, Lambdas, endpoints HTTPS, e-mail e SMS. Você já criou um tópico no capítulo 7, o `alertas-cobranca`, com uma assinatura de e-mail.

O SNS empurra a mensagem e não guarda nada; com um assinante em apuros, ele tenta por um tempo e desiste. Por isso o padrão de mercado é SNS na frente e uma fila SQS atrás de cada consumidor, que guarda até ele dar conta. A entrega do SNS para o SQS não tem cobrança de SNS; você paga só as requisições da fila.

Cada assinatura pode ter uma *filter policy*. A publicação leva atributos (pense em cabeçalhos HTTP da mensagem), e a assinatura declara quais quer receber:

```json
{"tipo": ["pedido.confirmado", "pedido.cancelado"]}
```

A fila de e-mail recebe confirmações e cancelamentos. A de SMS, só a saída do entregador. Quem publica não conhece os assinantes, que é o desacoplamento do capítulo 5: amanhã, uma fila para o programa de fidelidade assina o mesmo tópico sem ninguém mexer no publicador.

> **Na vida real:** O SNS envia SMS de verdade, mas por trás dele está o AWS End User Messaging SMS, com registro de remetente e regras próprias de cada país. Numa conta nova, o envio começa restrito a números verificados. No livro, o SMS fica simulado, como o e-mail está desde o capítulo 5.

### Amazon EventBridge: barramento e agenda

O Amazon EventBridge também entrega eventos a vários destinos, e a pergunta inevitável é por que existe mais um. A diferença está em quem decide o roteamento e com base em quê.

Um evento do EventBridge tem formato fixo: `source` (quem emitiu), `detail-type` (o tipo) e `detail` (o conteúdo, um JSON livre). Os eventos chegam a um *barramento* (*event bus*), e *regras* no barramento comparam cada evento com um padrão e mandam os que batem para até alguns alvos. O padrão olha qualquer campo, inclusive dentro do `detail`:

```json
{
  "source": ["aws.states"],
  "detail-type": ["Step Functions Execution Status Change"],
  "detail": {"status": ["FAILED", "TIMED_OUT", "ABORTED"]}
}
```

Toda conta tem um barramento `default`, e nele a própria AWS publica eventos dos serviços: uma task do ECS que parou, um objeto novo no S3 (se você ligar), uma execução do Step Functions que falhou. Esses eventos de serviço não custam nada para entrar. Você também cria barramentos próprios e publica eventos seus, por US$ 1,00 por milhão (cada 64 KB contam como um evento). Entregar a um alvo na mesma conta não custa.

Comparando com o SNS:

| | SNS | EventBridge |
|---|-----|-------------|
| Filtro | atributos da mensagem (ou corpo, se configurado) | qualquer campo do evento |
| Eventos dos serviços da AWS | não | sim, no barramento `default` |
| Arquivar e reprocessar eventos | não | sim (archive e replay) |
| Alvos | filas, Lambdas, HTTPS, e-mail, SMS | dezenas de serviços da AWS, APIs externas |
| Latência e volume | menor latência, vazão muito alta | um pouco mais de latência |

A regra prática que uso: SNS quando o publicador é seu e você quer fan-out simples e rápido; EventBridge quando o evento vem da AWS ou quando o roteamento depende do conteúdo. No Rangô, os dois aparecem.

O EventBridge Pipes liga uma fonte (um Stream do DynamoDB, uma fila) a um alvo, com filtro no meio, por US$ 0,40 por milhão de eventos. É a resposta à armadilha do capítulo 20: quando o Stream precisa de muitos leitores, um pipe publica num barramento, e as regras distribuem.

E o EventBridge Scheduler. O capítulo 19 agendou o resumo de vendas com regras de cron em UTC, e você converteu 11h em 14h de cabeça. O Scheduler aceita fuso horário (`America/Sao_Paulo`), agendamentos únicos e recorrentes, e tem 14 milhões de invocações gratuitas por mês; depois, US$ 1,00 por milhão.

### AWS Step Functions: o pedido como máquina de estados

SQS, SNS e EventBridge levam mensagens de um lugar a outro. Nenhum deles responde à pergunta do botijão: o restaurante recusou um pedido pago, quem estorna? Para isso é preciso alguém que lembre em que ponto o pedido está e decida o próximo passo, inclusive o passo de desfazer.

O AWS Step Functions faz isso com uma *máquina de estados*. Você descreve o processo em JSON, na Amazon States Language: estados `Task` (fazer algo, como chamar uma Lambda ou publicar no SNS), `Choice` (um `if`), `Wait`, `Parallel`, `Map`, `Succeed` e `Fail`. Cada pedido vira uma *execução*, com histórico de cada passo, entrada e saída, visível no console como um diagrama com o passo atual pintado.

Pense num reducer do React com efeitos colaterais, cujo estado vive na AWS e sobrevive a deploys, quedas de task e dias de espera. O tratamento de erro é declarativo. Um estado `Task` ganha `Retry` e `Catch`:

```json
"ConfirmarRestaurante": {
  "Type": "Task",
  "Resource": "arn:aws:states:::lambda:invoke",
  "Retry": [{
    "ErrorEquals": ["ErroTemporario"],
    "IntervalSeconds": 5,
    "MaxAttempts": 4,
    "BackoffRate": 2,
    "JitterStrategy": "FULL"
  }],
  "Catch": [{"ErrorEquals": ["States.ALL"], "ResultPath": "$.erro", "Next": "Estornar"}],
  "Next": "RestauranteAceitou"
}
```

É o backoff exponencial com full jitter do capítulo 5, sem uma linha de Python. O nome do erro é o nome da classe da exceção que a Lambda lançou. Se as tentativas acabam, o `Catch` desvia para outro estado.

Desviar para o estorno tem nome: *compensação*. Num banco de dados, uma transação desfaz tudo com `ROLLBACK`. Entre sistemas diferentes (o seu banco, o gateway, o restaurante), não existe rollback; cada passo feito precisa de um passo contrário, executado quando algo adiante falha. Essa sequência de passos com compensações é chamada de *saga*. O estorno é a compensação do pagamento.

A outra peça que o pedido precisa é esperar. O pagamento chega por webhook, minutos depois; o entregador sai quando o prato fica pronto. O Step Functions resolve com o *callback*: um estado `Task` com o sufixo `.waitForTaskToken` gera um token, entrega esse token a quem você indicar e fica parado até alguém chamar `SendTaskSuccess` (ou `SendTaskFailure`) com ele. A execução esperando não consome nada além do registro.

Existem dois tipos de máquina:

| | Standard | Express |
|---|----------|---------|
| Para quê | processos longos, com espera e auditoria | fluxos curtos e de volume muito alto |
| Cobrança | US$ 0,025 por 1.000 transições de estado | US$ 1,00 por milhão de execuções, mais duração |
| Gratuito | 4.000 transições por mês, sem prazo | não tem |
| Callback (`.waitForTaskToken`) | sim | não |
| Histórico por passo no console | sim | via CloudWatch Logs |
| `StartExecution` com mesmo nome | idempotente | não idempotente |

O pedido do Rangô espera webhook e entregador, então vai de Standard. A conta é por transição: cada passo concluído conta, e cada nova tentativa de um `Retry` também.

## Mão na massa

### O desenho

O pedido passa a ter um fluxo só:

```text
POST /pedidos ──► Postgres (recebido) ──► StartExecution(name = id do pedido)
                                                   │
                ┌──────────────────────────────────┘
                ▼
        AguardarPagamento ◄──── webhook do PIX (SendTaskSuccess)
           │ pago        │ recusado / 15 min
           ▼             ▼
  ConfirmarRestaurante   Cancelar ──► SNS: pedido.cancelado
   │ aceito   │ recusou / falhou
   │          ▼
   │       Estornar ──► SNS: pedido.cancelado
   ▼
  SNS: pedido.confirmado
   ▼
  AguardarEntregador ◄── POST /entregas/{id}/iniciar (SendTaskSuccess)
   ▼
  SNS: entrega.iniciada ──► Sucesso

  Tópico rango-producao-pedidos ──► fila email ──► Lambda avisos-email (DLQ)
                                └─► fila sms   ──► Lambda avisos-sms   (DLQ)
```

O stream do Valkey e os dois workers no ECS vão embora. O Valkey continua com a idempotência da API e o cache.

### O ponto de partida

Como no capítulo anterior, encontre o snapshot deixado pelo `cdk destroy`:

```bash
aws rds describe-db-snapshots --snapshot-type manual \
  --query "reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[0].DBSnapshotIdentifier" \
  --output text
```

Coloque o nome no `snapshot_db` do `rango-infra/app.py`. No `rango-infra/cdk.json`, acrescente ao `context` o e-mail que vai receber alertas:

```json
"email_alertas": "alertas@rango.com.br"
```

### A espera, guardada no DynamoDB

O callback cria um problema de corrida. O fluxo começa, chega ao `AguardarPagamento` e entrega o token a uma Lambda, que o guarda. Se o webhook do pagamento chegar antes de o token estar guardado (um cartão aprovado em dois segundos, uma Lambda em cold start), quem avisa o fluxo?

A solução é um item no DynamoDB por espera, com dois campos: `token`, gravado pelo fluxo, e `resultado`, gravado por quem traz a notícia. Cada lado grava o seu campo e lê o item inteiro na mesma operação atômica. Quem chegar por último encontra os dois e chama o `SendTaskSuccess`. Crie `backend/lambdas/rango_lambda/fluxo.py`:

```python
import json
import os
import time

import boto3

REGIAO = os.environ.get("AWS_REGION", "us-east-1")
tabela = boto3.resource("dynamodb", region_name=REGIAO).Table(
    os.environ.get("TABELA_FLUXO", "rango-fluxo-local")
)
sfn = boto3.client("stepfunctions", region_name=REGIAO)
EsperaEncerrada = (
    sfn.exceptions.TaskTimedOut,
    sfn.exceptions.TaskDoesNotExist,
    sfn.exceptions.InvalidToken,
)
PRAZO_SEGUNDOS = 2 * 86400


def _registrar(pedido_id, etapa: str, campo: str, valor: str) -> dict:
    return tabela.update_item(
        Key={"pk": f"ESPERA#{pedido_id}#{etapa}"},
        UpdateExpression="SET #c = :v, expira_em = :e",
        ExpressionAttributeNames={"#c": campo},
        ExpressionAttributeValues={":v": valor, ":e": int(time.time()) + PRAZO_SEGUNDOS},
        ReturnValues="ALL_NEW",
    )["Attributes"]


def _concluir(item: dict) -> None:
    if "token" in item and "resultado" in item:
        try:
            sfn.send_task_success(taskToken=item["token"], output=item["resultado"])
        except EsperaEncerrada:
            pass  # aviso repetido ou prazo vencido: nada a fazer


def guardar_token(pedido_id, etapa: str, token: str) -> None:
    _concluir(_registrar(pedido_id, etapa, "token", token))


def avisar(pedido_id, etapa: str, resultado: dict) -> None:
    _concluir(_registrar(pedido_id, etapa, "resultado", json.dumps(resultado)))
```

O `UpdateItem` com `ReturnValues="ALL_NEW"` grava e devolve o item como ficou, de uma vez; como o DynamoDB serializa gravações no mesmo item, só a segunda vê os dois campos. Um webhook reenviado gera um `SendTaskSuccess` repetido, que recebe erro de token encerrado e é ignorado. A Lambda da espera, `guardar_token.py`:

```python
from fluxo import guardar_token


def handler(event, context):
    guardar_token(event["pedido_id"], event["etapa"], event["token"])
```

Sem Postgres, ela roda fora da VPC e sem layer. A API também avisa o fluxo, então o `fluxo.py` vai ser copiado para `backend/app/`, a mesma duplicação que o `banco.py` já tem.

### Os passos que mexem no banco

`backend/lambdas/rango_lambda/confirmar_restaurante.py` simula a conversa com o tablet do restaurante, como o `externos.py` do capítulo 5:

```python
import os
import random

from banco import conexao


class ErroTemporario(Exception):
    pass


def perguntar_ao_restaurante(restaurante: str) -> bool:
    # Simulado. Com FALHA_RESTAURANTE=0.5, metade das chamadas falha.
    if random.random() < float(os.environ.get("FALHA_RESTAURANTE", "0")):
        raise ErroTemporario("tablet do restaurante não respondeu")
    return restaurante != os.environ.get("RECUSAR", "")


def handler(event, context):
    pedido_id = event["pedido_id"]
    pedido = conexao().execute(
        "SELECT restaurante, status FROM pedidos WHERE id = %s", (pedido_id,)
    ).fetchone()
    if pedido["status"] == "confirmado":
        return {"aceito": True}  # repetição de um passo que já deu certo
    aceito = perguntar_ao_restaurante(pedido["restaurante"])
    if aceito:
        conexao().execute(
            "UPDATE pedidos SET status = 'confirmado' WHERE id = %s AND status = 'pago'",
            (pedido_id,),
        )
    return {"aceito": aceito}
```

A primeira checagem cobre o passo repetido: a Lambda grava `confirmado`, morre antes de responder, e o `Retry` chama de novo.

E `cancelar_pedido.py`, que serve aos dois caminhos de cancelamento:

```python
import json

from banco import conexao


def estornar_cobranca(pedido_id: str) -> None:
    # Simulado. No gateway real, a chave de idempotência impede estorno em dobro.
    print(json.dumps({"estorno": pedido_id, "idempotency_key": f"estorno-{pedido_id}"}))


def handler(event, context):
    pedido_id, estornar = event["pedido_id"], event["estornar"]
    if estornar:
        estornar_cobranca(pedido_id)
    novo = "estornado" if estornar else "cancelado"
    conexao().execute(
        "UPDATE pedidos SET status = %s WHERE id = %s"
        " AND status IN ('recebido', 'pago', 'recusado')",
        (novo, pedido_id),
    )
    return {"status": novo}
```

A chave `estorno-{pedido_id}` é o que teria salvado o Bruno na terça: se o passo rodar duas vezes, o gateway reconhece a chave e devolve o primeiro estorno em vez de fazer outro.

Para os avisos, `avisos.py`, que atende o e-mail e o SMS:

```python
import json
import os
import time

import boto3

tabela = boto3.resource("dynamodb").Table(os.environ["TABELA_FLUXO"])
JaEnviado = tabela.meta.client.exceptions.ConditionalCheckFailedException
CANAL = os.environ["CANAL"]


def enviar(tipo: str, pedido: dict) -> None:
    # Simulado, como o enviar_email do capítulo 5.
    if os.environ.get("FALHA_AVISOS") == "1":
        raise RuntimeError(f"provedor de {CANAL} fora do ar")
    print(json.dumps({"canal": CANAL, "tipo": tipo, "pedido_id": pedido["pedido_id"]}))


def processar(registro: dict) -> None:
    tipo = registro["messageAttributes"]["tipo"]["stringValue"]
    pedido = json.loads(registro["body"])
    chave = {"pk": f"AVISO#{CANAL}#{tipo}#{pedido['pedido_id']}"}
    try:
        tabela.put_item(
            Item={**chave, "expira_em": int(time.time()) + 7 * 86400},
            ConditionExpression="attribute_not_exists(pk)",
        )
    except JaEnviado:
        return
    try:
        enviar(tipo, pedido)
    except Exception:
        tabela.delete_item(Key=chave)
        raise


def handler(event, context):
    falhas = []
    for registro in event["Records"]:
        try:
            processar(registro)
        except Exception as erro:
            print(f"falha em {registro['messageId']}: {erro!r}")
            falhas.append({"itemIdentifier": registro["messageId"]})
    return {"batchItemFailures": falhas}
```

O `put_item` condicional é o `SET NX` do capítulo 5 no DynamoDB: marca o aviso antes de enviar, e a duplicata encontra a marca e sai. Se o envio falha, a marca é apagada. Sobra uma janela pequena (o ambiente morrer entre enviar e terminar) para um e-mail duplicado, o que é aceitável.

> **Dica:** O Powertools for AWS Lambda (Python), biblioteca de código aberto mantida pela AWS, tem um utilitário de idempotência que faz esse controle com uma tabela do DynamoDB e um decorator. Conheça antes de escrever o seu terceiro controle à mão.

### A máquina de estados na stack

No `rango-infra/rango_infra/rango_infra_stack.py`, acrescente os imports:

```python
from aws_cdk import (
    # ... os imports do capítulo 20 ...
    ArnFormat,
    TimeZone,
    aws_scheduler as scheduler,
    aws_scheduler_targets as agendados,
    aws_sns as sns,
    aws_sns_subscriptions as assinaturas,
    aws_sqs as sqs,
    aws_stepfunctions as sfn,
    aws_stepfunctions_tasks as tarefas,
)
```

Apague o laço dos workers do capítulo 17 (o `for grupo in ("restaurante", "email")` inteiro) e as três `events.Rule` do resumo de vendas do capítulo 19. Depois do bloco do webhook, a tabela do fluxo, o endpoint e o tópico:

```python
        tabela_fluxo = dynamodb.Table(
            self,
            "TabelaFluxo",
            partition_key=dynamodb.Attribute(name="pk", type=dynamodb.AttributeType.STRING),
            billing_mode=dynamodb.BillingMode.PAY_PER_REQUEST,
            time_to_live_attribute="expira_em",
            removal_policy=RemovalPolicy.DESTROY,
        )

        vpc.add_interface_endpoint(
            "StepFunctions",
            service=ec2.InterfaceVpcEndpointAwsService.STEP_FUNCTIONS,
            subnets=privadas,
        )

        topico_pedidos = sns.Topic(self, "TopicoPedidos", topic_name=f"rango-{ambiente}-pedidos")
```

O endpoint serve à API e ao webhook, que chamam o Step Functions de dentro das subnets sem internet. Quando o Step Functions publica no SNS, a conversa não passa pela VPC.

As Lambdas que não usam o banco ficam fora da VPC, com um auxiliar próprio:

```python
        def funcao_leve(id_: str, nome: str, handler: str, **extras) -> lambda_.Function:
            fn = lambda_.Function(
                self,
                id_,
                function_name=f"rango-{ambiente}-{nome}",
                runtime=lambda_.Runtime.PYTHON_3_12,
                architecture=lambda_.Architecture.ARM_64,
                handler=handler,
                code=codigo_lambdas,
                environment={
                    "TABELA_FLUXO": tabela_fluxo.table_name,
                    **extras.pop("environment", {}),
                },
                log_group=logs.LogGroup(
                    self,
                    f"Logs{id_}",
                    retention=logs.RetentionDays.ONE_MONTH,
                    removal_policy=RemovalPolicy.DESTROY,
                ),
                **extras,
            )
            tabela_fluxo.grant_read_write_data(fn)
            return fn

        arn_maquina = self.format_arn(
            service="states",
            resource="stateMachine",
            resource_name=f"rango-{ambiente}-pedido",
            arn_format=ArnFormat.COLON_RESOURCE_NAME,
        )
        guardar = funcao_leve(
            "GuardarToken", "guardar-token", "guardar_token.handler",
            memory_size=256, timeout=Duration.seconds(10),
        )
        guardar.add_to_role_policy(
            iam.PolicyStatement(actions=["states:SendTaskSuccess"], resources=[arn_maquina])
        )

        confirmar_restaurante = funcao(
            "FnConfirmarRestaurante", "confirmar-restaurante", "confirmar_restaurante.handler",
            memory_size=256, timeout=Duration.seconds(15),
        )
        cancelar_pedido = funcao(
            "FnCancelarPedido", "cancelar-pedido", "cancelar_pedido.handler",
            memory_size=256, timeout=Duration.seconds(15),
        )
```

O prefixo `Fn` nos IDs evita colisão com os passos da máquina, que vão usar `ConfirmarRestaurante` como ID; dois constructs com o mesmo ID na mesma stack quebram o `cdk synth`. O ARN da máquina foi montado pelo nome, e não com `maquina.grant_task_response(guardar)`, por causa de uma dependência circular: a máquina precisa da função para existir, a função depende da policy da sua role, e a policy precisaria do ARN da máquina. O CloudFormation recusa o template. Montar o ARN pelo nome quebra o círculo.

Agora os passos e a máquina. Três auxiliares evitam repetição:

```python
        def publicar(id_: str, tipo: str) -> tarefas.SnsPublish:
            return tarefas.SnsPublish(
                self,
                id_,
                topic=topico_pedidos,
                message=sfn.TaskInput.from_object(
                    {"pedido_id": sfn.JsonPath.string_at("$.pedido_id")}
                ),
                message_attributes={"tipo": tarefas.MessageAttribute(value=tipo)},
                result_path=sfn.JsonPath.DISCARD,
            )

        def esperar(id_: str, etapa: str, prazo: Duration) -> tarefas.LambdaInvoke:
            return tarefas.LambdaInvoke(
                self,
                id_,
                lambda_function=guardar,
                integration_pattern=sfn.IntegrationPattern.WAIT_FOR_TASK_TOKEN,
                payload=sfn.TaskInput.from_object({
                    "pedido_id": sfn.JsonPath.string_at("$.pedido_id"),
                    "etapa": etapa,
                    "token": sfn.JsonPath.task_token,
                }),
                task_timeout=sfn.Timeout.duration(prazo),
                result_path=f"$.{etapa}",
            )

        def cancelar(id_: str, estornar: bool) -> sfn.Chain:
            passo = tarefas.LambdaInvoke(
                self,
                id_,
                lambda_function=cancelar_pedido,
                payload=sfn.TaskInput.from_object({
                    "pedido_id": sfn.JsonPath.string_at("$.pedido_id"),
                    "estornar": estornar,
                }),
                result_path=sfn.JsonPath.DISCARD,
            )
            passo.add_retry(
                interval=Duration.seconds(10), max_attempts=6, backoff_rate=2,
                jitter_strategy=sfn.JitterType.FULL,
            )
            return passo.next(publicar(f"Publicar{id_}", "pedido.cancelado")).next(
                sfn.Succeed(self, f"Fim{id_}")
            )
```

O cancelamento termina em `Succeed`, e isso é deliberado. Um pedido cancelado é um desfecho previsto do negócio. `Fail` fica para o que ninguém previu, e é nele que o alerta vai disparar.

O fluxo, montado de trás para frente:

```python
        estornar = cancelar("Estornar", estornar=True)
        cancelar_sem_pagamento = cancelar("Cancelar", estornar=False)

        entrega = (
            publicar("PublicarConfirmado", "pedido.confirmado")
            .next(esperar("AguardarEntregador", "entregador", Duration.hours(2)))
            .next(publicar("PublicarSaida", "entrega.iniciada"))
            .next(sfn.Succeed(self, "PedidoEmRota"))
        )

        confirmar = tarefas.LambdaInvoke(
            self,
            "ConfirmarRestaurante",
            lambda_function=confirmar_restaurante,
            payload_response_only=True,
            result_path="$.restaurante",
        )
        confirmar.add_retry(
            errors=["ErroTemporario"], interval=Duration.seconds(5), max_attempts=4,
            backoff_rate=2, jitter_strategy=sfn.JitterType.FULL,
        )
        confirmar.add_catch(estornar, errors=["States.ALL"], result_path="$.erro")
        confirmar.next(
            sfn.Choice(self, "RestauranteAceitou")
            .when(sfn.Condition.boolean_equals("$.restaurante.aceito", True), entrega)
            .otherwise(estornar)
        )

        pagamento = esperar("AguardarPagamento", "pagamento", Duration.minutes(15))
        pagamento.add_catch(cancelar_sem_pagamento, errors=["States.Timeout"], result_path="$.erro")
        pagamento.next(
            sfn.Choice(self, "PagamentoAprovado")
            .when(sfn.Condition.string_equals("$.pagamento.status", "pago"), confirmar)
            .otherwise(cancelar_sem_pagamento)
        )

        maquina = sfn.StateMachine(
            self,
            "FluxoPedido",
            state_machine_name=f"rango-{ambiente}-pedido",
            definition_body=sfn.DefinitionBody.from_chainable(pagamento),
            timeout=Duration.hours(6),
        )
```

Leia de baixo para cima e você tem o desenho do começo da seção. O estado da execução começa como `{"pedido_id": "..."}`, e cada `result_path` acrescenta um campo (`pagamento`, `restaurante`, `erro`) que o `Choice` lê. O `task_timeout` do pagamento é o PIX nunca pago: em 15 minutos, `States.Timeout` e cancelamento sem estorno. O CDK gera a Amazon States Language e a role da máquina, com permissão para as três Lambdas e o tópico.

### Avisos: SNS na frente, SQS atrás

Uma fila com DLQ por canal, cada uma assinando o tópico com o seu filtro, e uma Lambda consumindo cada fila:

```python
        for canal, tipos in (
            ("email", ["pedido.confirmado", "pedido.cancelado"]),
            ("sms", ["entrega.iniciada"]),
        ):
            dlq = sqs.Queue(
                self, f"Dlq_{canal}",
                queue_name=f"rango-{ambiente}-{canal}-dlq",
                retention_period=Duration.days(14),
            )
            fila = sqs.Queue(
                self, f"Fila_{canal}",
                queue_name=f"rango-{ambiente}-{canal}",
                visibility_timeout=Duration.minutes(2),
                dead_letter_queue=sqs.DeadLetterQueue(queue=dlq, max_receive_count=5),
            )
            topico_pedidos.add_subscription(
                assinaturas.SqsSubscription(
                    fila,
                    raw_message_delivery=True,
                    filter_policy={"tipo": sns.SubscriptionFilter.string_filter(allowlist=tipos)},
                )
            )
            avisos = funcao_leve(
                f"Avisos_{canal}", f"avisos-{canal}", "avisos.handler",
                memory_size=256, timeout=Duration.seconds(20),
                environment={"CANAL": canal},
            )
            avisos.add_event_source(
                fontes.SqsEventSource(fila, batch_size=10, report_batch_item_failures=True)
            )
```

Função de 20 segundos, fila de dois minutos: a regra das seis vezes. O `max_receive_count=5` segue a recomendação da AWS para filas lidas pela Lambda; com menos, uma rajada de throttling manda mensagens boas para a DLQ, que guarda por 14 dias, o máximo. O `raw_message_delivery=True` entrega só o corpo publicado, sem o envelope do SNS, e transforma os atributos em atributos da mensagem SQS, onde o `avisos.py` lê o `tipo`.

Aproveite para fechar o furo do capítulo 20. No `DynamoEventSource` da `entrega_concluida`, acrescente um destino para as falhas:

```python
        falhas_entregas = sqs.Queue(
            self, "FalhasEntregas",
            queue_name=f"rango-{ambiente}-entregas-dlq",
            retention_period=Duration.days(14),
        )
```

```python
                # dentro do fontes.DynamoEventSource(...) do capítulo 20
                on_failure=fontes.SqsDlq(falhas_entregas),
```

Para streams, a fila recebe a descrição do lote que falhou (shard e números de sequência), sem o registro: o suficiente para reler o Stream em até 24 horas.

### A API e o webhook avisam o fluxo

As permissões e variáveis, ainda na stack:

```python
        maquina.grant_start_execution(role_app)
        maquina.grant_task_response(role_app)
        tabela_fluxo.grant_read_write_data(role_app)
        container_api = tarefa_api.default_container
        container_api.add_environment("MAQUINA_PEDIDO_ARN", maquina.state_machine_arn)
        container_api.add_environment("TABELA_FLUXO", tabela_fluxo.table_name)

        maquina.grant_task_response(webhook)
        tabela_fluxo.grant_read_write_data(webhook)
        webhook.add_environment("TABELA_FLUXO", tabela_fluxo.table_name)
```

Em `backend/app/main.py`, o `cache.xadd` sai do `criar_pedido`, e entra o início do fluxo:

```python
import logging

import boto3

sfn = boto3.client("stepfunctions", region_name=os.environ.get("AWS_REGION", "us-east-1"))
MAQUINA_PEDIDO = os.environ.get("MAQUINA_PEDIDO_ARN", "")
log = logging.getLogger(__name__)


def iniciar_fluxo(pedido_id: str) -> None:
    try:
        sfn.start_execution(
            stateMachineArn=MAQUINA_PEDIDO,
            name=pedido_id,
            input=json.dumps({"pedido_id": pedido_id}),
        )
    except Exception:
        log.exception("fluxo do pedido %s não iniciado; a varredura tenta de novo", pedido_id)

# dentro de criar_pedido, no lugar de cache.xadd(STREAM_PEDIDOS, ...),
# depois do bloco with pool.connection() que faz o INSERT:
    iniciar_fluxo(str(pedido["id"]))
```

O nome da execução é o ID do pedido. Numa máquina Standard, repetir o `StartExecution` com o mesmo nome e a mesma entrada, enquanto a execução roda, devolve a mesma execução; com entrada diferente ou execução encerrada, vem `ExecutionAlreadyExists`. Por isso a entrada é mínima e montada sempre igual.

O `except` só registra o erro porque `INSERT` e `StartExecution` são a escrita dupla do capítulo 5, prometida para cá desde o capítulo 12: se a task morrer entre as duas linhas, o pedido existe e o fluxo não. A resposta vem logo adiante.

Delete `backend/app/worker.py` e a constante `STREAM_PEDIDOS`. Copie o `fluxo.py` para `backend/app/fluxo.py` e, em `backend/app/entregas.py`, faça a rota `iniciar` exigir pedido confirmado e avisar o fluxo:

```python
from app.fluxo import avisar

# em iniciar(), a consulta passa a exigir o novo status
            "SELECT restaurante FROM pedidos WHERE id = %s AND status = 'confirmado'",

# e, antes do return:
    avisar(pedido_id, "entregador", {"entregador": inicio.entregador})
```

Na mesma lógica, o `UPDATE` da `entrega_concluida.py` passa de `AND status = 'pago'` para `AND status = 'confirmado'`. Os status do pedido agora são `recebido`, `pago`, `confirmado` e `entregue`, com as saídas `cancelado` e `estornado`.

No `webhook_pagamento.py` do capítulo 19, depois do `UPDATE` que encontrou o pedido:

```python
from fluxo import avisar

# depois do bloco with conexao().cursor(), antes do return 200:
    avisar(pedido_id, "pagamento", {"status": status})
```

### Agendas com fuso e a varredura

A cada cinco minutos, a varredura chama o `StartExecution` para os pedidos recentes sem desfecho. Para quem já tem fluxo, nada muda; para o órfão, o fluxo começa. Crie `backend/lambdas/rango_lambda/varredura.py`:

```python
import json
import os

import boto3

from banco import conexao

sfn = boto3.client("stepfunctions")
MAQUINA = os.environ["MAQUINA_PEDIDO_ARN"]


def handler(event, context):
    pendentes = conexao().execute(
        """
        SELECT id FROM pedidos
        WHERE status IN ('recebido', 'pago')
          AND criado_em BETWEEN now() - interval '1 hour' AND now() - interval '2 minutes'
        """
    ).fetchall()
    for linha in pendentes:
        pedido_id = str(linha["id"])
        try:
            sfn.start_execution(
                stateMachineArn=MAQUINA,
                name=pedido_id,
                input=json.dumps({"pedido_id": pedido_id}),
            )
        except sfn.exceptions.ExecutionAlreadyExists:
            pass  # execução já encerrada
    return {"verificados": len(pendentes)}
```

É o transactional outbox do capítulo 5 sem tabela extra: a própria linha do pedido, com status `recebido`, diz que existe trabalho a fazer. Na stack, a varredura e o resumo de vendas migrado para o Scheduler:

```python
        varredura = funcao(
            "Varredura", "varredura-pedidos", "varredura.handler",
            memory_size=256, timeout=Duration.seconds(60), retry_attempts=0,
            environment={"MAQUINA_PEDIDO_ARN": maquina.state_machine_arn},
        )
        maquina.grant_start_execution(varredura)
        scheduler.Schedule(
            self, "VarreduraPedidos",
            schedule=scheduler.ScheduleExpression.rate(Duration.minutes(5)),
            target=agendados.LambdaInvoke(varredura),
        )

        for hora, horas in ((11, 12), (15, 4), (23, 8)):
            scheduler.Schedule(
                self, f"Resumo{hora}h",
                schedule=scheduler.ScheduleExpression.cron(
                    minute="0", hour=str(hora), time_zone=TimeZone.AMERICA_SAO_PAULO
                ),
                target=agendados.LambdaInvoke(
                    resumo, input=scheduler.ScheduleTargetInput.from_object({"horas": horas})
                ),
            )
```

As horas agora são as do Bruno, e um eventual horário de verão não desalinha nada.

### Alerta quando um fluxo falha

O último pedaço usa o barramento `default` e os eventos que o próprio Step Functions publica:

```python
        topico_alertas = sns.Topic(self, "TopicoAlertas", topic_name=f"rango-{ambiente}-alertas")
        email_alertas = self.node.try_get_context("email_alertas")
        if email_alertas:
            topico_alertas.add_subscription(assinaturas.EmailSubscription(email_alertas))

        events.Rule(
            self,
            "FluxoFalhou",
            event_pattern=events.EventPattern(
                source=["aws.states"],
                detail_type=["Step Functions Execution Status Change"],
                detail={
                    "status": ["FAILED", "TIMED_OUT", "ABORTED"],
                    "stateMachineArn": [maquina.state_machine_arn],
                },
            ),
            targets=[alvos.SnsTopic(topico_alertas)],
        )
```

Estorno que falhou seis vezes, entregador que não saiu em duas horas: tudo vira e-mail. Cancelamentos terminam em `Succeed` e não disparam nada.

### Deploy e o primeiro pedido acompanhado

Reative os workflows, faça o commit de `backend/` e `rango-infra/` e envie para a `main`:

```bash
gh workflow enable ci.yaml
gh workflow enable renovar-tasks.yaml
```

Depois da sua aprovação no environment `producao`, o pipeline publica a imagem nova e o `cdk deploy` cria tudo. O `cdk diff` no log mostra os dois serviços de worker sendo removidos. Confirme a assinatura de e-mail do tópico de alertas, como no capítulo 7.

Para os testes, dois atalhos. Exporte `URL_WEBHOOKS` e `SEGREDO_WEBHOOK_ARN` com as saídas da stack, como no capítulo 19, e leia a chave do webhook para a variável `CHAVE_WEBHOOK`. Depois:

```bash
API=https://api.rango.com.br

criar() {  # $1 = restaurante; imprime "pedido chave"
  local chave; chave=$(uuidgen | tr 'A-Z' 'a-z')
  local id; id=$(curl -s -X POST "$API/pedidos" \
    -H "Content-Type: application/json" -H "Idempotency-Key: $chave" \
    -d "{\"usuario\": \"ana\", \"restaurante\": \"$1\", \"total\": 58.90}" | jq -r .id)
  echo "$id $chave"
}

pagar() {  # $1 = pedido, $2 = chave de idempotência da criação
  local corpo="{\"pedido_id\": \"$1\", \"cobranca\": \"cobranca-${2:0:8}\", \"status\": \"aprovada\"}"
  local assinatura="sha256=$(printf '%s' "$corpo" \
    | openssl dgst -sha256 -hmac "$CHAVE_WEBHOOK" | awk '{print $NF}')"
  curl -s -X POST "$URL_WEBHOOKS/webhooks/pagamento" -H "Content-Type: application/json" \
    -H "X-Assinatura: $assinatura" -d "$corpo"
}

MAQUINA=$(aws stepfunctions list-state-machines \
  --query "stateMachines[?name=='rango-producao-pedido'].stateMachineArn" --output text)

passo() {  # em que passo está o pedido $1
  local execucao="${MAQUINA/:stateMachine:/:execution:}:$1"
  aws stepfunctions describe-execution --execution-arn "$execucao" --query status --output text
  aws stepfunctions get-execution-history --execution-arn "$execucao" --reverse-order \
    --query "events[?ends_with(type, 'StateEntered')] | [0].stateEnteredEventDetails.name" \
    --output text
}
```

O ARN de uma execução é o da máquina com `execution` no lugar de `stateMachine` e o nome da execução no fim, que é o ID do pedido. Crie um pedido e veja onde ele está:

```bash
read PEDIDO CHAVE < <(criar cantina-da-nona)
passo "$PEDIDO"
```

```text
RUNNING
AguardarPagamento
```

O fluxo está parado, esperando o PIX. Pague e pergunte de novo:

```bash
pagar "$PEDIDO" "$CHAVE"
sleep 3
passo "$PEDIDO"
curl -s "$API/pedidos/$PEDIDO" | jq .status
```

```text
RUNNING
AguardarEntregador
"confirmado"
```

Em três segundos, o webhook avisou o fluxo, o restaurante confirmou e o evento `pedido.confirmado` passou pelo SNS até a fila de e-mail. Confira no log da Lambda:

```bash
GRUPO=$(aws lambda get-function-configuration --function-name rango-producao-avisos-email \
  --query LoggingConfig.LogGroup --output text)
aws logs tail "$GRUPO" --since 5m --format short | grep canal
```

```text
2026-10-20T23:41:07 {"canal": "email", "tipo": "pedido.confirmado", "pedido_id": "8c1f4e2a-..."}
```

Agora o entregador sai:

```bash
curl -s -X POST "$API/entregas/$PEDIDO/iniciar" \
  -H "Content-Type: application/json" -d '{"entregador": "joao-p"}'
sleep 3
passo "$PEDIDO"
```

```text
SUCCEEDED
PedidoEmRota
```

O log da `rango-producao-avisos-sms` mostra o `entrega.iniciada`: o SMS do Bruno é mais um assinante do tópico. No console do Step Functions, o diagrama da execução mostra cada passo em verde, com entrada, saída e o tempo de espera do pagamento.

### O restaurante recusa

Simule o botijão vazio do Sabor do Sertão. A variável `RECUSAR` entra direto na função, somada às que o CDK definiu, porque o `update-function-configuration` substitui o ambiente inteiro:

```bash
FN=rango-producao-confirmar-restaurante
VARS=$(aws lambda get-function-configuration --function-name $FN \
  --query Environment.Variables | jq -c '. + {"RECUSAR": "sabor-do-sertao"}')
aws lambda update-function-configuration --function-name $FN \
  --environment "{\"Variables\": $VARS}" > /dev/null

read PEDIDO CHAVE < <(criar sabor-do-sertao)
pagar "$PEDIDO" "$CHAVE"
sleep 5
passo "$PEDIDO"
curl -s "$API/pedidos/$PEDIDO" | jq .status
```

```text
SUCCEEDED
FimEstornar
"estornado"
```

O log da `cancelar-pedido` mostra o estorno com a chave `estorno-<pedido>`, e o da `avisos-email` mostra o `pedido.cancelado`. Ninguém abriu o painel do gateway. Isso é drift proposital, no sentido do capítulo 15; desfaça agora com `jq -c 'del(.RECUSAR)'` no mesmo comando, ou deixe o próximo deploy desfazer.

Com `FALHA_RESTAURANTE` em `0.5`, o histórico mostra o `Retry` com intervalos irregulares. E um pedido não pago termina, 15 minutos depois, em `FimCancelar`.

### Uma mensagem envenenada

Mande à fila de e-mail uma mensagem sem o atributo `tipo`, como faria um bug num publicador futuro:

```bash
FILA=$(aws sqs get-queue-url --queue-name rango-producao-email --query QueueUrl --output text)
DLQ=$(aws sqs get-queue-url --queue-name rango-producao-email-dlq --query QueueUrl --output text)
aws sqs send-message --queue-url "$FILA" --message-body '{"pedido_id": "teste"}'
```

O `avisos.py` lança `KeyError`, devolve a mensagem em `batchItemFailures`, e ela volta à fila a cada dois minutos. No log, cinco linhas `falha em ...: KeyError('tipo')`. Uns dez minutos depois:

```bash
aws sqs get-queue-attributes --queue-url "$DLQ" \
  --attribute-names ApproximateNumberOfMessages --query Attributes
```

```json
{
    "ApproximateNumberOfMessages": "1"
}
```

As mensagens boas continuaram passando. Inspecione com `aws sqs receive-message --queue-url "$DLQ" --message-attribute-names All` e apague com `aws sqs purge-queue --queue-url "$DLQ"`.

O caso oposto é o do provedor de e-mail fora do ar por uma hora: mensagens boas na DLQ. Depois que o provedor voltar, devolva todas à fila de origem:

```bash
DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$DLQ" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)
aws sqs start-message-move-task --source-arn "$DLQ_ARN"
```

Sem `--destination-arn`, o SQS devolve cada mensagem à fila de onde ela veio. A idempotência do `avisos.py` garante que quem já recebeu o e-mail não recebe outro.

### Quanto isso custa

Com os preços de referência de outubro de 2026 em us-east-1 (aproximados; confira as páginas oficiais), e assumindo mil pedidos por dia:

| Item | Conta | Por mês |
|------|-------|---------|
| Step Functions Standard | ~9 transições × 30 mil pedidos = 270 mil, menos 4 mil gratuitas, × US$ 0,000025 | ~US$ 7 |
| Endpoint do Step Functions | 2 AZs × 730 h × US$ 0,01 | ~US$ 15 |
| SNS, SQS, Lambdas, DynamoDB do fluxo | algumas centenas de milhares de requisições | centavos |
| EventBridge Scheduler | ~8.700 invocações, dentro das 14 milhões gratuitas | US$ 0 |
| Workers do ECS removidos | estimativa do capítulo 17 | −US$ 14 |

Uns US$ 8 a mais por mês. O endpoint é o preço de manter as subnets sem internet; a máquina cresce linearmente, uns US$ 7 a cada mil pedidos diários.

### Desmontando

Execuções em andamento seguram a máquina. Pare as que estiverem esperando e destrua a stack:

```bash
for e in $(aws stepfunctions list-executions --state-machine-arn "$MAQUINA" \
    --status-filter RUNNING --query "executions[].executionArn" --output text); do
  aws stepfunctions stop-execution --execution-arn "$e" > /dev/null
done

cd rango-infra
cdk destroy RangoProducao
gh workflow disable ci.yaml
gh workflow disable renovar-tasks.yaml
unset CHAVE_WEBHOOK
```

Cada execução parada vira `ABORTED` e gera um e-mail de alerta, o teste da regra. Filas, tópicos, máquina, agendas e tabela vão embora com a stack. O banco deixa um snapshot novo, como sempre.

## Idempotência, peça por peça

O capítulo 5 disse que, num sistema com entrega pelo menos uma vez, a idempotência precisa estar perto do efeito. Agora você pode ver onde ela ficou em cada ponto do Rangô:

| Onde pode repetir | Quem protege |
|-------------------|--------------|
| Cliente clica duas vezes em "confirmar" | `Idempotency-Key` + `SET NX` no Valkey (capítulo 5) |
| API e varredura iniciam o mesmo fluxo | nome da execução = ID do pedido |
| Webhook reenviado pelo gateway | `UPDATE ... WHERE` + `SendTaskSuccess` repetido ignorado |
| `Retry` chama o restaurante de novo | checagem de `status = 'confirmado'` |
| Estorno executado duas vezes | chave `estorno-{pedido_id}` no gateway |
| SNS ou SQS entregam a mesma mensagem | `put_item` condicional no DynamoDB |
| Stream reentrega a conclusão da entrega | `UPDATE ... AND status = 'confirmado'` (capítulo 20) |

Os serviços tornam a repetição rara e visível; quem garante que ela não causa estrago é o seu código.

## Armadilhas e casos reais

> **Armadilha:** Visibility timeout menor que o processamento. Um consumidor leva 45 segundos numa fila com o padrão de 30, a mensagem reaparece no meio do trabalho, e outro consumidor faz a mesma coisa em paralelo. O sintoma é duplicata sem erro nenhum no log. Com Lambda, a própria AWS barra o caso extremo: um timeout de função maior que o visibility timeout da fila faz a criação do event source mapping falhar.

> **Armadilha:** DLQ sem alarme. A fila de mensagens mortas do Rangô pode encher em silêncio por 14 dias e então começar a descartar. O alarme sobre `ApproximateNumberOfMessagesVisible` da DLQ chega no capítulo 22; até lá, olhe a fila depois de cada deploy.

> **Armadilha:** Entrada diferente no `StartExecution`. Se a varredura passar a mandar `{"pedido_id": "...", "origem": "varredura"}`, recebe `ExecutionAlreadyExists` em todo pedido em andamento, e um retry nesse `except` nunca termina. Monte a entrada numa função só.

> **Armadilha:** Laços de espera no Step Functions Standard. Um `Wait` de 10 segundos seguido de um `Choice` que volta para o `Wait`, para "conferir se o pagamento chegou", custa duas transições a cada 10 segundos por pedido. Em 15 minutos, 180 transições, vinte vezes o fluxo inteiro. O callback com token espera de graça.

> **Armadilha:** Mensagens grandes pelo fluxo. A entrada de uma execução do Step Functions aceita até 256 KiB, e o estado acumula o resultado de cada passo. Passe IDs e busque os dados no passo que precisa deles, como o Rangô faz.

> **Na vida real:** Em 25 de novembro de 2020, o Amazon Kinesis Data Streams de us-east-1 passou boa parte do dia com falhas, depois que um aumento de capacidade da frota de front-end fez os servidores passarem do limite de threads do sistema operacional. Serviços da AWS que usam o Kinesis por dentro sofreram junto, entre eles o Cognito, o CloudWatch e o EventBridge, que entregou eventos com atraso. O barramento também é uma dependência: um fluxo que tolera atraso sobrevive a um dia assim.

## Resumo

- O SQS guarda mensagens até alguém processar. Receber não remove: a mensagem fica invisível pelo visibility timeout e volta se o consumidor não a apagar. A redrive policy manda para a DLQ depois de N recebimentos.
- Fila standard tem vazão quase ilimitada e entrega pelo menos uma vez, sem ordem; FIFO ordena por `MessageGroupId`, com vazão limitada.
- Com Lambda, o event source mapping consulta a fila; `ReportBatchItemFailures` devolve só as mensagens que falharam, e o visibility timeout deve ser seis vezes o timeout da função.
- O SNS copia cada publicação para todas as assinaturas, com filter policy por atributo. SNS na frente e uma fila SQS atrás de cada consumidor é o padrão de fan-out.
- O EventBridge roteia eventos pelo conteúdo, recebe de graça os eventos dos serviços da AWS no barramento `default` e agenda tarefas com fuso horário pelo Scheduler.
- O Step Functions conduz processos de vários passos com `Retry`, `Catch`, `Choice` e callback por token. Standard para processos longos e auditáveis; Express para fluxos curtos e de volume alto.
- Compensação desfaz um passo já feito quando outro adiante falha; o estorno compensa o pagamento.
- O Rangô trocou o stream do Valkey e os workers por uma máquina de estados por pedido, um tópico com filas de e-mail e SMS, uma varredura que fecha a escrita dupla e um alerta para fluxos que falham.
- Idempotência continua sendo trabalho seu, em cada ponto onde algo pode repetir.

## Dez lugares para procurar

Um cliente escreve às 21h10: o pedido levou 40 minutos para ser confirmado. Onde ficou parado? A execução do Step Functions mostra que o `ConfirmarRestaurante` demorou, mas não por quê. O log da Lambda está num grupo, o da API em outro, o do webhook num terceiro, e o Rangô já tem dez deles. A DLQ de e-mail tem sete mensagens, e você descobriu por acaso. O resumo de vendas das 11h falhou na quinta, e o Bruno avisou na sexta.

No próximo capítulo, o Rangô ganha olhos: Amazon CloudWatch Logs e Logs Insights para consultar todos os logs de uma vez, métricas e alarmes (a DLQ, finalmente), dashboards, logs estruturados no FastAPI, tracing distribuído com AWS X-Ray e OpenTelemetry seguindo um pedido da API até o SMS, e SLOs para responder com números à pergunta que todo mundo faz primeiro: está lento para quem?

## Referências

- Amazon SQS, Developer Guide: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html
- Cotas de mensagens do SQS (tamanho, retenção, visibility timeout, FIFO): https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/quotas-messages.html
- Visibility timeout: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html
- Dead letter queues no SQS: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html
- Preços do SQS: https://aws.amazon.com/sqs/pricing/
- Lambda com SQS (visibility timeout, ReportBatchItemFailures, maxReceiveCount): https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html
- Amazon SNS, Developer Guide: https://docs.aws.amazon.com/sns/latest/dg/welcome.html
- Filtro de mensagens no SNS: https://docs.aws.amazon.com/sns/latest/dg/sns-message-filtering.html
- Preços do SNS: https://aws.amazon.com/sns/pricing/
- Amazon EventBridge, User Guide: https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-what-is.html
- EventBridge Scheduler, User Guide: https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html
- Preços do EventBridge (barramentos, Pipes, Scheduler, archive): https://aws.amazon.com/eventbridge/pricing/
- CDK, módulo `aws_scheduler`: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_scheduler/README.html
- AWS Step Functions, Developer Guide: https://docs.aws.amazon.com/step-functions/latest/dg/welcome.html
- Tratamento de erros no Step Functions (Retry, Catch, jitter): https://docs.aws.amazon.com/step-functions/latest/dg/concepts-error-handling.html
- API `StartExecution` (idempotência em Standard): https://docs.aws.amazon.com/step-functions/latest/apireference/API_StartExecution.html
- Preços do Step Functions: https://aws.amazon.com/step-functions/pricing/
- Powertools for AWS Lambda (Python), idempotência: https://docs.powertools.aws.dev/lambda/python/latest/utilities/idempotency/
- Resumo do incidente do Kinesis em us-east-1 (25/nov/2020): https://aws.amazon.com/message/11201/
