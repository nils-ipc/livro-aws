# DynamoDB

No capítulo anterior, o resumo de vendas e o webhook do PIX saíram do servidor e viraram funções Lambda: código que só existe quando é chamado, cobrado por milissegundo, atrás de uma HTTP API do API Gateway. O capítulo terminou com um aviso que vale para este: Lambda escala para centenas de ambientes em segundos, e o Postgres não acompanha. A stack `RangoProducao` foi destruída, e o banco deixou um snapshot novo esperando por nós.

## Quarenta coordenadas por segundo

O pedido do Bruno parece simples. O cliente quer ver o entregador andando no mapa. O aplicativo do entregador manda a posição a cada cinco segundos, e a tela do React pergunta "onde está meu pedido?" no mesmo ritmo.

A primeira versão que vem à cabeça é uma tabela no Postgres que já existe:

```sql
CREATE TABLE posicoes (
    pedido_id     uuid NOT NULL REFERENCES pedidos (id),
    lat           numeric(9, 6) NOT NULL,
    lon           numeric(9, 6) NOT NULL,
    registrada_em timestamptz NOT NULL,
    PRIMARY KEY (pedido_id, registrada_em)
);
```

Funciona no notebook. Agora faça a conta do jantar. Com 200 entregadores na rua, são 40 gravações por segundo, mais 40 leituras dos clientes olhando o mapa. Em quatro horas de pico por dia, isso dá 576 mil linhas por noite, uns 4 milhões por semana. Cada `INSERT` mexe no índice da chave primária, gera WAL, entra no backup e na réplica. E quase nenhuma dessas linhas vai ser lida de novo depois que o pedido chegar: passada uma hora, ninguém quer saber onde o entregador estava às 20h41.

Agora coloque essa carga no `db.t4g.micro`, que já mostrou o `FATAL: sorry, too many clients already` no capítulo 13. Se a gravação de posição for para uma Lambda, cada ambiente abre a sua conexão. Num sábado de chuva, com o dobro de entregadores, as conexões acabam, e quem sofre junto é o `POST /pedidos`, que divide o mesmo banco. Um mapa derrubando a confirmação de pedidos rende um postmortem constrangedor.

Daria para remendar com instância maior, RDS Proxy e um job noturno apagando linhas velhas, cada peça custando dinheiro e atenção. O rastreamento pede um lugar que aceite muitas gravações pequenas, responda a perguntas simples em milissegundos, dispense conexão aberta e jogue fora sozinho o que envelheceu.

## Um dicionário do tamanho que você precisar

O **Amazon DynamoDB** é um banco de dados chave-valor e de documentos, totalmente gerenciado. Não existe instância para escolher, disco para aumentar ou versão para atualizar. E não existe conexão: cada operação é uma chamada HTTPS assinada com SigV4, autorizada pelo IAM. Mil Lambdas gravando nele não seguram nada aberto.

Para quem programa em Python, pense num dicionário de dicionários distribuído por muitas máquinas:

```python
tabela = {
    ("PEDIDO#5f0d2c1a", "ATUAL"): {"status": "em_rota", "entregador": "joao-p"},
    ("PEDIDO#5f0d2c1a", "POS#1792094460000"): {"posicao": {"lat": -8.05, "lon": -34.9}},
}
```

Cada linha é um **item**, e os campos dele são **atributos**. Fora da chave, nenhum atributo é obrigatório, e dois itens da mesma tabela podem ter atributos diferentes. Não existe `ALTER TABLE`: você grava o atributo novo, e ele passa a existir naquele item.

### Partition key e sort key

A chave primária tem uma ou duas partes, e entender as duas é metade do capítulo.

A **partition key** decide onde o item mora. O DynamoDB calcula um hash dela para escolher a **partição**, um pedaço da tabela guardado em servidores e replicado em três zonas de disponibilidade. É o `hash()` que escolhe a posição de uma chave num `dict`, só que o balde é uma máquina. Conforme a tabela cresce, o DynamoDB divide partições sem você ver.

A **sort key** é opcional e ordena os itens com a mesma partition key. Esses itens formam uma **item collection** e ficam guardados juntos, em ordem: uma lista ordenada pendurada em cada chave do dicionário. É isso que permite pedir "as últimas 120 posições do pedido X" numa única leitura sequencial. A combinação das duas identifica o item, e gravar de novo a mesma combinação substitui o item.

Cada partição tem um teto de cerca de 3.000 unidades de leitura e 1.000 de escrita por segundo. A *adaptive capacity* remaneja capacidade para uma partição muito procurada, sem passar desse teto. Por isso a partition key precisa espalhar o tráfego. O `id` do pedido espalha bem; a data do dia concentra todo mundo na mesma chave, a *hot partition*.

### As operações, e a que você deve evitar

A API é pequena. Para um item, você tem `PutItem` (grava ou substitui), `GetItem` (lê pela chave completa), `UpdateItem` (altera atributos, criando o item se ele não existir) e `DeleteItem`. Para vários, tem `Query` e `Scan`.

A `Query` recebe uma partition key exata e, opcionalmente, uma condição sobre a sort key: igual, maior, menor, entre dois valores ou "começa com". Ela lê só aquela item collection, em ordem, para frente ou para trás: um `SELECT ... WHERE pk = ? AND sk BETWEEN ? AND ? ORDER BY sk` que sempre usa índice, porque o próprio armazenamento é o índice.

O `Scan` lê a tabela inteira, e você paga pela leitura de tudo. Ele existe para exportações e manutenção.

A pegadinha para quem vem do SQL é a *filter expression*. `Query` e `Scan` aceitam um filtro sobre qualquer atributo, que parece um `WHERE`, só que roda depois da leitura. O DynamoDB lê os itens, cobra por eles e então descarta os que não passam. Um `Scan` com filtro `restaurante = cantina-da-nona` custa o mesmo que o `Scan` sem filtro. Também não há `JOIN`, `GROUP BY` ou subconsulta: se a pergunta não cabe numa `Query`, você muda o desenho das chaves ou cria um índice.

As leituras são *eventualmente consistentes* por padrão: logo depois de uma gravação, uma leitura pode devolver a versão anterior por uma fração de segundo. A leitura *fortemente consistente* (`ConsistentRead=True`) custa o dobro. E toda escrita aceita uma *condition expression*, "grave só se o atributo X tiver o valor Y"; se a condição falhar, nada é gravado e você recebe `ConditionalCheckFailedException`. É o `UPDATE ... WHERE status = 'pago'` do capítulo 19, com checagem e escrita atômicas no mesmo item.

### Capacidade: pagar por requisição ou reservar

O DynamoDB mede o trabalho em unidades. Na escrita, uma unidade cobre um item de até 1 KB; um item de 2,5 KB consome 3. Na leitura, uma unidade cobre até 4 KB com consistência forte; a leitura eventualmente consistente consome meia. As unidades usam KB binário, 1.024 bytes, e escritas dentro de transação contam em dobro.

No modo **on-demand**, você paga por requisição. Não há nada para configurar: a tabela aceita o tráfego que chegar, até a cota padrão de 40.000 unidades de leitura e 40.000 de escrita por segundo por tabela, que pode ser aumentada. Os preços de referência em us-east-1, consultados em outubro de 2026, são de cerca de US$ 0,625 por milhão de unidades de escrita e US$ 0,125 por milhão de unidades de leitura. São valores aproximados; confira a página oficial e a calculadora antes de decidir. Em novembro de 2024, a AWS cortou pela metade o preço do on-demand em todas as regiões e passou a tratá-lo como o modo padrão para a maioria das cargas.

No modo **provisionado**, você declara quantas unidades por segundo a tabela suporta (RCU para leitura, WCU para escrita) e paga por hora pela reserva, use ou não. O excedente recebe `ProvisionedThroughputExceededException`. O auto scaling ajusta a capacidade por política de alvo, como o ASG do capítulo 13, mas reduzir tem limite: quatro vezes no início do dia em UTC e mais uma por hora, no máximo 27 por dia.

Comece em on-demand. O provisionado compensa com tráfego alto, estável e já medido. O nível gratuito vale só para o provisionado (25 WCU e 25 RCU) e para os primeiros 25 GB de armazenamento, que custa cerca de US$ 0,25 por GB-mês na classe Standard.

## Começar pelas perguntas

No Postgres, você modela as entidades, normaliza e depois escreve as consultas; o planejador responde qualquer `SELECT` que você inventar amanhã. O DynamoDB inverte a ordem. Você começa listando os **padrões de acesso**: as perguntas exatas que a aplicação vai fazer, com que frequência e com que dados na mão. Depois desenha as chaves para que cada pergunta vire um `GetItem` ou uma `Query`.

Para o rastreamento do Rangô, as perguntas são estas:

| # | Quem pergunta | Pergunta | Frequência |
|---|---------------|----------|------------|
| 1 | App do entregador | Gravar a posição atual do pedido X | a cada 5 s por entregador |
| 2 | Cliente | Onde está o entregador do pedido X agora? | a cada 5 s por cliente |
| 3 | Cliente | Qual o trajeto dos últimos minutos do pedido X? | ao abrir o mapa |
| 4 | Restaurante | Quais entregas minhas estão na rua agora? | a cada 30 s |
| 5 | Entregador | Iniciar e concluir a entrega do pedido X | 2 vezes por pedido |

Repare no que falta: nenhuma pergunta do tipo "quanto tempo em média os entregadores levaram em outubro". Essa pergunta existe, o Bruno vai fazê-la um dia, e o lugar dela é outro. Voltamos a isso na seção sobre quando não usar.

### Uma tabela, vários tipos de item

As perguntas 2, 3 e 5 giram em torno do pedido. Então a partition key é o pedido, e dentro da item collection dele moram dois tipos de item:

```text
pk                     sk                    atributos
---------------------  --------------------  ---------------------------------------------
PEDIDO#5f0d2c1a-...    ATUAL                 status, entregador, restaurante, posicao,
                                             registrada_em, iniciada_em
PEDIDO#5f0d2c1a-...    POS#1792094455000     posicao, expira_em
PEDIDO#5f0d2c1a-...    POS#1792094460000     posicao, expira_em
PEDIDO#5f0d2c1a-...    POS#1792094465000     posicao, expira_em
```

O item `ATUAL` guarda o estado da entrega e a última posição. Ele é sobrescrito a cada cinco segundos e responde à pergunta 2 com um `GetItem`. Os itens `POS#...` são o histórico: um por posição, com a sort key formada pelo instante em milissegundos. A pergunta 3 vira uma `Query` com `begins_with(sk, "POS#")`, em ordem decrescente, limitada aos últimos 120 pontos (dez minutos).

O número na sort key tem 13 dígitos, completados com zeros à esquerda. A sort key é texto, e texto ordena caractere a caractere: sem o preenchimento, `"POS#999"` viria depois de `"POS#1000"`. Toda chave numérica dentro de uma string precisa desse cuidado, o mesmo que você já teve ao nomear arquivos `01-`, `02-` para o `ls` mostrar na ordem.

Os nomes genéricos `pk` e `sk`, com prefixos como `PEDIDO#` e `POS#`, são a marca de uma técnica chamada **single-table design**: guardar entidades diferentes na mesma tabela, com as chaves arranjadas para que itens lidos juntos fiquem na mesma item collection. Para quem vem do SQL, é como guardar o resultado de um `JOIN` já pronto. Em vez de juntar `entregas` e `posicoes` na hora da leitura, você grava as duas coisas lado a lado e lê de uma vez.

A técnica tem custo. Uma tabela com dez tipos de item é difícil de ler no console, de explicar para quem chega no time e de mudar quando aparece um padrão de acesso imprevisto. Para o Rangô, a regra é modesta: uma tabela por domínio, com os itens lidos juntos. O rastreamento ganha a sua, `rango-entregas`.

### Um índice para o restaurante

A pergunta 4 tem o restaurante na mão, e a partition key da tabela é o pedido. Sobraria o `Scan` com filtro, que lê tudo.

A resposta é um **Global Secondary Index** (GSI): uma cópia de parte da tabela, mantida pelo DynamoDB de forma assíncrona, com outra chave primária. O índice `por-restaurante` usa `restaurante` como partition key e `iniciada_em` como sort key, e a `Query` nele responde "entregas da Cantina da Nona, da mais antiga para a mais nova". Leituras em GSI são sempre eventualmente consistentes, o que o painel do restaurante nem percebe.

Um item só entra no GSI se tiver todos os atributos da chave do índice. Os itens `POS#...` não têm `restaurante` e ficam de fora; quando a entrega termina, remover `restaurante` do item `ATUAL` tira a entrega do índice. Esse padrão se chama **índice esparso** (*sparse index*): o GSI guarda só as entregas em andamento.

O custo: toda escrita que mexe em atributos projetados no índice também é uma escrita no índice, cobrada à parte. A projeção padrão é `ALL`; há também `KEYS_ONLY` e `INCLUDE`. Como o restaurante quer ver a posição, fica `ALL`, e cada posição custa duas escritas, uma na tabela e uma no índice.

> **Dica:** Existe também o Local Secondary Index (LSI), que troca só a sort key. Ele nasce com a tabela, no máximo cinco, e impede o DynamoDB de dividir uma item collection entre partições. Na dúvida, use GSI (até 20 por tabela, na cota padrão).

> **Dica:** Desde novembro de 2025, a chave de um GSI pode ter até quatro atributos na partition key e quatro na sort key, sem custo adicional. Antes disso, um índice por "restaurante e status" exigia gravar um atributo sintético como `cantina-da-nona#em_rota`. Se você encontrar esse padrão de concatenação em código antigo, saiba que hoje ele tem alternativa.

## Mão na massa

Vamos acrescentar ao Rangô a tabela `rango-entregas`, as rotas de rastreamento na API do ECS e uma Lambda que avisa o Postgres quando a entrega termina. A tabela cuida do que muda a cada cinco segundos; o pedido, com status, valor e cobrança, continua no Postgres, que é o lugar dele.

### O ponto de partida

Como no capítulo anterior, encontre o snapshot deixado pelo `cdk destroy`:

```bash
aws rds describe-db-snapshots --snapshot-type manual \
  --query "reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[0].DBSnapshotIdentifier" \
  --output text
```

Coloque o nome no `snapshot_db` do `rango-infra/app.py`. O pedido pago no teste do webhook do capítulo 19 está nesse snapshot, e vai servir de cobaia.

### A tabela na stack

No `rango-infra/rango_infra/rango_infra_stack.py`, acrescente os imports:

```python
from aws_cdk import (
    # ... os imports do capítulo 19 ...
    aws_dynamodb as dynamodb,
    aws_lambda_event_sources as fontes,
)
```

E a tabela, logo depois da VPC:

```python
        tabela_entregas = dynamodb.Table(
            self,
            "TabelaEntregas",
            partition_key=dynamodb.Attribute(name="pk", type=dynamodb.AttributeType.STRING),
            sort_key=dynamodb.Attribute(name="sk", type=dynamodb.AttributeType.STRING),
            billing_mode=dynamodb.BillingMode.PAY_PER_REQUEST,
            time_to_live_attribute="expira_em",
            stream=dynamodb.StreamViewType.NEW_AND_OLD_IMAGES,
            removal_policy=RemovalPolicy.DESTROY,
        )
        tabela_entregas.add_global_secondary_index(
            index_name="por-restaurante",
            partition_key=dynamodb.Attribute(name="restaurante", type=dynamodb.AttributeType.STRING),
            sort_key=dynamodb.Attribute(name="iniciada_em", type=dynamodb.AttributeType.NUMBER),
        )
```

Repare no que a declaração tem e no que ela não tem. Só os atributos das chaves são declarados, com tipo (`STRING` ou `NUMBER`); todo o resto do item é livre. O `PAY_PER_REQUEST` é o on-demand. O nome fica a cargo do CDK, pelo mesmo motivo dos segredos: nome fixo impede a substituição do recurso. O `DESTROY` faz sentido aqui porque posições de entrega são descartáveis por natureza; numa tabela com dados que importam, use `RETAIN` e ligue o point-in-time recovery, que custa cerca de US$ 0,20 por GB-mês e restaura a tabela para qualquer segundo dos últimos 35 dias, como o PITR do RDS no capítulo 12.

O `time_to_live_attribute` e o `stream` são os dois recursos que ainda não apresentei. Eles merecem uma seção cada, e chegam logo depois do código.

### O caminho de rede

As tarefas do ECS rodam nas subnets `PRIVATE_ISOLATED`, sem NAT e sem internet. Até aqui, cada serviço da AWS que a API usa ganhou um endpoint na VPC. O DynamoDB é um dos dois serviços com *gateway endpoint*, o tipo gratuito que você criou para o S3 no capítulo 10:

```python
        vpc.add_gateway_endpoint(
            "DynamoDb",
            service=ec2.GatewayVpcEndpointAwsService.DYNAMODB,
            subnets=[privadas],
        )
```

Sem essa linha, o log mostra `ConnectTimeoutError` para `dynamodb.us-east-1.amazonaws.com`, depois de algumas retentativas do boto3. Leva uma tarde para entender, porque a permissão está certa e a tabela existe.

### A API ganha acesso à tabela

Na task role da API e no container:

```python
        tabela_entregas.grant_read_write_data(role_app)
```

```python
        tarefa_api.add_container(
            "api",
            image=imagem,
            secrets=variaveis,
            environment={"TABELA_ENTREGAS": tabela_entregas.table_name},
            port_mappings=[ecs.PortMapping(container_port=8000)],
            logging=ecs.LogDrivers.aws_logs(stream_prefix="api", log_group=logs_app),
        )
```

O `grant_read_write_data` cria uma policy com as ações de leitura e escrita de itens, no ARN da tabela e no ARN dos índices dela (`.../index/*`). Esquecer os índices é um erro comum quando se escreve a policy à mão: a `Query` na tabela funciona, a `Query` no GSI devolve `AccessDeniedException`. O nome da tabela é configuração, então vai como variável de ambiente comum.

### O código da API

Crie `backend/app/entregas.py`:

```python
import os
import time
import uuid
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Attr, Key
from fastapi import APIRouter, HTTPException, Path
from pydantic import BaseModel, Field

from app.banco import pool

tabela = boto3.resource(
    "dynamodb", region_name=os.environ.get("AWS_REGION", "us-east-1")
).Table(os.environ.get("TABELA_ENTREGAS", "rango-entregas-local"))
CondicaoFalhou = tabela.meta.client.exceptions.ConditionalCheckFailedException

router = APIRouter()
Restaurante = Path(pattern=r"^[a-z0-9-]{1,60}$")
HISTORICO_SEGUNDOS = 24 * 3600


class Inicio(BaseModel):
    entregador: str = Field(pattern=r"^[a-z0-9-]{1,40}$")


class Posicao(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    registrada_em: int = Field(gt=0)  # epoch em milissegundos, do celular


def chave(pedido_id: uuid.UUID) -> dict:
    return {"pk": f"PEDIDO#{pedido_id}", "sk": "ATUAL"}


@router.post("/entregas/{pedido_id}/iniciar", status_code=201)
def iniciar(pedido_id: uuid.UUID, inicio: Inicio):
    with pool.connection() as con:
        pedido = con.execute(
            "SELECT restaurante FROM pedidos WHERE id = %s AND status = 'pago'",
            (pedido_id,),
        ).fetchone()
    if pedido is None:
        raise HTTPException(404, "pedido pago não encontrado")
    try:
        tabela.put_item(
            Item={
                **chave(pedido_id),
                "status": "em_rota",
                "entregador": inicio.entregador,
                "restaurante": pedido["restaurante"],
                "iniciada_em": int(time.time()),
                "registrada_em": 0,
            },
            ConditionExpression="attribute_not_exists(pk)",
        )
    except CondicaoFalhou:
        raise HTTPException(409, "entrega já iniciada")
    return {"pedido_id": str(pedido_id), "status": "em_rota"}


@router.post("/entregas/{pedido_id}/posicao", status_code=204)
def registrar_posicao(pedido_id: uuid.UUID, p: Posicao):
    posicao = {"lat": Decimal(str(p.lat)), "lon": Decimal(str(p.lon))}
    try:
        tabela.update_item(
            Key=chave(pedido_id),
            UpdateExpression="SET posicao = :pos, registrada_em = :t",
            ConditionExpression="#st = :em_rota AND registrada_em < :t",
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={
                ":pos": posicao,
                ":t": p.registrada_em,
                ":em_rota": "em_rota",
            },
        )
    except CondicaoFalhou:
        return  # posição atrasada ou entrega encerrada: descarta
    tabela.put_item(
        Item={
            "pk": f"PEDIDO#{pedido_id}",
            "sk": f"POS#{p.registrada_em:013d}",
            "posicao": posicao,
            "expira_em": int(time.time()) + HISTORICO_SEGUNDOS,
        }
    )


@router.get("/entregas/{pedido_id}")
def posicao_atual(pedido_id: uuid.UUID):
    item = tabela.get_item(Key=chave(pedido_id)).get("Item")
    if item is None:
        raise HTTPException(404, "entrega não encontrada")
    return {k: item.get(k) for k in ("status", "entregador", "posicao", "registrada_em")}


@router.get("/entregas/{pedido_id}/trajeto")
def trajeto(pedido_id: uuid.UUID):
    resposta = tabela.query(
        KeyConditionExpression=Key("pk").eq(f"PEDIDO#{pedido_id}")
        & Key("sk").begins_with("POS#"),
        FilterExpression=Attr("expira_em").gt(int(time.time())),
        ScanIndexForward=False,
        Limit=120,
    )
    return [item["posicao"] for item in reversed(resposta["Items"])]


@router.get("/restaurantes/{restaurante}/entregas")
def entregas_do_restaurante(restaurante: str = Restaurante):
    resposta = tabela.query(
        IndexName="por-restaurante",
        KeyConditionExpression=Key("restaurante").eq(restaurante),
    )
    return [
        {
            "pedido_id": item["pk"].removeprefix("PEDIDO#"),
            "entregador": item["entregador"],
            "posicao": item.get("posicao"),
        }
        for item in resposta["Items"]
    ]


@router.post("/entregas/{pedido_id}/concluir")
def concluir(pedido_id: uuid.UUID):
    agora = int(time.time())
    try:
        tabela.update_item(
            Key=chave(pedido_id),
            UpdateExpression="SET #st = :entregue, concluida_em = :agora, "
            "expira_em = :expira REMOVE restaurante",
            ConditionExpression="#st = :em_rota",
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={
                ":entregue": "entregue",
                ":em_rota": "em_rota",
                ":agora": agora,
                ":expira": agora + HISTORICO_SEGUNDOS,
            },
        )
    except CondicaoFalhou:
        raise HTTPException(409, "entrega não está em rota")
    return {"pedido_id": str(pedido_id), "status": "entregue"}
```

O `iniciar` lê o pedido no Postgres uma única vez, para conferir o pagamento e descobrir o restaurante; daí em diante, as posições não tocam no Postgres. O `attribute_not_exists(pk)` faz o `PutItem` falhar se o item `ATUAL` já existir, o que impede dois entregadores de iniciarem a mesma entrega.

O `registrar_posicao` usa `UpdateItem` com condição dupla. A primeira parte recusa posições de entregas encerradas ou nunca iniciadas. A segunda (`registrada_em < :t`) resolve um problema do capítulo 5: a rede do celular reordena mensagens, e a posição das 20h41min05s pode chegar depois da das 20h41min10s. Sem a condição, o mapa pularia para trás. Com ela, o próprio banco descarta a posição velha, sem ler antes de escrever. O instante vem do celular, que conhece a ordem real das leituras do GPS.

O `#st` existe porque `status` é palavra reservada do DynamoDB, e usá-lo direto numa expressão dá `ValidationException: ... Attribute name is a reserved keyword; reserved keyword: status`. A lista tem centenas de palavras; a posição vive num mapa `posicao` justamente para que `lat` e `lon` entrem como valor, sem placeholders.

O `Decimal(str(...))` é obrigatório, porque o boto3 se recusa a gravar `float`:

```text
TypeError: Float types are not supported. Use Decimal types instead.
```

O número do DynamoDB tem precisão decimal, e o `float` do Python é binário: `-8.05` vira `-8.0500000000000007105...`. Passar pelo `str` gera o `Decimal("-8.05")` esperado. Na leitura, o FastAPI converte os `Decimal` para JSON sozinho.

O `trajeto` usa a filter expression do jeito certo: sobre itens que a `Query` já leu pela chave, para esconder posições expiradas (o motivo aparece na seção sobre TTL). O `Limit` conta os itens lidos antes do filtro. E o `concluir` faz três coisas numa escrita condicional: muda o status, remove `restaurante` (tirando a entrega do índice esparso) e dá ao item `ATUAL` um prazo de expiração.

Inclua o router no `backend/app/main.py`, como o das fotos:

```python
from app.entregas import router as entregas_router

app.include_router(entregas_router)
```

> **Armadilha:** As rotas `iniciar`, `posicao` e `concluir` aceitam qualquer chamada, e o Rangô ainda não tem login de entregador. Do jeito que está, qualquer pessoa que descubra o `id` de um pedido pode mover o entregador no mapa ou marcar a entrega como concluída. A rota do restaurante ganha login ainda neste capítulo, mas o entregador fica para depois. Antes de produção de verdade, essas rotas precisam autenticar o entregador e conferir que ele é o dono da entrega. Autenticação é código que pede uma biblioteca estabelecida (um provedor OIDC, como o Amazon Cognito, ou o que a empresa já usa) e revisão de alguém de segurança.

> **Dica:** O `TABELA_ENTREGAS` tem um valor padrão para os testes do CI e o Compose subirem sem AWS. Para desenvolver contra uma tabela local, existe a imagem oficial `amazon/dynamodb-local`, e o boto3 aceita a variável de ambiente `AWS_ENDPOINT_URL_DYNAMODB` para apontar para ela sem mudar o código.

No React, o mapa do cliente pergunta a posição a cada cinco segundos. O componente de mapa fica por sua conta; a parte que conversa com a API é esta:

```tsx
import { useEffect, useState } from "react";

type Posicao = { lat: number; lon: number };

export function usePosicaoEntregador(pedidoId: string) {
  const [posicao, setPosicao] = useState<Posicao | null>(null);

  useEffect(() => {
    const buscar = async () => {
      const resposta = await fetch(`${import.meta.env.VITE_API_URL}/entregas/${pedidoId}`);
      if (resposta.ok) setPosicao((await resposta.json()).posicao);
    };
    buscar();
    const intervalo = setInterval(buscar, 5000);
    return () => clearInterval(intervalo);
  }, [pedidoId]);

  return posicao;
}
```

### TTL: o banco joga fora o que envelheceu

O **Time to Live** (TTL) é o job de limpeza que você não precisa escrever. Você escolhe um atributo da tabela, aqui o `expira_em`, e grava nele um instante no formato epoch Unix em segundos, como `Number`. Quando esse instante passa, o DynamoDB apaga o item por conta própria, sem cobrar escrita por isso. Se o atributo não existir no item ou tiver outro tipo (uma string com data ISO, por exemplo), o item é ignorado e vive para sempre.

É o `EXPIRE` do Redis do capítulo 4, com uma diferença que pega muita gente: o apagamento acontece "tipicamente dentro de alguns dias" depois da expiração, nas palavras da documentação. Até lá, o item expirado continua aparecendo em `GetItem`, `Query` e `Scan`, e por isso o `trajeto` filtra por `expira_em`. TTL controla o tamanho da tabela; regra de negócio confere a data no código.

Atualizar um item expirado antes da limpeza, estendendo ou removendo o `expira_em`, cancela a expiração; a documentação recomenda uma condition expression quando o item não deveria ressuscitar. E as exclusões do TTL aparecem no Stream marcadas como feitas pelo serviço.

No Rangô, o histórico fica 24 horas, e o item `ATUAL` some 24 horas depois da conclusão. Localização de entregador é dado pessoal, e a LGPD agradece quando ele não fica guardado sem motivo.

### O painel do restaurante ganha um login

Hoje, quem adivinhar o nome `cantina-da-nona` vê onde estão os entregadores do restaurante. O painel precisa de login, e sessão é um caso clássico para o DynamoDB: chave conhecida, `GetItem` e prazo de validade. Uma tabela do domínio do painel guarda usuários e sessões, logo abaixo da `TabelaEntregas`:

```python
        tabela_painel = dynamodb.Table(
            self,
            "TabelaPainel",
            partition_key=dynamodb.Attribute(name="pk", type=dynamodb.AttributeType.STRING),
            billing_mode=dynamodb.BillingMode.PAY_PER_REQUEST,
            time_to_live_attribute="expira_em",
            removal_policy=RemovalPolicy.DESTROY,
        )
        tabela_painel.grant_read_write_data(role_app)
```

No container da API, o `environment` ganha `"TABELA_PAINEL": tabela_painel.table_name`. Acrescente `argon2-cffi` ao `backend/requirements.txt`, fixando a versão, e crie `backend/app/painel.py`:

```python
import hashlib
import os
import secrets
import time

import boto3
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

tabela = boto3.resource(
    "dynamodb", region_name=os.environ.get("AWS_REGION", "us-east-1")
).Table(os.environ.get("TABELA_PAINEL", "rango-painel-local"))

router = APIRouter()
hasher = PasswordHasher()
HASH_DESCARTAVEL = hasher.hash(secrets.token_urlsafe(16))
SESSAO_SEGUNDOS = 8 * 3600


class Login(BaseModel):
    email: str
    senha: str


def chave_sessao(token: str) -> dict:
    return {"pk": "SESSAO#" + hashlib.sha256(token.encode()).hexdigest()}


@router.post("/painel/entrar")
def entrar(login: Login):
    usuario = tabela.get_item(Key={"pk": f"USUARIO#{login.email.lower()}"}).get("Item")
    try:
        hasher.verify(usuario["hash_senha"] if usuario else HASH_DESCARTAVEL, login.senha)
    except VerificationError:
        usuario = None
    if usuario is None:
        raise HTTPException(401, "e-mail ou senha inválidos")
    token = secrets.token_urlsafe(32)
    tabela.put_item(
        Item={
            **chave_sessao(token),
            "restaurante": usuario["restaurante"],
            "expira_em": int(time.time()) + SESSAO_SEGUNDOS,
        }
    )
    return {"token": token, "restaurante": usuario["restaurante"]}


def restaurante_logado(authorization: str = Header(default="")) -> str:
    token = authorization.removeprefix("Bearer ")
    sessao = tabela.get_item(Key=chave_sessao(token)).get("Item") if token else None
    if sessao is None or sessao["expira_em"] < time.time():
        raise HTTPException(401, "sessão inválida")
    return sessao["restaurante"]
```

A tabela guarda só o hash Argon2 da senha, feito por uma biblioteca estabelecida. Para e-mail inexistente, o código verifica contra um hash descartável, e a resposta tem o mesmo tempo e a mesma mensagem. Do token, a tabela guarda só o SHA-256; quem a ler não se passa por ninguém. E, como o TTL apaga com atraso, a sessão vencida é recusada pelo código.

No `entregas.py`, a rota do restaurante passa a exigir a sessão e a conferir o dono:

```python
from fastapi import Depends

from app.painel import restaurante_logado


@router.get("/restaurantes/{restaurante}/entregas")
def entregas_do_restaurante(
    restaurante: str = Restaurante, logado: str = Depends(restaurante_logado)
):
    if logado != restaurante:
        raise HTTPException(403, "sessão de outro restaurante")
    resposta = tabela.query(
        # ... igual ao anterior ...
```

Inclua o `painel_router` no `main.py`. No React, o painel guarda o token em memória e o manda no cabeçalho `Authorization: Bearer`. É um login mínimo, sem MFA nem limite de tentativas, e precisa de revisão de alguém de segurança antes da produção; o capítulo 23 volta a ele.

### Streams: a entrega concluída chega ao Postgres

O pedido no Postgres precisa saber que foi entregue. O caminho óbvio é o `concluir` fazer um `UPDATE` no Postgres depois de gravar no DynamoDB. É a escrita dupla do capítulo 5: se o processo morrer entre as duas, os dois bancos discordam para sempre.

O **DynamoDB Streams** resolve isso do lado do banco. Ele registra cada alteração de item num log ordenado por item, disponível por 24 horas. Cada registro carrega só as chaves (`KEYS_ONLY`), o item depois (`NEW_IMAGE`), o item antes (`OLD_IMAGE`) ou os dois (`NEW_AND_OLD_IMAGES`). Escolhemos os dois para detectar a transição de `em_rota` para `entregue`.

É o *transactional outbox* do capítulo 5 entregue pelo banco: a gravação e o registro no Stream acontecem juntos. A Lambda lê o Stream por um *event source mapping*, um processo do serviço Lambda que junta registros em lotes e chama a função, e essas leituras não são cobradas.

Crie `backend/lambdas/rango_lambda/entrega_concluida.py`:

```python
from banco import conexao


def handler(event, context):
    with conexao().cursor() as cur:
        for registro in event["Records"]:
            pedido_id = registro["dynamodb"]["Keys"]["pk"]["S"].removeprefix("PEDIDO#")
            cur.execute(
                "UPDATE pedidos SET status = 'entregue' WHERE id = %s AND status = 'pago'",
                (pedido_id,),
            )
    return {"processados": len(event["Records"])}
```

O registro chega no formato bruto do DynamoDB, com o tipo de cada valor explícito (`{"S": "PEDIDO#..."}`, onde `S` quer dizer string). O `UPDATE` com `AND status = 'pago'` é idempotente: o Stream entrega cada registro pelo menos uma vez, e uma reentrega não faz nada.

Na stack, a função usa o auxiliar `funcao` do capítulo 19, que já cuida da layer, da VPC e do segredo do banco:

```python
        entrega_concluida = funcao(
            "EntregaConcluida",
            "entrega-concluida",
            "entrega_concluida.handler",
            memory_size=256,
            timeout=Duration.seconds(30),
        )
        entrega_concluida.add_event_source(
            fontes.DynamoEventSource(
                tabela_entregas,
                starting_position=lambda_.StartingPosition.LATEST,
                batch_size=25,
                retry_attempts=5,
                bisect_batch_on_error=True,
                filters=[
                    lambda_.FilterCriteria.filter(
                        {
                            "eventName": lambda_.FilterRule.is_equal("MODIFY"),
                            "dynamodb": {
                                "OldImage": {"status": {"S": lambda_.FilterRule.is_equal("em_rota")}},
                                "NewImage": {"status": {"S": lambda_.FilterRule.is_equal("entregue")}},
                            },
                        }
                    )
                ],
            )
        )
```

O filtro economiza dinheiro. Sem ele, a função seria chamada 40 vezes por segundo para ignorar posições. Com ele, o event source mapping descarta antes de chamar, e só a transição `em_rota` → `entregue` passa.

O `bisect_batch_on_error` divide o lote ao meio quando a função falha, para isolar o registro problemático. Depois da quinta tentativa, o registro é descartado em silêncio, porque não há destino para falhas. Guarde esse detalhe para a ponte. O `DynamoEventSource` dá à role a permissão de ler o Stream, e o `sg_lambdas` do capítulo 19 já alcança o banco.

### O deploy e o primeiro trajeto

Reative os workflows, faça o commit de `backend/` e `rango-infra/` e envie para a `main`:

```bash
gh workflow enable ci.yaml
gh workflow enable renovar-tasks.yaml
```

Depois da sua aprovação no environment `producao`, o pipeline publica a imagem nova da API e o `cdk deploy` cria a tabela, o endpoint e a função. Repita os passos do webhook do capítulo 19 para ter um pedido pago em `$PEDIDO`. Agora faça o papel do entregador:

```bash
API=https://api.rango.com.br

curl -s -X POST "$API/entregas/$PEDIDO/iniciar" \
  -H "Content-Type: application/json" -d '{"entregador": "joao-p"}'

agora_ms() { echo $(( $(date +%s) * 1000 )); }
for ponto in "-8.0631 -34.8711" "-8.0612 -34.8730" "-8.0598 -34.8752"; do
  set -- $ponto
  curl -s -X POST "$API/entregas/$PEDIDO/posicao" \
    -H "Content-Type: application/json" \
    -d "{\"lat\": $1, \"lon\": $2, \"registrada_em\": $(agora_ms)}"
  sleep 2
done
```

Para o papel do restaurante, cadastre uma usuária no painel. O hash é gerado no seu terminal (com `pip install argon2-cffi`), e a senha não aparece no histórico do shell:

```bash
HASH=$(python3 -c "import getpass; from argon2 import PasswordHasher; print(PasswordHasher().hash(getpass.getpass()))")
PAINEL=$(aws dynamodb list-tables \
  --query "TableNames[?contains(@, 'TabelaPainel')] | [0]" --output text)
aws dynamodb put-item --table-name "$PAINEL" --item \
  "{\"pk\":{\"S\":\"USUARIO#ana@cantinadanona.com.br\"},\"restaurante\":{\"S\":\"cantina-da-nona\"},\"hash_senha\":{\"S\":\"$HASH\"}}"

read -rs -p "Senha: " SENHA; echo
TOKEN=$(jq -n --arg s "$SENHA" '{email: "ana@cantinadanona.com.br", senha: $s}' \
  | curl -s -X POST "$API/painel/entrar" -H "Content-Type: application/json" -d @- | jq -r .token)
unset SENHA
```

E os papéis do cliente e do restaurante:

```bash
curl -s "$API/entregas/$PEDIDO" | jq .
curl -s "$API/entregas/$PEDIDO/trajeto" | jq -c .
curl -s "$API/restaurantes/cantina-da-nona/entregas" -H "Authorization: Bearer $TOKEN" | jq -c .
```

```json
{
  "status": "em_rota",
  "entregador": "joao-p",
  "posicao": {"lat": -8.0598, "lon": -34.8752},
  "registrada_em": 1792094465000
}
```

```text
[{"lat":-8.0631,"lon":-34.8711},{"lat":-8.0612,"lon":-34.873},{"lat":-8.0598,"lon":-34.8752}]
[{"pedido_id":"5f0d2c1a-9e3b-4b7f-8a61-0c4e2d9b7a35","entregador":"joao-p","posicao":{"lat":-8.0598,"lon":-34.8752}}]
```

Agora o teste do capítulo 5: mande uma posição com um instante anterior ao da última.

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$API/entregas/$PEDIDO/posicao" \
  -H "Content-Type: application/json" \
  -d '{"lat": -8.1000, "lon": -34.9000, "registrada_em": 1000000000000}'
curl -s "$API/entregas/$PEDIDO" | jq -c .posicao
```

```text
204
{"lat":-8.0598,"lon":-34.8752}
```

A posição atrasada foi recusada pela condição, e o mapa não pulou. Conclua a entrega e confira o Postgres pela API de pedidos:

```bash
curl -s -X POST "$API/entregas/$PEDIDO/concluir" | jq -c .
sleep 5
curl -s "$API/pedidos/$PEDIDO" | jq .status
curl -s "$API/restaurantes/cantina-da-nona/entregas" -H "Authorization: Bearer $TOKEN"
```

```text
{"pedido_id":"5f0d2c1a-9e3b-4b7f-8a61-0c4e2d9b7a35","status":"entregue"}
"entregue"
[]
```

O Stream levou a mudança até a Lambda, que atualizou o Postgres. E a entrega saiu do índice do restaurante, porque perdeu o atributo `restaurante`. Chame o `concluir` de novo e você recebe 409; a Lambda não é chamada, porque o filtro só aceita a transição a partir de `em_rota`.

### Olhando a tabela pela CLI

A CLI mostra quanto cada operação custa, o que ajuda a fixar o modelo. Pegue o nome da tabela e faça a `Query` do trajeto, pedindo o consumo:

```bash
TABELA=$(aws dynamodb list-tables \
  --query "TableNames[?contains(@, 'TabelaEntregas')] | [0]" --output text)

aws dynamodb query --table-name "$TABELA" \
  --key-condition-expression "pk = :pk AND begins_with(sk, :pos)" \
  --expression-attribute-values "{\":pk\": {\"S\": \"PEDIDO#$PEDIDO\"}, \":pos\": {\"S\": \"POS#\"}}" \
  --return-consumed-capacity TOTAL \
  --query "{itens: Count, consumo: ConsumedCapacity.CapacityUnits}"
```

```json
{
    "itens": 3,
    "consumo": 0.5
}
```

Três itens pequenos cabem em 4 KB, então a leitura eventualmente consistente custou meia unidade. Agora o jeito errado de responder a pergunta do restaurante, com `Scan` e filtro:

```bash
aws dynamodb scan --table-name "$TABELA" \
  --filter-expression "restaurante = :r" \
  --expression-attribute-values '{":r": {"S": "cantina-da-nona"}}' \
  --return-consumed-capacity TOTAL \
  --query "{itens: Count, lidos: ScannedCount, consumo: ConsumedCapacity.CapacityUnits}"
```

Compare `Count` (itens devolvidos) com `ScannedCount` (itens lidos e cobrados). Numa noite de jantar, o `ScannedCount` seria 576 mil para devolver uma dúzia, que é o que a `Query` no índice esparso lê.

### Quanto isso custa

Com os preços de referência de outubro de 2026 em us-east-1 (aproximados; confira a página oficial), e assumindo 200 entregadores durante quatro horas por dia, todo dia:

| Item | Conta | Por mês |
|------|-------|---------|
| Posições recebidas | 40/s × 14.400 s × 30 dias | 17,3 milhões |
| Escritas | 3 por posição (`ATUAL`, índice, histórico) = 51,8 milhões de unidades × US$ 0,625/milhão | ~US$ 32 |
| Leituras do cliente | 17,3 milhões × 0,5 unidade × US$ 0,125/milhão | ~US$ 1 |
| Armazenamento | < 1 GB, graças ao TTL | dentro dos 25 GB gratuitos |
| Lambda e Stream | algumas centenas de entregas por dia | centavos |

Uns US$ 33 por mês, quase tudo em escritas, um terço delas no índice. Para baixar, grave o histórico a cada três posições ou projete só as chaves no índice.

### Desmontando

```bash
cd rango-infra
cdk destroy RangoProducao
gh workflow disable ci.yaml
gh workflow disable renovar-tasks.yaml
```

As duas tabelas vão embora com o `DESTROY`, junto com o índice, o Stream e a usuária do painel, que você cadastra de novo quando recriar a stack. O banco deixa um snapshot novo, como sempre.

## Quando não usar o DynamoDB

Depois da API respondendo em milissegundos, aparece a tentação de mover os pedidos para lá também. Resista.

O resumo de vendas do capítulo 19 é um `GROUP BY restaurante` com `sum` e `avg`. No DynamoDB, ele vira um `Scan` com agregação em Python, ou uma tabela de totais mantida por um Stream. Relatórios e perguntas que o Bruno ainda não fez pedem SQL.

Padrões de acesso mudam. No Postgres, uma pergunta nova é um `CREATE INDEX`; no DynamoDB, pode ser um GSI ou um backfill em milhões de itens.

Relações e restrições também. Chave estrangeira, `UNIQUE` fora da chave, `CHECK` e cascata viram código seu. Existem transações (`TransactWriteItems`), que custam o dobro e têm limite de itens; para pedido com cobrança, cupom e estoque, o Postgres faz melhor.

O DynamoDB brilha com acesso sempre por chave, padrões conhecidos, escritas em volume alto ou imprevisível e vontade de zero operação: sessões, carrinhos, rastreamento, contadores, chaves de idempotência. O Rangô agora usa os dois bancos, cada um onde é bom.

## Armadilhas e casos reais

> **Armadilha:** Partition key com pouca variedade. Com `pk = "2026-10-15"`, todas as escritas do dia caem numa partição, que aguenta cerca de 1.000 unidades de escrita por segundo. Com 5.000 entregadores, vem throttling mesmo em on-demand, com a tabela longe da cota. Acrescente um sufixo (`2026-10-15#7`) e leia os sufixos em paralelo.

> **Armadilha:** Esquecer a paginação. `Query` e `Scan` devolvem páginas limitadas por tamanho, com `LastEvaluatedKey` quando há mais. O `entregas_do_restaurante` assume que cabe numa página, o que vale para o Rangô; em consultas que crescem, use os paginators do boto3.

> **Armadilha:** O Stream de uma tabela comum aceita no máximo dois leitores simultâneos por shard (em global tables, um). A terceira Lambda pendurada nele sofre throttling. Para muitos consumidores, um leitor publica num barramento de eventos, assunto do próximo capítulo.

> **Na vida real:** Em 20 de setembro de 2015, o DynamoDB de us-east-1 passou horas com erros que chegaram a cerca de 55% das requisições. Os servidores de armazenamento consultam um serviço interno de metadados para saber de quais partições cuidam, e a adoção rápida de GSIs tinha inchado essas respostas até perto do limite de tempo. Uma falha breve de rede fez muitos servidores perguntarem ao mesmo tempo, e as retentativas mantiveram o serviço sobrecarregado. É a tempestade de retentativas do capítulo 5 dentro da própria AWS. "Gerenciado" quer dizer que outra equipe cuida da operação; a falha continua possível.

## Resumo

- O DynamoDB é um banco chave-valor gerenciado, acessado por HTTPS com IAM, sem conexão persistente: combina com Lambda e com cargas de muitas escritas pequenas.
- A partition key escolhe a partição pelo hash e precisa espalhar o tráfego (teto de cerca de 3.000 leituras e 1.000 escritas por segundo por partição). A sort key ordena os itens dentro da item collection.
- O desenho começa pelos padrões de acesso. Single-table design guarda junto o que é lido junto, com chaves como `PEDIDO#id` e `POS#instante`.
- GSI responde perguntas com outra chave; índice esparso indexa só os itens que têm o atributo da chave. Escritas no índice são cobradas à parte.
- On-demand cobra por requisição e é o ponto de partida; provisionado reserva capacidade e compensa com tráfego estável e conhecido.
- Condition expressions fazem checagem e escrita atômicas, e resolveram a posição fora de ordem.
- TTL apaga sem custo de escrita, em até alguns dias; filtre os expirados na leitura.
- Streams registram cada alteração por 24 horas; com Lambda e filtro, viram um outbox pronto.
- O Rangô usa Postgres para pedidos e relatórios e DynamoDB para o rastreamento e as sessões do painel, com gateway endpoint gratuito na VPC.

## O pedido que ninguém enxerga inteiro

Olhe o caminho que um pedido do Rangô percorre hoje. O `POST /pedidos` grava no Postgres e chama o gateway de pagamento, esperando a resposta. Um stream no Valkey, inventado no capítulo 5, avisa o restaurante e manda o e-mail, com mensagens pendentes presas ao nome de tarefas que já não existem. O webhook do PIX chega por uma Lambda. A conclusão da entrega chega por outra, pelo Stream do DynamoDB, e se ela falhar cinco vezes o registro some sem deixar rastro.

Cada peça funciona, e ninguém enxerga o pedido de ponta a ponta. Se o restaurante recusar um pedido já pago, quem devolve o dinheiro? Se o e-mail falhar, quem tenta de novo, e quando alguém fica sabendo? O Bruno já pediu um SMS para o cliente quando o entregador sair, e isso seria mais uma chamada pendurada no meio da cadeia.

O próximo capítulo troca essa cadeia por mensagens e eventos de verdade: Amazon SQS com dead letter queue e visibility timeout, Amazon SNS para avisar vários interessados de uma vez, Amazon EventBridge como barramento e agendador com fuso horário, e AWS Step Functions para desenhar o fluxo do pedido como uma máquina de estados que mostra, a qualquer momento, em que passo cada pedido está.

## Referências

- Amazon DynamoDB, Developer Guide: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html
- Partições e chaves de partição, burst e adaptive capacity: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/burst-adaptive-capacity.html
- Cotas do DynamoDB (tabelas, índices, throughput, Streams): https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ServiceQuotas.html
- Time to Live: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html
- TTL e Streams, filtro para exclusões do serviço: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/time-to-live-ttl-streams.html
- DynamoDB Streams: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Streams.html
- StreamSpecification no CloudFormation: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-dynamodb-table-streamspecification.html
- Preços on-demand: https://aws.amazon.com/dynamodb/pricing/on-demand/
- Redução de preços do on-demand e das global tables (nov/2024): https://aws.amazon.com/about-aws/whats-new/2024/11/amazon-dynamo-db-reduces-prices-on-demand-throughput-global-tables
- Blog da AWS sobre a redução de preços: https://aws.amazon.com/blogs/database/new-amazon-dynamodb-lowers-pricing-for-on-demand-throughput-and-global-tables/
- Chaves compostas de vários atributos em GSIs (nov/2025): https://aws.amazon.com/about-aws/whats-new/2025/11/amazon-dynamodb-multi-attribute-composite-keys-global-secondary-indexes
- Palavras reservadas do DynamoDB: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ReservedWords.html
- Filtros de eventos da Lambda: https://docs.aws.amazon.com/lambda/latest/dg/invocation-eventfiltering.html
- Resumo do incidente do DynamoDB em us-east-1 (20/set/2015): https://aws.amazon.com/message/5467D2/
