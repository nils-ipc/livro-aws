# Observabilidade com CloudWatch

No capítulo anterior, o pedido do Rangô deixou de ser uma cadeia de chamadas síncronas. Uma máquina de estados do AWS Step Functions conduz cada pedido do pagamento até a saída do entregador, um tópico do SNS espalha os avisos para filas de e-mail e SMS com DLQ, e uma varredura a cada cinco minutos recupera pedidos que ficaram sem fluxo. Uma regra do EventBridge já manda e-mail quando uma execução falha. O sistema ficou mais confiável e, ao mesmo tempo, mais espalhado: são dez lugares diferentes onde alguma coisa pode dar errado sem ninguém perceber.

## Sexta, 21h10, "cadê o meu pedido?"

A mensagem chega pelo Instagram do Rangô: "Fiz o pedido às 20h29, paguei no PIX na hora, e só às 21h07 apareceu confirmado. Quarenta minutos. O que aconteceu?"

Você abre o console do Step Functions e procura a execução pelo ID do pedido. Ela existe, mas começou às 21h05. O fluxo em si levou dois minutos. O que aconteceu entre 20h29 e 21h05?

A resposta está em algum dos dez grupos de logs da stack. O da API tem um nome como `RangoProducao-LogsApp8F2D41C7-xK2pQ9mZ3aLb`, e os das Lambdas seguem o mesmo padrão. Você abre um, rola a tela, abre outro. As linhas da API são JSON, com campos `ts`, `nivel` e `msg`. As das Lambdas são texto solto de `print`. Nenhuma delas diz o ID do pedido de um jeito que dê para procurar nos dez grupos de uma vez.

Enquanto procura, você esbarra em duas coisas que não estava procurando. A DLQ de e-mail tem sete mensagens, todas de quinta de manhã. E o resumo de vendas das 11h de quinta falhou: o Bruno avisou na sexta, porque o dono da Cantina da Nona reclamou que não recebeu. Nenhum dos dois problemas gerou alerta. A regra do capítulo 21 só observa execuções do Step Functions.

O Rangô tem os dados. Os logs estão lá, e a AWS mede cada fila, cada Lambda e cada requisição no load balancer. Falta o que o capítulo 6 chamou de observabilidade: conseguir responder perguntas que você não previu, como "onde esse pedido ficou parado?", sem abrir dez abas e sem depender de um cliente reclamar.

## Um serviço, várias perguntas

O Amazon CloudWatch reúne as peças de observabilidade da AWS. Você já usou duas partes dele sem dar esse nome: o alarme de cobrança do capítulo 7 é um alarme do CloudWatch, e os logs das tasks e das Lambdas vão para o CloudWatch Logs desde os capítulos 17 e 19. Este capítulo usa o resto.

Cada pergunta da sexta tem uma ferramenta:

| Pergunta | Ferramenta |
|----------|-----------|
| O que aconteceu com o pedido 7f3c? | CloudWatch Logs e Logs Insights |
| Quantos pedidos por minuto? Qual a latência? | Métricas |
| Quem me avisa quando a DLQ recebe mensagem? | Alarmes |
| Como está o Rangô agora, numa tela só? | Dashboards |
| Por qual serviço a requisição passou, e quanto tempo em cada um? | Traces (AWS X-Ray e OpenTelemetry) |
| O Rangô está bom o suficiente para os clientes? | SLOs |

### Logs: grupos, streams e retenção

No CloudWatch Logs, cada linha é um *log event*, com horário e texto. Os eventos ficam em *log streams*, uma por origem: cada task do ECS e cada ambiente de execução da Lambda escreve na sua. As streams ficam dentro de um *log group*, a unidade onde você define retenção, permissões e criptografia. A analogia mais próxima é uma tabela de banco: o grupo é a tabela, a stream é o arquivo de onde as linhas vieram.

Você paga pela ingestão e pelo armazenamento. Em `us-east-1`, a ingestão padrão custa cerca de US$ 0,50 por GB, e o armazenamento, cerca de US$ 0,03 por GB por mês. Existe uma classe Infrequent Access, com ingestão pela metade do preço e menos recursos, boa para logs que você só consulta em incidente. O nível gratuito mensal inclui 5 GB. Os valores são aproximados, consultados em outubro de 2026; confira a página de preços do CloudWatch antes de planejar.

### Logs Insights

O CloudWatch Logs Insights consulta logs com uma linguagem própria, feita de comandos encadeados por `|`, no estilo de um pipe do terminal. Um exemplo:

```text
fields @timestamp, message
| filter level = "ERROR"
| sort @timestamp desc
| limit 20
```

O detalhe que muda tudo: quando a linha é JSON, o Logs Insights descobre os campos sozinho. Se a API escreve `{"level": "ERROR", "pedido_id": "7f3c..."}`, você filtra por `pedido_id` sem configurar nada. Ele descobre até 1.000 campos por log group. Com texto solto, você precisaria de `parse` e expressões regulares para cada formato.

Uma consulta pode cobrir até 50 log groups de uma vez e rodar por até 60 minutos. A cobrança é pelo volume escaneado, então o intervalo de tempo que você escolhe pesa mais na conta do que a complexidade da consulta.

### Métricas

Uma métrica é uma série temporal: um número por instante. Ela mora num *namespace* (`AWS/SQS`, `AWS/Lambda`, `AWS/ApplicationELB`) e é identificada pelo nome mais as *dimensões*, pares chave-valor que dizem de quem é o número. `ApproximateNumberOfMessagesVisible` com a dimensão `QueueName=rango-producao-email-dlq` é uma métrica; a mesma métrica com outra fila é outra.

Os serviços da AWS publicam as próprias métricas de graça. O load balancer publica `RequestCount`, `TargetResponseTime` e as contagens de 5xx; a Lambda, `Invocations`, `Errors`, `Duration` e `Throttles`; o SQS, o tamanho da fila e a idade da mensagem mais antiga, aquela `ApproximateAgeOfOldestMessage` prometida desde o capítulo 5; o RDS, `DatabaseConnections` e `FreeStorageSpace`.

Na hora de ler, você escolhe um *período* (um minuto, cinco minutos) e uma *estatística*: `Sum`, `Average`, `Maximum` ou um percentil como `p99`. O capítulo 6 explicou por que a média esconde os clientes que esperaram demais; aqui o p99 é só uma opção no gráfico.

Métricas suas, como "segundos entre o pagamento e a confirmação", são *custom metrics*: cerca de US$ 0,30 por métrica por mês nas primeiras 10.000, com dez gratuitas. O jeito mais simples de publicá-las a partir de uma Lambda é o *Embedded Metric Format* (EMF): você escreve no log uma linha JSON num formato combinado, e o CloudWatch extrai a métrica dela. Nenhuma chamada de API extra no caminho do pedido.

### Alarmes

Um alarme observa uma métrica e tem três estados: `OK`, `ALARM` e `INSUFFICIENT_DATA`. Você define o limite, o período e quantos períodos olhar. "Dois de três períodos acima do limite" (o *M de N*) evita que um pico isolado acorde alguém às 3h. A cada mudança de estado, o alarme pode publicar num tópico do SNS, e o Rangô já tem um, o `rango-producao-alertas`.

A configuração que mais pega gente desprevenida é o que fazer com dado ausente. Por padrão (`missing`), período sem dado conta como insuficiente, e o alarme vai para `INSUFFICIENT_DATA`. Há outras três opções: `notBreaching` trata a ausência como normal, `breaching` trata como problema, e `ignore` mantém o estado anterior. O capítulo 18 já usou `notBreaching` no alarme de 5xx, porque minuto sem erro não gera ponto na métrica. A regra prática: se a ausência quer dizer "nada aconteceu", use `notBreaching`; se quer dizer "o que devia rodar não rodou", use `breaching`.

Os dez primeiros alarmes de resolução padrão são gratuitos; depois, cerca de US$ 0,10 por alarme por mês. O alarme de cobrança do capítulo 7 já ocupa um desses dez.

### Traces e o fim do SDK do X-Ray

Logs contam o que cada peça fez. Um *trace* conta a viagem de uma requisição pelas peças, como uma linha do tempo. Cada trecho é um *span*: "API recebeu `POST /pedidos`, 180 ms", e dentro dele "INSERT no Postgres, 12 ms" e "StartExecution no Step Functions, 41 ms". Todos os spans de uma viagem compartilham um *trace ID*, que passa de serviço em serviço num cabeçalho HTTP. O padrão W3C chama esse cabeçalho de `traceparent`; o X-Ray usa o seu, `X-Amzn-Trace-Id`.

O AWS X-Ray é o serviço de traces da AWS. Durante anos, instrumentar uma aplicação para ele significava usar o SDK do X-Ray e um processo chamado X-Ray Daemon. Isso mudou: desde 25 de fevereiro de 2026, os dois estão em modo de manutenção, recebendo só correções críticas e de segurança, e o suporte termina em 25 de fevereiro de 2027. O X-Ray continua aceitando dados deles, e o console segue igual, mas a recomendação da AWS para código novo é o OpenTelemetry, seja pela distribuição da AWS (ADOT, AWS Distro for OpenTelemetry), seja pela instrumentação OpenTelemetry padrão.

Para o Rangô, isso decide a escolha: nada de SDK do X-Ray. A API usa a distribuição ADOT para Python, que instrumenta FastAPI, boto3 e outras bibliotecas sem você tocar nas rotas. Um aviso da própria AWS: as bibliotecas OpenTelemetry podem não ter todos os recursos que os SDKs do X-Ray tinham, então confira se algo de que você depende ficou para trás.

O destino dos spans também mudou. Com o *Transaction Search*, uma configuração que vale para a conta inteira, o X-Ray recebe spans no formato do OpenTelemetry e grava todos eles num log group chamado `aws/spans`. Você paga pela ingestão como log (cerca de US$ 0,35 por GB), e por padrão 1% dos spans é indexado de graça como resumo de trace, pesquisável no console. Os outros 99% continuam no log group, consultáveis pelo Logs Insights.

### SLOs

As métricas dizem o que está acontecendo. Um *SLO* (Service Level Objective) diz se isso é bom o suficiente. Ele tem duas partes: um indicador (o SLI), como "p90 do tempo até confirmar o pedido abaixo de 5 minutos", e uma meta, como "em 99% dos períodos de 5 minutos da última semana".

O que sobra da meta é o *error budget*: 1% dos períodos pode ser ruim. Uma semana tem 2.016 períodos de 5 minutos, então o Rangô pode ter cerca de 20 períodos ruins por semana, uns 100 minutos. Esse número muda a conversa com o Bruno. "Está lento" vira "a noite de sexta gastou 40% do orçamento da semana".

A velocidade com que o orçamento some é o *burn rate*. Burn rate 1 consome o orçamento exatamente no ritmo de zerar no fim da janela; acima de 1, ele acaba antes. Na sexta, com todos os períodos ruins durante quase 40 minutos, o burn rate foi 100: o orçamento de uma semana inteira duraria pouco mais de uma hora e meia naquele ritmo. Alarmes sobre burn rate avisam disso cedo e ignoram o ruído de um período ruim isolado.

O CloudWatch cria SLOs dentro do Application Signals, a parte que descobre serviços e operações e mede latência e disponibilidade. O indicador pode ser qualquer métrica do CloudWatch ou uma expressão matemática sobre métricas, o que basta para o Rangô.

## Mão na massa

O plano: dar nomes aos log groups, fazer todo mundo escrever JSON com o mesmo vocabulário, seguir um pedido pelos dez grupos, publicar uma métrica de negócio, criar alarmes e um painel, ligar os traces e definir um SLO.

Pré-requisitos: o repositório do capítulo 21, a CLI configurada com `AWS_PROFILE=rango-dev`, `jq` instalado. Como nos capítulos anteriores, encontre o snapshot deixado pelo último `cdk destroy` e coloque o nome dele no `snapshot_db` do `rango-infra/app.py`.

### Um vocabulário de log só

A Lambda tem um formato de log JSON embutido. Ligado, cada chamada ao módulo `logging` vira uma linha JSON com `timestamp`, `level`, `message`, `logger` e `requestId`, e os campos que você passa em `extra` entram no mesmo objeto. A API, então, adota as mesmas chaves. Reescreva `backend/app/logs.py`:

```python
# backend/app/logs.py
import json
import logging
import sys
from datetime import datetime, timezone

from opentelemetry import trace


class FormatoJson(logging.Formatter):
    def format(self, registro: logging.LogRecord) -> str:
        dados = {
            "timestamp": datetime.fromtimestamp(registro.created, timezone.utc).isoformat(),
            "level": registro.levelname,
            "message": registro.getMessage(),
            "logger": registro.name,
            **getattr(registro, "campos", {}),
        }
        contexto = trace.get_current_span().get_span_context()
        if contexto.is_valid:
            dados["trace_id"] = format(contexto.trace_id, "032x")
        if registro.exc_info:
            dados["erro"] = self.formatException(registro.exc_info)
        return json.dumps(dados, ensure_ascii=False, default=str)


def configurar() -> None:
    saida = logging.StreamHandler(sys.stdout)
    saida.setFormatter(FormatoJson())
    logging.basicConfig(level=logging.INFO, handlers=[saida], force=True)
```

Duas mudanças além dos nomes. O `trace_id` liga cada linha de log ao trace da requisição, assim que a instrumentação da próxima seção estiver no ar. E o `exc_info`: o formatador do capítulo 6 ignorava a exceção. O `log.exception` do `iniciar_fluxo` gravava "fluxo do pedido não iniciado" e jogava fora o traceback, que era justamente a parte útil.

No `backend/app/main.py`, o pedido passa a ter o ID num campo próprio, e a mensagem deixa de levar o ID no texto:

```python
# em criar_pedido, logo depois do INSERT:
    log.info("pedido criado", extra={"campos": {"pedido_id": str(pedido["id"])}})

# em iniciar_fluxo, no lugar do log.exception anterior:
    except Exception:
        log.exception(
            "fluxo não iniciado; a varredura tenta de novo",
            extra={"campos": {"pedido_id": pedido_id}},
        )
```

Nas Lambdas, troque os `print` por `logging`. O `confirmar_restaurante.py`, por exemplo, ganha no topo:

```python
import logging

log = logging.getLogger()
```

E, no `handler`, depois de perguntar ao restaurante:

```python
    log.info("restaurante respondeu", extra={"pedido_id": pedido_id, "aceito": aceito})
```

Faça o mesmo em `avisos.py` (`pedido_id`, `canal`, `tipo` em cada envio e em cada falha), `cancelar_pedido.py`, `guardar_token.py`, `varredura.py` (um `log.info` por pedido reenviado ao fluxo), `webhook_pagamento.py`, `entrega_concluida.py` e `resumo_vendas.py`. Com o formato JSON, a Lambda configura o logger raiz com nível `INFO`, sem `basicConfig`.

Na stack, os log groups ganham nomes legíveis, com um prefixo comum. No `rango_infra_stack.py`, logo depois da criação do cluster, onde o capítulo 17 criou o `logs_app`:

```python
        grupos_logs: list[logs.LogGroup] = []

        def grupo_de_logs(id_: str, nome: str) -> logs.LogGroup:
            grupo = logs.LogGroup(
                self,
                f"Logs{id_}",
                log_group_name=f"/rango/{ambiente}/{nome}",
                retention=logs.RetentionDays.ONE_MONTH,
                removal_policy=RemovalPolicy.DESTROY,
            )
            grupos_logs.append(grupo)
            return grupo
```

Nas duas auxiliares, `funcao` e `funcao_leve`, troque o `log_group=logs.LogGroup(...)` por estas três linhas:

```python
                log_group=grupo_de_logs(id_, f"lambda/{nome}"),
                logging_format=lambda_.LoggingFormat.JSON,
                tracing=lambda_.Tracing.ACTIVE,
```

O `tracing` fica para a seção de traces, mas já entra aqui. E o grupo da API, criado no capítulo 17, passa a usar a mesma auxiliar, logo abaixo dela:

```python
        logs_app = grupo_de_logs("App", "api")
```

O ID `LogsApp` continua o mesmo, mas o nome físico mudou, e o CloudFormation substitui o grupo. Como a stack é recriada do zero neste capítulo, isso não custa nada. Numa stack em produção, trocar o nome de um log group significa perder o histórico, que fica no grupo antigo até a retenção vencer (ou até ele ser apagado com a stack).

Faça o commit e envie para a `main`. Depois de aprovar o deploy no environment `producao`, confira:

```bash
aws logs describe-log-groups --log-group-name-prefix /rango/producao/ \
  --query 'logGroups[].logGroupName' --output text | tr '\t' '\n'
```

```text
/rango/producao/api
/rango/producao/lambda/avisos-email
/rango/producao/lambda/avisos-sms
/rango/producao/lambda/cancelar-pedido
/rango/producao/lambda/confirmar-restaurante
/rango/producao/lambda/entrega-concluida
/rango/producao/lambda/guardar-token
/rango/producao/lambda/resumo-vendas
/rango/producao/lambda/varredura-pedidos
/rango/producao/lambda/webhook-pagamento
```

### Seguir um pedido pelos dez grupos

O console do Logs Insights deixa escolher os grupos numa lista. Para o dia a dia, um script que consulta todos os grupos do prefixo poupa cliques. Crie `scripts/consultar-logs.sh`:

```bash
#!/usr/bin/env bash
# Uso: scripts/consultar-logs.sh 'consulta do Logs Insights' [minutos]
set -euo pipefail

consulta="$1"
minutos="${2:-60}"

grupos=$(aws logs describe-log-groups --log-group-name-prefix /rango/producao/ \
  --query 'logGroups[].logGroupName' --output text)
fim=$(date +%s)
inicio=$((fim - minutos * 60))

# $grupos sem aspas de propósito: cada nome vira um argumento
id=$(aws logs start-query --log-group-names $grupos \
  --start-time "$inicio" --end-time "$fim" \
  --query-string "$consulta" --query queryId --output text)

while :; do
  resultado=$(aws logs get-query-results --query-id "$id")
  status=$(jq -r .status <<<"$resultado")
  [ "$status" = "Running" ] || [ "$status" = "Scheduled" ] || break
  sleep 1
done

echo "status: $status" >&2
jq -r '.results[] | map(select(.field != "@ptr") | .value) | @tsv' <<<"$resultado"
```

Agora crie um pedido de teste com a função `criar` e o webhook do capítulo 21, guarde o ID numa variável `PEDIDO` e siga o pedido:

```bash
chmod +x scripts/consultar-logs.sh
scripts/consultar-logs.sh "fields @timestamp, @log, level, message
| filter pedido_id = '$PEDIDO'
| sort @timestamp asc" 15
```

```text
status: Complete
2026-10-16 14:02:11.482  123456789012:/rango/producao/api                           INFO  pedido criado
2026-10-16 14:02:12.903  123456789012:/rango/producao/lambda/guardar-token          INFO  token guardado
2026-10-16 14:02:19.377  123456789012:/rango/producao/lambda/webhook-pagamento      INFO  pagamento registrado
2026-10-16 14:02:20.115  123456789012:/rango/producao/lambda/confirmar-restaurante  INFO  restaurante respondeu
2026-10-16 14:02:21.640  123456789012:/rango/producao/lambda/avisos-email           INFO  aviso enviado
```

O campo `@log` mostra de qual grupo veio cada linha. É a linha do tempo que você tentou montar na sexta, abrindo abas.

Com os logs nesse formato, a investigação da sexta teria levado três minutos. A mesma consulta, para o pedido do cliente, teria mostrado isto:

```text
20:29:41.204  /rango/producao/api                         INFO   pedido criado
20:29:43.871  /rango/producao/api                         ERROR  fluxo não iniciado; a varredura tenta de novo
20:31:02.517  /rango/producao/lambda/webhook-pagamento    INFO   pagamento registrado
21:05:03.090  /rango/producao/lambda/varredura-pedidos    INFO   fluxo iniciado pela varredura
21:05:03.655  /rango/producao/lambda/guardar-token        INFO   token guardado
21:07:12.048  /rango/producao/lambda/confirmar-restaurante INFO  restaurante respondeu
```

O campo `erro` da segunda linha traria um `ConnectTimeoutError` na chamada ao Step Functions: uma falha isolada de rede, a primeira falácia do capítulo 5. Para isso a varredura existe. Ela devia ter pegado o pedido às 20h35. A pergunta seguinte é por que ela levou meia hora a mais, e uma segunda consulta responde:

```bash
scripts/consultar-logs.sh "filter level = 'ERROR'
| stats count(*) as erros by @log, bin(5m)
| sort erros desc" 60
```

Na sexta, essa consulta teria mostrado a varredura falhando a cada cinco minutos, de 20h25 a 21h00, com `OperationalError` e a mensagem do Postgres sobre não haver mais vagas de conexão. Era o pico do jantar: a API em seis tasks, o webhook com seus dez ambientes, dezenas de ambientes da `confirmar-restaurante`, cada um segurando uma conexão aberta. O ambiente da varredura foi reciclado no meio do pico, e o novo nunca conseguiu conexão. A rede de segurança do pedido ficou fora do ar exatamente quando foi necessária.

A mesma consulta, rodada sobre quinta de manhã, explica as outras duas surpresas. Das 10h50 às 11h25, o provedor de e-mail recusou envios: as sete mensagens da DLQ são desse intervalo, e o resumo das 11h ficou esperando o mesmo provedor até estourar os 60 segundos de timeout. Um defeito externo, dois sintomas, nenhum alerta.

Uma terceira consulta, só com os logs da API, dá a latência por rota, a partir do `duracao_ms` que o middleware do capítulo 6 grava:

```text
filter message = "requisicao"
| stats count(*) as req, pct(duracao_ms, 50) as p50, pct(duracao_ms, 99) as p99 by rota
| sort p99 desc
```

### Uma métrica de negócio

Logs respondem perguntas sobre um pedido. Para a pergunta "os pedidos estão demorando para confirmar?", você quer um número por minuto, com gráfico e alarme. No `confirmar_restaurante.py`, a consulta passa a trazer a idade do pedido:

```python
    pedido = conexao().execute(
        "SELECT restaurante, status, extract(epoch FROM now() - criado_em) AS segundos"
        " FROM pedidos WHERE id = %s",
        (pedido_id,),
    ).fetchone()
```

E, quando o restaurante aceita, a função escreve uma linha no Embedded Metric Format:

```python
import json
import time


def publicar_metrica(nome: str, valor: float, unidade: str) -> None:
    # Embedded Metric Format: o CloudWatch extrai a métrica desta linha de log.
    print(json.dumps({
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [{
                "Namespace": "Rango",
                "Dimensions": [["Servico"]],
                "Metrics": [{"Name": nome, "Unit": unidade}],
            }],
        },
        "Servico": "fluxo-pedido",
        nome: valor,
    }))
```

```python
    # no handler, dentro do if aceito, depois do UPDATE:
        publicar_metrica("SegundosAteConfirmar", float(pedido["segundos"]), "Seconds")
```

Aqui o `print` é deliberado. O formato JSON da Lambda embrulha as mensagens do `logging` num objeto próprio, e a linha deixaria de estar no formato que o CloudWatch reconhece; o `print` sai como está. A dimensão `Servico` tem um valor só, e isso também é deliberado, como mostra a seção de armadilhas.

### Alarmes que chegam ao seu e-mail

No `rango_infra_stack.py`, acrescente o import:

```python
from aws_cdk import (
    # ... os imports do capítulo 21 ...
    aws_cloudwatch_actions as cw_actions,
)
```

No laço das filas de aviso do capítulo 21, guarde cada DLQ numa lista. Antes do laço, `dlqs: list[sqs.Queue] = []`; dentro dele, depois de criar a `dlq`, `dlqs.append(dlq)`. Então, depois do tópico de alertas:

```python
        acao_alerta = cw_actions.SnsAction(topico_alertas)
        alarmes: list[cloudwatch.Alarm] = []

        def avisar(alarme: cloudwatch.Alarm) -> cloudwatch.Alarm:
            alarme.add_alarm_action(acao_alerta)
            alarme.add_ok_action(acao_alerta)
            alarmes.append(alarme)
            return alarme

        for fila_morta in [*dlqs, falhas_entregas]:
            avisar(
                fila_morta.metric_approximate_number_of_messages_visible(
                    period=Duration.minutes(5), statistic="Maximum"
                ).create_alarm(
                    self,
                    f"Alarme{fila_morta.node.id}",
                    alarm_description=f"Mensagens paradas na {fila_morta.node.id}",
                    threshold=0,
                    evaluation_periods=1,
                    comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
                    treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING,
                )
            )

        for fn, id_, periodos in ((resumo, "AlarmeResumo", 1), (varredura, "AlarmeVarredura", 2)):
            avisar(
                fn.metric_errors(period=Duration.minutes(5), statistic="Sum").create_alarm(
                    self,
                    id_,
                    threshold=1,
                    evaluation_periods=periodos,
                    comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
                    treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING,
                )
            )

        avisar(erros_5xx)
        avisar(
            db.metric_database_connections(
                period=Duration.minutes(1), statistic="Maximum"
            ).create_alarm(
                self,
                "AlarmeConexoesDb",
                alarm_description="Conexões perto do max_connections (~112 no db.t4g.micro)",
                threshold=90,
                evaluation_periods=5,
                datapoints_to_alarm=3,
            )
        )
        avisar(
            db.metric_free_storage_space(
                period=Duration.minutes(5), statistic="Minimum"
            ).create_alarm(
                self,
                "AlarmeDiscoDb",
                alarm_description="Menos de 2 GiB livres no disco do RDS",
                threshold=2 * 1024**3,
                evaluation_periods=3,
                comparison_operator=cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
            )
        )
```

Uma DLQ com qualquer mensagem já é motivo de alerta, e é por isso que o limite é zero. A métrica `Errors` da Lambda conta exceções e também timeouts, então o resumo de quinta teria disparado o `AlarmeResumo` às 11h01. A varredura pede dois períodos seguidos, porque uma falha isolada se resolve na rodada seguinte; dez minutos sem varredura, não. O alarme de conexões usa o M de N: três minutos de cinco acima de 90 conexões. Na sexta, ele teria disparado por volta de 20h27, antes do pedido do cliente existir. O `AlarmeDiscoDb` é o alarme de espaço livre que o capítulo 12 deixou prometido: o storage autoscaling aumenta o disco, mas só o alarme conta que algo está enchendo.

O alarme de 5xx do capítulo 18 contava erros: dez por minuto. Numa noite de pico, dez erros em 3.000 requisições são ruído; numa madrugada, três erros em cinco requisições são um problema. O capítulo 18 prometeu trocar contagens por taxas, e uma expressão matemática faz isso. Substitua o `erros_5xx` daquele capítulo, no mesmo lugar, antes do serviço que o usa:

```python
        taxa_5xx = cloudwatch.MathExpression(
            expression="100 * FILL(erros, 0) / requisicoes",
            using_metrics={
                "erros": alb.metrics.http_code_target(
                    elbv2.HttpCodeTarget.TARGET_5XX_COUNT, statistic="Sum"
                ),
                "requisicoes": alb.metrics.request_count(statistic="Sum"),
            },
            period=Duration.minutes(1),
            label="% de respostas 5xx",
        )
        erros_5xx = taxa_5xx.create_alarm(
            self,
            "ErrosApi",
            threshold=5,
            evaluation_periods=3,
            datapoints_to_alarm=2,
            comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
            treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING,
        )
```

O `FILL(erros, 0)` preenche com zero os minutos sem 5xx, que não geram ponto. Minuto sem nenhuma requisição deixa a divisão sem dado, e o `NOT_BREACHING` trata isso como normal. O ID continua `ErrosApi`, e o `deployment_alarms` do serviço continua apontando para ele: o rollback automático do blue/green passa a usar a taxa. O tópico de alertas só existe mais adiante na stack, por isso a ação entra depois, com o `avisar(erros_5xx)` do bloco anterior.

São oito alarmes, contando o `ErrosApi`. Com o de cobrança, nove dos dez gratuitos.

### Um painel para a sexta à noite

O *dashboard* junta tudo numa tela. Ainda na stack:

```python
        def confirmacao(estatistica: str) -> cloudwatch.Metric:
            return cloudwatch.Metric(
                namespace="Rango",
                metric_name="SegundosAteConfirmar",
                dimensions_map={"Servico": "fluxo-pedido"},
                statistic=estatistica,
                period=Duration.minutes(5),
            )

        painel = cloudwatch.Dashboard(
            self, "Painel", dashboard_name=f"rango-{ambiente}",
            default_interval=Duration.hours(6),
        )
        painel.add_widgets(
            cloudwatch.GraphWidget(
                title="Requisições e % de 5xx",
                left=[alb.metrics.request_count(statistic="Sum", period=Duration.minutes(1))],
                right=[taxa_5xx],
                width=12,
            ),
            cloudwatch.GraphWidget(
                title="Latência da API (segundos)",
                left=[
                    alb.metrics.target_response_time(statistic=s, period=Duration.minutes(1))
                    for s in ("p50", "p99")
                ],
                width=12,
            ),
        )
        painel.add_widgets(
            cloudwatch.GraphWidget(
                title="Segundos até confirmar o pedido",
                left=[confirmacao("p50"), confirmacao("p90")],
                left_annotations=[cloudwatch.HorizontalAnnotation(value=300, label="5 min")],
                width=12,
            ),
            cloudwatch.GraphWidget(
                title="Conexões no Postgres e fluxos com falha",
                left=[db.metric_database_connections(statistic="Maximum")],
                right=[maquina.metric_failed()],
                width=12,
            ),
        )
        painel.add_widgets(
            cloudwatch.AlarmStatusWidget(title="Alarmes", alarms=alarmes, width=8),
            cloudwatch.LogQueryWidget(
                title="Erros por grupo de logs",
                log_group_names=[g.log_group_name for g in grupos_logs],
                query_lines=[
                    "filter level = 'ERROR'",
                    "stats count(*) as erros by @log",
                    "sort erros desc",
                ],
                width=16,
            ),
        )
```

O painel fica na stack como qualquer outro recurso: quem recriar o ambiente de homologação ganha o mesmo painel, com as métricas daquele ambiente. Os três primeiros dashboards customizados são gratuitos, com até 50 métricas cada; o preço a partir do quarto está na página de preços do CloudWatch.

### Traces da API até o SNS

Primeiro, a configuração da conta. No console do CloudWatch, em Settings, procure a configuração de traces do X-Ray e ative o Transaction Search, mantendo a indexação em 1%. O console cria a resource policy que deixa o X-Ray gravar no `aws/spans`. Confira pela CLI:

```bash
aws xray get-trace-segment-destination
```

```json
{
    "Destination": "CloudWatchLogs",
    "Status": "ACTIVE"
}
```

A ativação pode levar alguns minutos até aparecer como `ACTIVE`. O `aws/spans` nasce sem retenção e fora da stack. Defina uma:

```bash
aws logs put-retention-policy --log-group-name aws/spans --retention-in-days 30
```

Agora a API. Acrescente ao `backend/requirements.txt` o pacote `aws-opentelemetry-distro` e fixe a versão que o `pip` instalar, como fez com as outras dependências. A AWS exige a versão 0.10.0 ou posterior para mandar spans direto ao X-Ray, sem coletor intermediário. No `backend/Dockerfile`, o comando passa a começar pelo `opentelemetry-instrument`, que carrega a instrumentação antes do Uvicorn:

```dockerfile
CMD ["opentelemetry-instrument", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

A configuração vai em variáveis de ambiente. Na stack, junto das variáveis que o capítulo 21 deu ao `container_api`:

```python
        for nome, valor in {
            "OTEL_PYTHON_DISTRO": "aws_distro",
            "OTEL_PYTHON_CONFIGURATOR": "aws_configurator",
            "OTEL_TRACES_EXPORTER": "otlp",
            "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/protobuf",
            "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": f"https://xray.{self.region}.amazonaws.com/v1/traces",
            "OTEL_METRICS_EXPORTER": "none",
            "OTEL_LOGS_EXPORTER": "none",
            "OTEL_RESOURCE_ATTRIBUTES": f"service.name=rango-api,deployment.environment={ambiente}",
            "OTEL_PYTHON_FASTAPI_EXCLUDED_URLS": "health",
        }.items():
            container_api.add_environment(nome, valor)

        role_app.add_managed_policy(
            iam.ManagedPolicy.from_aws_managed_policy_name("AWSXrayWriteOnlyPolicy")
        )
        vpc.add_interface_endpoint(
            "XRay", service=ec2.InterfaceVpcEndpointAwsService.XRAY, subnets=privadas
        )
```

Cada variável tem um motivo. As duas primeiras ativam a distribuição da AWS, que assina os envios com as credenciais da task role, sem chave nenhuma. Métricas e logs pelo OpenTelemetry ficam desligados, porque o Rangô já tem os dois pelo CloudWatch. A exclusão do `/health` evita um trace a cada health check do load balancer, que seriam milhares por dia sem informação nenhuma. O `service.name` é o nome com que a API aparece no mapa de serviços.

O endpoint de interface do X-Ray existe porque as tasks estão em subnets sem saída para a internet, como todo o resto desde o capítulo 15. Sem ele, os spans não saem da VPC, e o exportador registra erros de conexão em silêncio.

A amostragem fica no padrão: sem coletor, o SDK grava 100% dos traces. A AWS sugere 5% para volumes altos, com `OTEL_TRACES_SAMPLER=parentbased_traceidratio` e `OTEL_TRACES_SAMPLER_ARG=0.05`. Com 1.000 pedidos por dia, o Rangô gera pouco volume, e investigar o pedido de um cliente específico exige o trace daquele pedido.

As Lambdas já ganharam o `tracing=lambda_.Tracing.ACTIVE` lá atrás: com ele, o próprio serviço Lambda registra cada chamada, sem SDK nenhum no código. Falta o Step Functions. Na `sfn.StateMachine` do capítulo 21, acrescente:

```python
            tracing_enabled=True,
```

O CDK soma as permissões do X-Ray às roles das funções e da máquina. Faça o commit, envie, aprove o deploy e crie um pedido. Pegue o `trace_id` da linha "pedido criado":

```bash
scripts/consultar-logs.sh "filter message = 'pedido criado' | fields trace_id | sort @timestamp desc | limit 1" 10
```

O X-Ray mostra o ID no formato `1-` mais os 8 primeiros caracteres, um hífen e os 24 restantes. Um `trace_id` `6710a3c2b7e94f0d8c21a4f3e5d6c7b8` vira `1-6710a3c2-b7e94f0d8c21a4f3e5d6c7b8`. Cole na busca de traces do console do CloudWatch. A linha do tempo será parecida com esta (durações ilustrativas):

```text
rango-api        POST /pedidos .......................... 186 ms
  ├─ redis       SET idem:...                              2 ms
  ├─ postgres    INSERT pedidos                           11 ms
  └─ StepFunctions StartExecution                         43 ms
rango-producao-pedido (Step Functions)
  ├─ AguardarPagamento → Lambda guardar-token            212 ms
  ├─ ConfirmarRestaurante → Lambda confirmar-restaurante 1.304 ms
  │    └─ Initialization (cold start)                    521 ms
  └─ PublicarConfirmado → SNS Publish                     38 ms
```

O Step Functions continua o trace que chegou no cabeçalho da chamada da API, e cada Lambda aparece com a duração dela, incluindo o cold start. A passagem do SNS pelas filas até as Lambdas de aviso nem sempre continua o mesmo trace; esse último trecho, o `pedido_id` nos logs já cobre. É a combinação dos dois que leva um pedido da API até o SMS.

### Um SLO para o tempo até confirmar

A sintaxe para criar SLOs pela stack muda mais rápido que este livro, então este vai pelo console. No CloudWatch, abra Application Signals, depois Service Level Objectives, e crie um SLO:

1. Indicador: métrica do CloudWatch, `Rango` › `SegundosAteConfirmar` com `Servico=fluxo-pedido`, estatística p90.
2. Condição: menor ou igual a 300 (segundos).
3. Cálculo por períodos de 5 minutos.
4. Intervalo móvel de 7 dias, meta de 99%.
5. Nome: `rango-confirmacao-5min`.

Na mesma tela, crie um alarme de burn rate com janela de uma hora e limite 10, com ação no tópico `rango-producao-alertas`. Com burn rate 10, o orçamento da semana acaba em menos de 17 horas: dá tempo de agir antes, e um período ruim isolado não chega perto do limite. Ele é o décimo alarme da conta, o último dentro dos dez gratuitos.

O SLO não vive na stack, então sobrevive ao `cdk destroy`. Como a métrica dele vem da Lambda, ele simplesmente fica sem dados enquanto a stack não existir. Se não quiser mantê-lo, apague-o no console ao fim do capítulo.

Um segundo SLO natural para o Rangô seria a disponibilidade da API, usando como indicador a mesma expressão do `taxa_5xx`, com meta de 99,5% em períodos de um minuto. O Application Signals já calcula disponibilidade como (1 − taxa de *faults*) × 100, em que fault é resposta 5xx e 4xx conta como sucesso, mas só para serviços que ele descobre, o que exige ligá-lo na ADOT, com custo próprio.

### O teste do alarme

Simule a quinta-feira. Mude a variável `FALHA_AVISOS` da Lambda de e-mail para `1` (um drift proposital, como o `RECUSAR` do capítulo anterior), crie dois pedidos e espere. Cada mensagem é recebida cinco vezes, uma a cada dois minutos, e vai para a DLQ. Uns 15 minutos depois, chega o e-mail:

```text
ALARM: "RangoProducao-AlarmeDlqemail..." in US East (N. Virginia)
Threshold Crossed: 1 out of the last 1 datapoints [2.0 (16/10/26 14:41:00)] was greater than the threshold (0.0)
```

Volte a variável para `0`, devolva as mensagens à fila com o `start-message-move-task` do capítulo 21 e aguarde o e-mail de `OK`. O painel mostra tudo isso no mesmo intervalo: o alarme vermelho, o pico de erros no grupo `avisos-email` e a volta ao normal.

### Quanto custa enxergar

Para o Rangô com 1.000 pedidos por dia, em `us-east-1`, valores aproximados de outubro de 2026:

| Item | Custo mensal |
|------|-------------|
| Logs (cerca de 2 GB) | dentro dos 5 GB gratuitos |
| 1 custom metric (`SegundosAteConfirmar`) | ~US$ 0,30 |
| 8 alarmes + 1 de burn rate | dentro dos 10 gratuitos |
| 1 dashboard | gratuito (até 3) |
| Spans no `aws/spans` | centavos a poucos dólares |
| Endpoint de interface do X-Ray (2 AZs) | ~US$ 14,60 |

O item mais caro é o endpoint, e não a observabilidade em si. É o preço de manter as tasks sem acesso à internet, a mesma conta dos endpoints do capítulo 17. O capítulo 24 volta a ela.

Ao terminar, destrua a stack como de costume e desative os workflows:

```bash
cd rango-infra
cdk destroy RangoProducao
gh workflow disable ci.yaml
gh workflow disable renovar-tasks.yaml
```

O Transaction Search continua ativo na conta, mas só cobra quando chegam spans. O `aws/spans` fica, com a retenção de 30 dias.

## Armadilhas e casos reais

> **Armadilha:** Dimensão com valor único por pedido. Se o `publicar_metrica` usasse `pedido_id` como dimensão, cada pedido viraria uma métrica diferente. Com 1.000 pedidos por dia, seriam 30.000 métricas por mês, cobradas proporcionalmente às horas em que recebem dados, e a conta do CloudWatch passaria a ter quatro dígitos. Dimensões são para valores de poucos tipos (serviço, ambiente, rota); o ID do pedido vai no log.

> **Armadilha:** Alarme de 5xx sobre taxa com pouco tráfego. De madrugada, uma requisição com erro em duas é 50%. O `datapoints_to_alarm=2` ajuda, mas um serviço com tráfego muito baixo pode precisar de uma condição extra: só alertar se houver mais de N requisições no minuto, com uma segunda expressão.

> **Armadilha:** O que não rodou não gera erro. Se o agendamento do resumo for apagado por engano, a métrica `Errors` fica zerada para sempre, e o `AlarmeResumo` nunca dispara. Para detectar ausência, alarme sobre `Invocations` com `treat_missing_data` em `breaching`, numa janela que cubra o intervalo entre execuções.

> **Armadilha:** Média de percentis. O p99 de cada task, somado e dividido por seis, dá um número diferente do p99 do serviço. Calcule o percentil sobre a métrica agregada, como o `TargetResponseTime` do load balancer, ou com `pct()` no Logs Insights sobre todas as linhas.

> **Armadilha:** Dados pessoais no log. Um `log.info("pedido", extra={"pedido": pedido})` grava endereço, telefone e, no pior caso, dados de pagamento num lugar que muita gente da equipe lê e que fica guardado por 30 dias. Logue IDs e busque o resto no banco. O CloudWatch Logs tem políticas de proteção de dados que mascaram padrões conhecidos, mas elas são uma segunda camada, e a LGPD conta o que foi gravado.

> **Armadilha:** Consulta de 30 dias em todos os grupos. O Logs Insights cobra pelo volume escaneado. Comece pelo intervalo mais curto que responde a pergunta e aumente se precisar.

> **Na vida real:** Em 4 de janeiro de 2021, o Slack teve uma falha grave no primeiro dia útil do ano. Segundo o postmortem, no meio do incidente os serviços de dashboard e de alerta da própria empresa ficaram indisponíveis, porque dependiam da mesma rede que estava com problemas. O Rangô tem a mesma dependência: se `us-east-1` tiver um dia ruim, o CloudWatch dessa região pode sofrer junto. Para um sistema do tamanho do Rangô, a defesa razoável é um verificador externo simples, de fora da AWS, que acesse `https://api.rango.com.br/health` a cada minuto.

## Resumo

- O CloudWatch reúne logs, métricas, alarmes, dashboards, traces (com o X-Ray) e SLOs. Os serviços da AWS publicam as próprias métricas de graça.
- Logs em JSON com o mesmo vocabulário (`level`, `message`, `pedido_id`, `trace_id`) deixam o Logs Insights filtrar sem configuração, em até 50 log groups por consulta. Nomes com prefixo comum (`/rango/producao/...`) tornam a busca em todos os grupos um comando.
- Métricas de negócio saem de uma Lambda pelo Embedded Metric Format, uma linha de log. Dimensões só com valores de poucos tipos.
- Alarmes têm três estados, M de N para ignorar picos isolados e uma escolha consciente para dado ausente. Toda DLQ merece alarme com limite zero.
- Taxa de erro, calculada com expressão matemática, substitui a contagem do capítulo 18, inclusive no rollback automático.
- O SDK e o Daemon do X-Ray estão em manutenção desde fevereiro de 2026, com fim de suporte em fevereiro de 2027. O caminho agora é OpenTelemetry (ADOT) mandando spans ao X-Ray, com Transaction Search gravando tudo no `aws/spans`.
- Um SLO transforma "está lento" em orçamento de erro, e o alarme de burn rate avisa quando o orçamento está acabando rápido demais.

## Quem apagou a fila?

Segunda-feira, 8h40, você abre o painel antes do café. O gráfico de requisições tem um pico às 3h17 que não combina com o horário. A taxa de 5xx está normal, mas o Logs Insights mostra 41 mil respostas 401 em duas horas, vindas de poucos endereços IP, na `POST /painel/entrar`, o login do painel criado no capítulo 20. Alguém está testando senhas em massa.

E o gráfico da fila de SMS parou às 7h02. A fila `rango-producao-sms` não existe mais. Ninguém da equipe lembra de ter apagado nada. Os logs do Rangô contam o que a aplicação fez, mas não quem chamou a API da AWS para apagar uma fila. No próximo capítulo: AWS CloudTrail para saber quem fez o quê, GuardDuty para detectar comportamento estranho na conta, WAF na frente do CloudFront e do load balancer, e a separação em várias contas que impede um engano de virar desastre.

## Referências

- Amazon CloudWatch Logs, User Guide: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/WhatIsCloudWatchLogs.html
- Logs Insights, sintaxe de consulta: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html
- Cotas do CloudWatch Logs (campos descobertos, anomaly detectors): https://docs.aws.eu/AmazonCloudWatch/latest/logs/cloudwatch_limits_cwl.html
- Aumento de cotas do Logs Insights (50 log groups, 60 minutos), 2023: https://aws.amazon.com/about-aws/whats-new/2023/02/amazon-cloudwatch-increased-quotas-logs-insights
- Aumento de consultas concorrentes do Logs Insights, 2026: https://aws.amazon.com/about-aws/whats-new/2026/03/amazon-cloudwatch-logs-increased-limits
- Embedded Metric Format, especificação: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format_Specification.html
- Metric math: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/using-metric-math.html
- CDK, `TreatMissingData`: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_cloudwatch/TreatMissingData.html
- Avaliação de alarmes e dados ausentes (re:Post): https://www.repost.aws/articles/ARtfXuUalKQLycBz2IfuVavQ/understanding-cloudwatch-alarm-evaluation-why-alarms-delay-fire-unexpectedly-or-get-stuck
- Preços do CloudWatch: https://aws.amazon.com/cloudwatch/pricing/
- Fim do suporte aos SDKs e ao Daemon do X-Ray e migração para OpenTelemetry: https://aws.amazon.com/blogs/mt/announcing-aws-x-ray-sdks-daemon-end-of-support-and-opentelemetry-migration
- Transaction Search: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Enable-TransactionSearch.html
- Transaction Search com Lambda: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Enable-Lambda-TransactionSearch.html
- Envio sem coletor com a ADOT: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-OTLP-UsingADOT.html
- SLOs no Application Signals: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-ServiceLevelObjectives.html
- Burn rate para SLOs, anúncio de novembro de 2024: https://aws.amazon.com/about-aws/whats-new/2024/11/application-signals-burn-rate-application-performance-goals
- Google SRE Book, Service Level Objectives: https://sre.google/sre-book/service-level-objectives/
- Google SRE Workbook, alertas sobre SLOs: https://sre.google/workbook/alerting-on-slos/
- Slack, postmortem de 4 de janeiro de 2021: https://slack.engineering/slacks-outage-on-january-4th-2021/
