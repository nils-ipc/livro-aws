# Serverless com Lambda e API Gateway

No capítulo anterior, o deploy do Rangô saiu das suas mãos. Um push na `main` dispara o GitHub Actions, que se autentica na AWS por OIDC, constrói a imagem num runner ARM, envia ao ECR e roda o `cdk deploy`, com blue/green no ECS e rollback automático quando o alarme de erros 5xx dispara. No fim, a stack `RangoProducao` foi destruída, com snapshot do banco, e os workflows ficaram desabilitados. E o Bruno, animado com a facilidade, já tinha um pedido novo.

## Seis minutos de trabalho, 24 horas de conta

O pedido é simples: um resumo de vendas para cada restaurante às 11h, às 15h e às 23h. Quantos pedidos entraram no período, quanto faturaram e qual foi o ticket médio. Os pratos mais pedidos ficam para depois, porque os itens ainda não estão numa tabela. Quarenta linhas de Python, uma consulta ao Postgres e um e-mail.

Com o que você tem, o caminho óbvio é um terceiro worker no ECS. Um laço que calcula quanto falta até a próxima hora cheia, dorme, acorda, gera o resumo e volta a dormir. Funciona. Agora faça a conta. A consulta e o envio levam uns dois segundos por execução. Três execuções por dia dão seis segundos de trabalho. A task de 0,25 vCPU e 512 MB fica ligada 86.400 segundos por dia. Você estaria pagando por 99,99% de sono.

O valor é pequeno: o capítulo 17 estimou uns US$ 14 por mês para os dois workers, então uma task dessas fica perto de US$ 7. O problema aparece quando o padrão se repete. O Bruno já quer um relatório semanal, uma limpeza dos carrinhos abandonados e, o mais urgente, um endereço para receber os avisos do gateway de pagamento.

O gateway acaba de liberar o PIX, que funciona diferente do cartão. O Rangô gera o código, o cliente paga no aplicativo do banco quando quiser, e minutos depois o gateway faz um POST num endereço do Rangô dizendo "a cobrança tal foi aprovada". Esse POST chama-se *webhook*. Ele chega em rajadas no almoço e no jantar, e quase nunca de madrugada.

O webhook poderia ser mais uma rota do FastAPI, e seria uma escolha razoável. Mas repare no padrão dos pedidos do Bruno: código pequeno, que roda de vez em quando, disparado por um evento. Manter algo ligado o tempo todo para isso é alugar um salão de festas para um jantar de três pessoas.

## Código que só existe quando é chamado

O capítulo 4 apresentou *serverless* como conceito: você entrega o código, o provedor executa quando algo acontece e cobra pelo tempo de execução. O AWS Lambda é a implementação da AWS. Existe servidor, claro; você só deixa de escolhê-lo e de pagar por ele quando nada está rodando.

O que você entrega é uma função Python com uma assinatura fixa:

```python
def handler(event, context):
    return {"ok": True}
```

O `event` é um dicionário com os dados de quem chamou. Se foi uma regra de agendamento, vem o que você configurou nela. Se foi uma requisição HTTP, vêm o método, o caminho, os cabeçalhos e o corpo. O `context` traz metadados da execução, como o ID da requisição e quanto tempo resta antes do limite. Pense numa view do Django em que o `request` virou um dicionário e o framework foi substituído pela AWS.

### O ambiente de execução por dentro

Quando a primeira chamada chega, a Lambda cria um **ambiente de execução**: uma micro máquina virtual (Firecracker, a mesma tecnologia por trás do Fargate) com o runtime Python, o seu código e a memória que você configurou. A fase **INIT** acontece uma vez: a Lambda inicia o interpretador e importa o seu módulo, e tudo o que está fora do `handler` roda aqui (imports, clientes do boto3, leitura de segredos). A fase **INVOKE** acontece a cada chamada. A fase **SHUTDOWN** vem quando a Lambda decide descartar o ambiente ocioso, num momento que você não controla.

Entre uma chamada e outra, o ambiente fica congelado. Se outra chamada chega, a Lambda descongela e chama o `handler` de novo, sem repetir o INIT. As variáveis globais, a conexão aberta com o banco e os arquivos em `/tmp` continuam lá. A chamada que precisa de um ambiente novo é o *cold start*, que o capítulo 4 prometeu explicar por dentro: o INIT somado à primeira chamada. A que encontra um ambiente pronto é o *warm start*.

Um detalhe muda o modelo mental: **cada ambiente atende uma chamada por vez**. Se dez requisições chegam juntas, a Lambda precisa de dez ambientes. O número de ambientes ocupados ao mesmo tempo é a **concorrência** da função. Um processo Uvicorn atende dezenas de requisições ao mesmo tempo com `async`; na Lambda, a concorrência vem de multiplicar processos Python inteiros.

### O que pesa no cold start

O tempo do INIT depende do tamanho do pacote, dos imports (`import pandas` sozinho custa centenas de milissegundos), do código de inicialização e da memória. Na Lambda, você escolhe a memória, entre 128 MB e 10.240 MB, e a CPU vem junto, em proporção: com 1.769 MB, a função recebe o equivalente a uma vCPU. Uma função com imports pesados pode ficar mais rápida e até mais barata com mais memória, porque o tempo cai mais do que o preço por milissegundo sobe.

Muito texto antigo recomenda evitar VPC por causa de cold starts de vários segundos. A AWS mudou esse mecanismo em 2019, e hoje as interfaces de rede são criadas quando a função é configurada, não a cada cold start.

Até julho de 2025, o INIT de funções em zip com runtime gerenciado não era cobrado. Desde 1º de agosto de 2025, ele é cobrado em todas as configurações, pelo preço normal de duração, e aparece somado no `Billed Duration` dos logs. Para quem inicializava coisas pesadas fora do handler contando com o INIT grátis, a conta mudou.

Quando o cold start incomoda, existem duas saídas pagas. A *provisioned concurrency* mantém um número fixo de ambientes já inicializados, prontos para atender, e você paga por eles mesmo parados; é a recomendação da documentação quando a latência precisa ser previsível. O *SnapStart*, disponível para Python 3.12 em diante desde novembro de 2024, tira uma fotografia da memória do ambiente depois do INIT e restaura a partir dela nos cold starts seguintes. Ele não funciona com imagens de container, e o código precisa tomar cuidado com o que fica na fotografia: uma conexão aberta com o banco, por exemplo, não sobrevive à restauração.

### Os limites que você precisa conhecer

A Lambda tem limites fixos que moldam o que cabe nela. Os valores abaixo são da documentação de cotas, consultada em outubro de 2026; confira a página oficial antes de projetar algo perto deles.

| Limite | Valor |
|--------|-------|
| Tempo máximo de execução | 900 segundos (15 minutos) |
| Memória | 128 MB a 10.240 MB |
| Payload de chamada síncrona | 6 MB na requisição e 6 MB na resposta |
| Payload de chamada assíncrona | 1 MB |
| Pacote zip | 50 MB compactado; 250 MB descompactado, somando as layers |
| Imagem de container | 10 GB |
| Layers por função | 5 |
| Espaço em `/tmp` | 512 MB a 10.240 MB |
| Variáveis de ambiente | 4 KB no total |
| Concorrência por região | 1.000 por padrão (contas novas começam com menos) |

Os 15 minutos deixam de fora processamentos longos, que ficam melhor numa task do ECS. Os 4 KB de variáveis de ambiente reforçam o caminho do capítulo 16: o Parameter Store e o Secrets Manager guardam os valores, e a função recebe só os nomes.

O limite de 1.000 de concorrência vale para a região inteira, somando todas as funções, e cada função ganha no máximo 1.000 ambientes novos a cada 10 segundos. A documentação aponta um descompasso: o API Gateway aceita por padrão 10.000 requisições por segundo, a Lambda roda 1.000 ambientes. Se cada requisição leva um segundo, o excesso volta como erro de *throttling*. A solução é pedir aumento da cota antes de precisar, como o capítulo 4 recomendou pré-escalar antes do programa de TV.

### Runtimes e layers

Em outubro de 2026, os runtimes Python de uso geral são `python3.14`, `python3.13` e `python3.12`, todos sobre Amazon Linux 2023 e disponíveis em x86_64 e arm64 (Graviton, cerca de 20% mais barato por GB-segundo). O `python3.12` tem descontinuação marcada para 31 de outubro de 2028. O Rangô usa essa versão, a mesma da imagem do container desde o capítulo 3.

Uma *layer* é um zip extra que a Lambda descompacta em `/opt`. Se ele tiver uma pasta `python/`, ela entra no `sys.path`. O uso clássico é separar dependências do código: a layer leva o `psycopg` e o `boto3`, o pacote da função leva só os seus `.py`, e duas funções podem compartilhar a mesma layer. São no máximo cinco por função, dentro dos 250 MB descompactados. Cada publicação gera uma versão imutável, e layers não resolvem conflito de dependências: se duas trazem a mesma biblioteca, vence a primeira na ordem, sem aviso.

O runtime já vem com um `boto3`, mas a versão muda quando a AWS atualiza o runtime. A documentação recomenda empacotar o seu, com versão conhecida.

### As formas de chamar uma função

Uma função Lambda não escuta nenhuma porta. Na **chamada síncrona**, quem chama espera a resposta; é o que o API Gateway faz. Na **chamada assíncrona**, quem chama entrega o evento e vai embora, a Lambda executa quando puder e, se a função falhar, tenta de novo duas vezes por padrão; é o que acontece quando o Amazon EventBridge dispara uma função num horário. No **mapeamento de origem de eventos**, a própria Lambda lê uma fila do SQS e chama a função com lotes de mensagens, modelo que o capítulo 21 usa.

A AWS lançou variações recentes, como as Lambda Managed Instances e as durable functions, e passou a chamar as funções clássicas de *Event Functions*. Este capítulo fica com elas.

## A porta HTTP da função

Para o webhook do PIX, o gateway de pagamento precisa de uma URL HTTPS. A Lambda não tem porta, então alguma coisa precisa receber a requisição HTTP, terminar o TLS, transformar tudo num `event` e chamar a função. Esse é o papel do Amazon API Gateway.

O API Gateway faz para a Lambda o que o ALB faz para as tasks do ECS, com autenticação, limite de requisições e rotas declaradas. Ele cobra por requisição, sem custo fixo por hora, enquanto o ALB do capítulo 13 custa uns US$ 23 por mês parado. As *function URLs*, que dão à função um endereço HTTPS sem API Gateway, servem para protótipos, mas não oferecem rotas nem limite de requisições.

### HTTP API ou REST API

O API Gateway tem dois produtos para APIs HTTP comuns, com nomes que confundem: a REST API e a HTTP API. As duas recebem requisições REST. A diferença está nos recursos e no preço.

| | HTTP API | REST API |
|---|---|---|
| Preço (primeira faixa, us-east-1, out/2026) | US$ 1,00 por milhão de chamadas | US$ 3,50 por milhão de chamadas |
| Autorizadores | JWT, Lambda, IAM | Lambda, IAM, Cognito |
| Chaves de API e limite por cliente | Não | Sim |
| Validação da requisição | Não | Sim |
| Integração com AWS WAF | Não | Sim |
| Endpoint privado (só dentro da VPC) | Não | Sim |
| Cache de respostas | Não | Sim, cobrado por hora |

A REST API compensa quando você vende acesso à API para terceiros, com chave e cota por cliente, ou precisa do WAF na frente (capítulo 23). Para o webhook, que tem um único cliente e valida a assinatura no código, a HTTP API basta e custa menos de um terço. Os preços são aproximados, de referência, da página oficial; contas criadas desde 15 de julho de 2025 usam os créditos do plano gratuito do capítulo 7.

A HTTP API tem dois limites fixos. A integração tem no máximo 30 segundos: se a função demorar mais, o cliente recebe erro, mesmo que a Lambda continue rodando. E o payload vai até 10 MB. Um relatório pesado sob demanda precisa responder logo com um "estou processando" e entregar depois, no modelo assíncrono do capítulo 5.

### O evento que chega na função

Quando a HTTP API chama a Lambda, ela usa o formato de payload 2.0. O `event` fica mais ou menos assim, resumido:

```json
{
  "version": "2.0",
  "routeKey": "POST /webhooks/pagamento",
  "rawPath": "/webhooks/pagamento",
  "headers": {
    "content-type": "application/json",
    "x-assinatura": "sha256=4f1c..."
  },
  "requestContext": {
    "http": {"method": "POST", "sourceIp": "203.0.113.77"}
  },
  "body": "{\"pedido_id\": \"...\", \"status\": \"aprovada\"}",
  "isBase64Encoded": false
}
```

O corpo chega como texto cru, ou em base64 quando o `isBase64Encoded` vem `true`. A resposta da função é outro dicionário, com `statusCode`, `headers` e `body`.

## Mão na massa

O plano é colocar duas funções no Rangô. A `resumo-vendas` roda três vezes por dia, disparada por regras do EventBridge. A `webhook-pagamento` atende o POST do gateway, atrás de uma HTTP API. As duas leem o Postgres, então ficam dentro da VPC, nas subnets privadas, e compartilham uma layer com as dependências.

```text
EventBridge (cron UTC) ──► Lambda resumo-vendas ──┐
                                                  ├──► RDS rango-db
Gateway de pagamento ──► HTTP API ──► Lambda      │    (subnets privadas)
                         webhook-pagamento ───────┘
                              │
                              └──► Secrets Manager (endpoint na VPC)
```

Pré-requisitos: o repositório do capítulo 18, a AWS CLI v2 com o profile `rango-dev`, o Node e o CDK, o Docker rodando (o CDK usa um container para montar a layer) e o `jq`.

### O ponto de partida

A stack `RangoProducao` foi destruída no fim do capítulo 18. Ficaram a `RangoRegistro`, com as imagens no ECR, a `RangoPipeline`, com as roles do GitHub, a zona, o certificado, o bucket de fotos e o snapshot final do banco. Encontre o nome dele:

```bash
aws rds describe-db-snapshots --snapshot-type manual \
  --query "reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[0].DBSnapshotIdentifier" \
  --output text
```

Coloque esse nome no `snapshot_db` do `rango-infra/app.py`, como nos capítulos anteriores. O deploy vai acontecer pelo pipeline, no fim das mudanças.

### O código das funções

As funções ficam numa pasta própria no backend:

```text
backend/lambdas/
├── camada/
│   └── requirements.txt
└── rango_lambda/
    ├── banco.py
    ├── rds-ca.pem
    ├── resumo_vendas.py
    └── webhook_pagamento.py
```

Copie o certificado da CA do RDS que o capítulo 17 baixou:

```bash
mkdir -p backend/lambdas/camada backend/lambdas/rango_lambda
cp backend/rds-ca.pem backend/lambdas/rango_lambda/
```

O `backend/lambdas/camada/requirements.txt` tem as dependências da layer. Fixe as versões exatas com um `pip freeze`, como no capítulo 3; os intervalos abaixo são o ponto de partida:

```text
psycopg[binary]~=3.2
boto3~=1.40
```

O `banco.py` concentra a conexão. Repare que quase tudo acontece no nível do módulo, ou seja, na fase INIT:

```python
import json
import os

import boto3
import psycopg
from psycopg.rows import dict_row

_segredo = json.loads(
    boto3.client("secretsmanager").get_secret_value(
        SecretId=os.environ["SEGREDO_DB_ARN"]
    )["SecretString"]
)
_conexao = None


def conexao() -> psycopg.Connection:
    global _conexao
    if _conexao is None or _conexao.closed or _conexao.broken:
        _conexao = psycopg.connect(
            host=os.environ["DB_HOST"],
            dbname="rango",
            user=_segredo["username"],
            password=_segredo["password"],
            sslmode="verify-full",
            sslrootcert=os.path.join(os.environ["LAMBDA_TASK_ROOT"], "rds-ca.pem"),
            connect_timeout=5,
            autocommit=True,
            row_factory=dict_row,
        )
    return _conexao
```

O segredo é lido uma vez por ambiente, e a conexão aberta na primeira chamada é reaproveitada nas seguintes. Uma conexão por ambiente, sem pool, porque cada ambiente atende uma chamada por vez. Se o Postgres derrubou a conexão durante o congelamento, o `broken` acusa e a próxima chamada reconecta. E a rotação do capítulo 16 não atrapalha: na estratégia multi-user, a senha anterior vale até a rotação seguinte, e nenhum ambiente vive 30 dias. O `LAMBDA_TASK_ROOT` é a pasta do código, `/var/task`.

Agora o `resumo_vendas.py`:

```python
import json

from banco import conexao

CONSULTA = """
    SELECT restaurante,
           count(*) AS pedidos,
           sum(total) AS faturamento,
           round(avg(total), 2) AS ticket_medio
    FROM pedidos
    WHERE criado_em >= now() - %s * interval '1 hour'
      AND status <> 'recusado'
    GROUP BY restaurante
    ORDER BY restaurante
"""


def enviar_resumo(linha: dict, horas: int) -> None:
    # O envio de e-mail segue simulado, como no externos.py do capítulo 5.
    print(json.dumps({"evento": "resumo.enviado", "horas": horas, **linha}, default=str))


def handler(event, context):
    horas = int(event.get("horas", 8))
    linhas = conexao().execute(CONSULTA, (horas,)).fetchall()
    for linha in linhas:
        enviar_resumo(linha, horas)
    return {"restaurantes": len(linhas), "horas": horas}
```

O período chega no evento: às 11h, 12 horas desde as 23h da véspera; às 15h, 4 horas; às 23h, 8 horas. O `print` vai para o CloudWatch Logs, que captura a saída padrão.

E o `webhook_pagamento.py`. Gateways assinam o corpo do webhook com uma chave compartilhada, para que ninguém marque um pedido como pago com um POST qualquer. O formato varia de gateway para gateway; aqui, o gateway hipotético manda um HMAC-SHA256 do corpo no cabeçalho `X-Assinatura`:

```python
import base64
import hashlib
import hmac
import json
import os
import uuid

import boto3

from banco import conexao

_chave = boto3.client("secretsmanager").get_secret_value(
    SecretId=os.environ["SEGREDO_WEBHOOK_ARN"]
)["SecretString"].encode()

STATUS = {"aprovada": "pago", "recusada": "recusado"}


def resposta(codigo: int, corpo: dict) -> dict:
    return {
        "statusCode": codigo,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(corpo),
    }


def handler(event, context):
    corpo = event.get("body") or ""
    bruto = base64.b64decode(corpo) if event.get("isBase64Encoded") else corpo.encode()

    cabecalhos = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    recebida = cabecalhos.get("x-assinatura", "").encode()
    esperada = ("sha256=" + hmac.new(_chave, bruto, hashlib.sha256).hexdigest()).encode()
    if not hmac.compare_digest(esperada, recebida):
        return resposta(401, {"erro": "assinatura inválida"})

    aviso = json.loads(bruto)
    status = STATUS.get(aviso.get("status"))
    try:
        pedido_id = uuid.UUID(str(aviso.get("pedido_id")))
    except ValueError:
        return resposta(422, {"erro": "pedido_id inválido"})
    if status is None:
        return resposta(422, {"erro": "status desconhecido"})

    with conexao().cursor() as cur:
        cur.execute(
            "UPDATE pedidos SET status = %s WHERE id = %s AND cobranca = %s",
            (status, pedido_id, aviso.get("cobranca")),
        )
        if cur.rowcount == 0:
            return resposta(404, {"erro": "pedido não encontrado"})

    return resposta(200, {"pedido_id": str(pedido_id), "status": status})
```

A assinatura é conferida sobre os bytes crus, antes de interpretar o JSON, porque reformatar o JSON muda o HMAC. O `compare_digest` compara em tempo constante, para a demora não revelar quantos caracteres batem. E o `UPDATE` com `status = 'pago'` é idempotente, como no capítulo 5: gateways reenviam webhooks quando não recebem 200, e o aviso repetido deixa o pedido no mesmo estado.

> **Armadilha:** Código de autenticação, verificação de assinatura e criptografia é o lugar onde um detalhe errado vira brecha. Use o esquema exato que o seu gateway documenta (muitos incluem um timestamp no cálculo, para impedir que alguém reenvie um aviso antigo), prefira a biblioteca oficial dele quando existir e peça a revisão de alguém de segurança antes de ligar o webhook em produção.

### A stack

No `rango-infra/rango_infra/rango_infra_stack.py`, acrescente os imports:

```python
from aws_cdk import (
    # ... os imports do capítulo 18 ...
    BundlingOptions,
    DockerImage,
    aws_apigatewayv2 as apigwv2,
    aws_apigatewayv2_integrations as integracoes,
    aws_events as events,
    aws_events_targets as alvos,
    aws_lambda as lambda_,
    aws_secretsmanager as secretsmanager,
)
```

Primeiro a layer. O CDK monta o zip dentro de um container:

```python
        camada_banco = lambda_.LayerVersion(
            self,
            "CamadaBanco",
            code=lambda_.Code.from_asset(
                "../backend/lambdas/camada",
                bundling=BundlingOptions(
                    image=DockerImage.from_registry("python:3.12-slim"),
                    command=[
                        "pip", "install", "--no-cache-dir",
                        "-r", "requirements.txt",
                        "-t", "/asset-output/python",
                        "--platform", "manylinux2014_aarch64",
                        "--platform", "manylinux_2_28_aarch64",
                        "--implementation", "cp",
                        "--python-version", "3.12",
                        "--only-binary=:all:",
                    ],
                ),
            ),
            compatible_runtimes=[lambda_.Runtime.PYTHON_3_12],
            compatible_architectures=[lambda_.Architecture.ARM_64],
            removal_policy=RemovalPolicy.DESTROY,
        )
```

Os parâmetros `--platform`, `--implementation`, `--python-version` e `--only-binary` pedem ao pip as *wheels* para Linux arm64 com CPython 3.12, qualquer que seja a máquina do deploy. É o primo do `exec format error` do capítulo 3, e a mensagem de erro está nas armadilhas.

Depois, o Security Group das funções e a liberação no banco:

```python
        sg_lambdas = ec2.SecurityGroup(
            self, "SgLambdas", vpc=vpc, description="Funcoes Lambda do Rango"
        )
        db.connections.allow_default_port_from(sg_lambdas, "Lambdas no Postgres")
```

A descrição vai sem acento pelo motivo do capítulo 9. As funções alcançam o Secrets Manager pelo endpoint do capítulo 16, mas não a internet: as subnets são `PRIVATE_ISOLATED`, sem NAT. Uma função que precisasse chamar a API do gateway traria de volta a conta do NAT Gateway do capítulo 10.

Uma função auxiliar evita repetir a configuração comum:

```python
        codigo_lambdas = lambda_.Code.from_asset("../backend/lambdas/rango_lambda")

        def funcao(id_: str, nome: str, handler: str, **extras) -> lambda_.Function:
            variaveis = {
                "DB_HOST": db.instance_endpoint.hostname,
                "SEGREDO_DB_ARN": segredo_app.secret_arn,
                **extras.pop("environment", {}),
            }
            fn = lambda_.Function(
                self,
                id_,
                function_name=f"rango-{ambiente}-{nome}",
                runtime=lambda_.Runtime.PYTHON_3_12,
                architecture=lambda_.Architecture.ARM_64,
                handler=handler,
                code=codigo_lambdas,
                layers=[camada_banco],
                vpc=vpc,
                vpc_subnets=privadas,
                security_groups=[sg_lambdas],
                environment=variaveis,
                log_group=logs.LogGroup(
                    self,
                    f"Logs{id_}",
                    retention=logs.RetentionDays.ONE_MONTH,
                    removal_policy=RemovalPolicy.DESTROY,
                ),
                **extras,
            )
            segredo_app.grant_read(fn)
            return fn
```

Cada função ganha uma role própria, com a policy gerenciada de logs e de interfaces de rede na VPC. O `grant_read` soma a leitura do segredo e o `kms:Decrypt` na chave do capítulo 16. O grupo de logs explícito evita uma armadilha que aparece mais adiante.

A função de resumo e os três horários:

```python
        resumo = funcao(
            "ResumoVendas",
            "resumo-vendas",
            "resumo_vendas.handler",
            memory_size=512,
            timeout=Duration.seconds(60),
            retry_attempts=0,
        )
        for hora_utc, horas in ((14, 12), (18, 4), (2, 8)):
            events.Rule(
                self,
                f"Resumo{hora_utc:02d}hUtc",
                schedule=events.Schedule.cron(minute="0", hour=str(hora_utc)),
                targets=[
                    alvos.LambdaFunction(
                        resumo, event=events.RuleTargetInput.from_object({"horas": horas})
                    )
                ],
            )
```

As regras do EventBridge entendem cron apenas em UTC. Brasília está em UTC−3 o ano todo desde o fim do horário de verão, em 2019: 11h vira 14h, 15h vira 18h e 23h vira 2h. O EventBridge Scheduler, do capítulo 21, aceita fuso horário e evita essa conta.

O `retry_attempts=0` é deliberado. Com as duas novas tentativas padrão, uma falha depois de alguns e-mails enviados mandaria tudo de novo, e o dono da Cantina da Nona receberia dois resumos iguais. O Bruno prefere um a menos a um duplicado; a falha vai precisar de alarme, assunto do capítulo 22. O `timeout` de 60 segundos também: o padrão de 3 segundos é curto para um cold start que busca segredo e abre conexão TLS.

Agora o webhook, o segredo dele e a HTTP API:

```python
        segredo_webhook = secretsmanager.Secret(
            self,
            "SegredoWebhook",
            encryption_key=chave,
            generate_secret_string=secretsmanager.SecretStringGenerator(
                password_length=48, exclude_punctuation=True
            ),
            removal_policy=RemovalPolicy.DESTROY,
        )

        webhook = funcao(
            "WebhookPagamento",
            "webhook-pagamento",
            "webhook_pagamento.handler",
            memory_size=256,
            timeout=Duration.seconds(10),
            reserved_concurrent_executions=10,
            environment={"SEGREDO_WEBHOOK_ARN": segredo_webhook.secret_arn},
        )
        segredo_webhook.grant_read(webhook)

        api_webhooks = apigwv2.HttpApi(
            self, "ApiWebhooks", api_name=f"rango-{ambiente}-webhooks"
        )
        api_webhooks.add_routes(
            path="/webhooks/pagamento",
            methods=[apigwv2.HttpMethod.POST],
            integration=integracoes.HttpLambdaIntegration("IntegracaoWebhook", webhook),
        )

        CfnOutput(self, "UrlWebhooks", value=api_webhooks.api_endpoint)
        CfnOutput(self, "SegredoWebhookArn", value=segredo_webhook.secret_arn)
```

O segredo nasce com valor aleatório, útil nos testes. Em produção, o gateway gera a chave e você grava com `aws secretsmanager put-secret-value`, fora do código e do template. O nome fica a cargo do CDK porque um segredo apagado passa dias em exclusão agendada, e um nome fixo impediria recriar a stack nesse intervalo.

O `reserved_concurrent_executions=10` reserva dez ambientes só para o webhook e, ao mesmo tempo, limita o webhook a dez, protegendo o banco. Um `db.t4g.micro` aceita pouco mais de cem conexões, teto que o capítulo 13 já encontrou. Com o limite, o excesso de uma rajada recebe erro 429, e o gateway tenta de novo depois. A permissão para o API Gateway chamar a função, o CDK cria na resource-based policy dela, a mesma ideia da bucket policy do capítulo 11.

### Antes do deploy, a cota da conta

A reserva de concorrência tem uma regra: a conta precisa manter pelo menos 100 execuções não reservadas. Numa conta nova, com cota reduzida, essa conta não fecha. Confira:

```bash
aws lambda get-account-settings \
  --query "AccountLimit.[ConcurrentExecutions,UnreservedConcurrentExecutions]" \
  --output text
```

```text
1000	1000
```

Se aparecer `10	10`, a reserva vai falhar no deploy com esta mensagem:

```text
Specified ReservedConcurrentExecutions for function decreases account's
UnreservedConcurrentExecution below its minimum value of [100].
```

Nesse caso, peça o aumento pelo Service Quotas (cota "Concurrent executions" do serviço AWS Lambda) e, enquanto ele não sai, comente a linha `reserved_concurrent_executions`.

### O deploy pelo pipeline

Reative os workflows desabilitados no fim do capítulo 18:

```bash
gh workflow enable ci.yaml
gh workflow enable renovar-tasks.yaml
```

Faça o commit de `backend/lambdas/` e `rango-infra/` e envie para a `main`. Depois da sua aprovação no environment `producao`, o `cdk deploy` roda o container que monta a layer e publica os zips no bucket do bootstrap. O runner `ubuntu-24.04-arm` já tem Docker, e a role `rango-github-deploy` não precisa de nada novo, porque as roles do bootstrap que ela assume fazem o trabalho. A stack inteira volta, com o banco do snapshot, a API no ECS e o front. No fim, pegue as saídas:

```bash
saida() {
  aws cloudformation describe-stacks --stack-name RangoProducao \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
URL_WEBHOOKS=$(saida UrlWebhooks)
SEGREDO_WEBHOOK_ARN=$(saida SegredoWebhookArn)
echo "$URL_WEBHOOKS"
```

```text
https://k3x9q2w7ab.execute-api.us-east-1.amazonaws.com
```

### O primeiro cold start

Chame a função de resumo à mão, com um período longo para pegar os pedidos que vieram do snapshot:

```bash
aws lambda invoke \
  --function-name rango-producao-resumo-vendas \
  --cli-binary-format raw-in-base64-out \
  --payload '{"horas": 720}' \
  --log-type Tail \
  --query LogResult --output text \
  resposta.json | base64 -d
cat resposta.json
```

O `--log-type Tail` devolve os últimos 4 KB do log da execução, em base64, e o `base64 -d` decodifica. O `--cli-binary-format` diz à CLI v2 que o payload é JSON puro.

```text
START RequestId: 8b1f0c2e-4d7a-4c55-9f0e-2a6b9d3c7e11 Version: $LATEST
{"evento": "resumo.enviado", "horas": 720, "restaurante": "cantina-da-nona", "pedidos": 41, "faturamento": "2414.90", "ticket_medio": "58.90"}
{"evento": "resumo.enviado", "horas": 720, "restaurante": "sabor-do-sertao", "pedidos": 17, "faturamento": "736.30", "ticket_medio": "43.31"}
END RequestId: 8b1f0c2e-4d7a-4c55-9f0e-2a6b9d3c7e11
REPORT RequestId: 8b1f0c2e-4d7a-4c55-9f0e-2a6b9d3c7e11	Duration: 812.45 ms	Billed Duration: 1290 ms	Memory Size: 512 MB	Max Memory Used: 96 MB	Init Duration: 476.83 ms
```

```text
{"restaurantes": 2, "horas": 720}
```

Os seus números vão ser outros. Na linha `REPORT`, o `Init Duration` de 477 ms é a fase INIT: imports e busca do segredo. O `Duration` de 812 ms é a primeira chamada, quase toda gasta abrindo a conexão TLS com o Postgres. O `Billed Duration` soma as duas: é a cobrança do INIT na prática. Rode de novo:

```text
REPORT RequestId: 1c7e5a90-...	Duration: 38.12 ms	Billed Duration: 39 ms	Memory Size: 512 MB	Max Memory Used: 97 MB
```

Sem `Init Duration`. O ambiente foi reaproveitado com a conexão aberta, e a chamada caiu de 1,3 segundo para 39 milissegundos. Para a rotina das 11h, tanto faz. Para uma API com usuário esperando, faz muita diferença.

### O webhook, assinado

Crie um pedido pela API. O gateway simulado do capítulo 5 forma o código da cobrança com os oito primeiros caracteres da chave de idempotência:

```bash
CHAVE=$(uuidgen | tr 'A-Z' 'a-z')
PEDIDO=$(curl -s -X POST https://api.rango.com.br/pedidos \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $CHAVE" \
  -d '{"usuario": "ana", "restaurante": "cantina-da-nona", "total": 58.90}' | jq -r .id)
COBRANCA="cobranca-${CHAVE:0:8}"
```

Agora faça o papel do gateway. Leia a chave do webhook, monte o aviso e assine:

```bash
CHAVE_WEBHOOK=$(aws secretsmanager get-secret-value \
  --secret-id "$SEGREDO_WEBHOOK_ARN" --query SecretString --output text)
CORPO="{\"pedido_id\": \"$PEDIDO\", \"cobranca\": \"$COBRANCA\", \"status\": \"aprovada\"}"
ASSINATURA="sha256=$(printf '%s' "$CORPO" \
  | openssl dgst -sha256 -hmac "$CHAVE_WEBHOOK" | awk '{print $NF}')"

curl -s -X POST "$URL_WEBHOOKS/webhooks/pagamento" \
  -H "Content-Type: application/json" \
  -H "X-Assinatura: $ASSINATURA" \
  -d "$CORPO"
```

```json
{"pedido_id": "5f0d2c1a-9e3b-4b7f-8a61-0c4e2d9b7a35", "status": "pago"}
```

A chave do webhook passou pela sua variável de ambiente local só para este teste. Ao terminar, rode `unset CHAVE_WEBHOOK`.

Confirme pela API, que lê o mesmo banco:

```bash
curl -s https://api.rango.com.br/pedidos/$PEDIDO | jq .status
```

```text
"pago"
```

Agora mande o mesmo corpo com uma assinatura errada, trocando o último caractere:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$URL_WEBHOOKS/webhooks/pagamento" \
  -H "Content-Type: application/json" \
  -H "X-Assinatura: ${ASSINATURA%?}0" \
  -d "$CORPO"
```

```text
401
```

E reenvie o aviso original, com a assinatura certa, como um gateway faria depois de um timeout. A resposta volta `200` com o mesmo `"status": "pago"`. O pedido continua igual.

### Quanto isso custa

Com os preços de referência de outubro de 2026 em us-east-1 (US$ 0,20 por milhão de chamadas e cerca de US$ 0,0000133 por GB-segundo em arm64; confira a página oficial), o resumo dá 90 execuções por mês de uns 2 segundos com 0,5 GB: 90 GB-segundos, menos de um centavo de dólar, contra os US$ 7 da task do ECS. Três mil webhooks por mês custam meio centavo na HTTP API. O que custa nesta arquitetura já existia antes: o banco e os endpoints da VPC.

### Desmontando

```bash
cd rango-infra
cdk destroy RangoProducao
gh workflow disable ci.yaml
gh workflow disable renovar-tasks.yaml
```

A exclusão pode demorar vários minutos a mais, porque as interfaces de rede da Lambda na VPC são liberadas aos poucos e travam a exclusão do Security Group e das subnets. O segredo do webhook entra em exclusão agendada, e o banco deixa um snapshot novo para o próximo capítulo.

## Quando serverless vale a pena, e quando não

Depois do resumo a menos de um centavo, a tentação é levar a API inteira para a Lambda. O Lambda Web Adapter permite isso, rodando o FastAPI dentro da função sem mudar o código. Faça a conta antes.

A API do Rangô recebe tráfego o dia inteiro. Suponha uma média de 50 requisições por segundo, cada uma com 100 ms, numa função de 512 MB em arm64. Num mês de 30 dias, são cerca de 130 milhões de chamadas. A duração dá 6,5 milhões de GB-segundos, uns US$ 86. As chamadas da Lambda somam uns US$ 26. A HTTP API cobra mais uns US$ 130. Total: perto de US$ 240 por mês. As duas tasks do ECS que o capítulo 17 estimou custam uns US$ 29, e mesmo somando o ALB a conta fica abaixo de US$ 60. Os valores são aproximados, mas a ordem de grandeza não muda.

O ECS cobra pela capacidade reservada, e um Uvicorn ocupado atende dezenas de requisições na mesma vCPU paga. A Lambda cobra por ambiente ocupado, inclusive o tempo esperando o banco responder. Com tráfego constante, você paga a conveniência em cada milissegundo.

Os critérios, para o Rangô e para quase todo projeto:

- **Tráfego intermitente ou imprevisível** favorece a Lambda. Zero chamadas custam zero.
- **Tráfego constante e alto** favorece containers.
- **Trabalho disparado por evento** (um horário, um arquivo no S3, uma mensagem, um webhook) é o terreno natural da Lambda.
- **Trabalhos longos** ficam no ECS: 15 minutos de teto, 30 segundos atrás do API Gateway.
- **Latência previsível** é difícil com cold starts, e a provisioned concurrency traz de volta a capacidade parada.
- **Muitas conexões com banco relacional** são um problema. A Lambda escala para centenas de ambientes em segundos, e o Postgres não acompanha. O RDS Proxy, um PgBouncer gerenciado e cobrado à parte, existe para isso, e serviços sem conexão persistente, como S3, SQS e DynamoDB, combinam melhor com funções.

O Rangô fica híbrido, como muita coisa em produção: a API e os workers do stream seguem no ECS, onde o tráfego é constante; o que roda de vez em quando ou reage a eventos externos vai para a Lambda.

## Armadilhas e casos reais

> **Armadilha:** Wheel do sistema errado. Quem instala as dependências da layer com um `pip install` simples num Mac ou num Linux x86 recebe binários que não rodam na Lambda arm64. O deploy funciona, e a primeira chamada falha com `Runtime.ImportModuleError: Unable to import module 'resumo_vendas': no pq wrapper available.` O `--platform` e o `--only-binary` do bundling existem para isso. Bibliotecas em Python puro não sofrem com o problema, por isso ele costuma aparecer só quando entra a primeira dependência com código compilado.

> **Armadilha:** Timeout padrão de 3 segundos. Uma função criada sem `timeout` explícito morre em 3 segundos, e um cold start que busca segredo e abre conexão TLS com o banco pode passar disso. O log mostra `Task timed out after 3.00 seconds`, e a função funciona na segunda tentativa, já aquecida. Esse "falha só às vezes" costuma consumir uma tarde de investigação.

> **Armadilha:** Grupo de logs sem retenção. Sem o `log_group` explícito, a Lambda cria sozinha o grupo `/aws/lambda/nome-da-funcao` na primeira execução, com retenção infinita. O CloudFormation não sabe que ele existe, então o grupo sobrevive ao `cdk destroy` e cresce para sempre, cobrando armazenamento. Defina o grupo na stack, com retenção.

> **Armadilha:** Laço recursivo. Uma função disparada por upload no S3 gera uma miniatura e grava no mesmo bucket. A gravação dispara a função de novo, que gera a miniatura da miniatura, e assim por diante, com a concorrência subindo até o limite da conta. A AWS hoje detecta e interrompe esse tipo de laço para algumas combinações de serviços, mas não conte com isso: grave a saída em outro bucket ou em outro prefixo, e filtre o gatilho pelo prefixo de entrada.

> **Armadilha:** Estado que vaza entre chamadas. Variáveis globais sobrevivem entre invocações, o que serve para conexões e, por engano, para dados de uma requisição. Num exemplo hipotético, uma função guarda o usuário autenticado numa global, a chamada seguinte de outro usuário falha antes de sobrescrever, e a resposta sai com os dados do primeiro. O que é da requisição fica dentro do `handler`, inclusive arquivos em `/tmp`.

> **Armadilha:** Cron em UTC. Um `cron(0 11 * * ? *)` numa regra do EventBridge dispara às 8h em Brasília, antes de a cozinha abrir.

> **Dica:** O `event` é só um dicionário. No pytest, chame o handler com um evento de exemplo no formato 2.0 e você cobre a maior parte dos testes sem ferramenta extra.

## Resumo

- A Lambda executa uma função Python (`handler(event, context)`) quando um evento acontece e cobra por chamada e por GB-segundo. Zero chamadas custam zero.
- Cada ambiente de execução passa por INIT uma vez, atende uma chamada por vez e fica congelado entre chamadas. Cold start é o INIT somado à primeira chamada; desde agosto de 2025, o INIT é cobrado.
- Memória vai de 128 MB a 10.240 MB, com CPU proporcional (1.769 MB equivalem a uma vCPU). O teto de execução é de 15 minutos; o padrão de timeout, 3 segundos.
- A concorrência padrão é de 1.000 ambientes por região, menor em contas novas. Reservar concorrência protege o banco e exige deixar 100 execuções livres na conta.
- Layers levam dependências para `/opt/python`, no máximo cinco por função. Monte as wheels para a arquitetura certa.
- O API Gateway transforma HTTP em evento. A HTTP API (US$ 1,00 por milhão) serve à maioria dos casos e corta integrações em 30 segundos; a REST API (US$ 3,50) traz chaves de API, validação, WAF, endpoints privados e cache.
- O Rangô ganhou a `resumo-vendas`, disparada por três regras do EventBridge em UTC, e a `webhook-pagamento`, atrás de uma HTTP API, com assinatura HMAC e `UPDATE` idempotente. As duas rodam na VPC e falam com o RDS.
- Serverless vale para trabalho intermitente e disparado por evento. Para tráfego constante, muitas conexões com banco relacional ou tarefas longas, containers saem mais baratos e mais previsíveis.

## Entregadores a cada cinco segundos

Com o PIX funcionando, o Bruno volta com a próxima ideia, e essa ele chama de prioridade da empresa: o cliente quer ver o entregador no mapa, em tempo real. O aplicativo do entregador manda a posição a cada cinco segundos, e o React do cliente pergunta "onde está meu pedido?" com a mesma frequência.

Com 200 entregadores no jantar, são 40 gravações por segundo só de posição, mais as leituras dos clientes esperando. Cada posição vira uma linha numa tabela que cresce milhões de linhas por semana e que ninguém consulta depois de uma hora. Coloque isso no `db.t4g.micro` dos pedidos, que mal aguentou seis instâncias no capítulo 13, com Lambdas na frente, cada uma com a sua conexão. O Postgres passa o jantar gravando coordenadas que vão para o lixo em seguida.

O próximo capítulo apresenta o Amazon DynamoDB, um banco acessado por HTTP, sem conexão persistente, que aguenta milhares de gravações por segundo e apaga sozinho o que expirou. Ele obriga você a desenhar as tabelas começando pelas perguntas que a aplicação vai fazer. E o capítulo mostra também quando ele é a escolha errada.

## Referências

- AWS Lambda, cotas e limites: https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html
- AWS Lambda, runtimes e calendário de descontinuação: https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html
- AWS Lambda, preços: https://aws.amazon.com/lambda/pricing/
- AWS Compute Blog, cobrança da fase INIT padronizada (2025): https://aws.amazon.com/blogs/compute/aws-lambda-standardizes-billing-for-init-phase/
- AWS What's New, SnapStart para Python e .NET (nov/2024): https://aws.amazon.com/about-aws/whats-new/2024/11/aws-lambda-snapstart-python-net-functions/
- Lambda Web Adapter, SnapStart: https://aws.github.io/aws-lambda-web-adapter/features/snapstart.html
- Amazon API Gateway, HTTP API versus REST API: https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-vs-rest.html
- Amazon API Gateway, cotas da HTTP API: https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-quotas.html
- Amazon API Gateway, preços: https://aws.amazon.com/api-gateway/pricing/
