# Filas, eventos e sistemas distribuídos

No capítulo anterior, o Rangô aprendeu a crescer para os lados, como todo mundo depois das festas de fim de ano. A API ficou stateless, os carrinhos foram para o Redis, a lista de restaurantes ganhou cache, e o Nginx passou a distribuir as requisições entre várias instâncias, desviando das que caem. Ficou um aviso no fim: nenhuma quantidade de réplicas resolve uma rota que passa a maior parte do tempo esperando outro sistema responder. E ficou uma promessa: explicar por que um `POST /pedidos` que falha no meio não pode simplesmente ser repetido. Quem já apertou F5 numa tela de pagamento conhece o frio na barriga que essa frase provoca.

## Vinte e cinco segundos para dizer "recebido"

Vamos voltar àquela quinta-feira, às 21h22. Seis instâncias, CPU em 45%, cache funcionando. E o botão "Confirmar pedido" girando sem parar. O círculo que gira é o jeito mais educado que a computação inventou para dizer "não faço a menor ideia de quando isso termina".

A conta do que a rota `POST /pedidos` fazia é simples. Cobrar o cartão no gateway de pagamento levava 2,5 segundos. Avisar o restaurante pela API dele, mais 2 segundos. Enviar o e-mail de confirmação, mais 1 segundo. Em uma noite normal, o cliente esperava 5,5 segundos olhando o botão girar, o que já é ruim. Naquela noite, o provedor de e-mail passou a responder em 20 segundos, e cada confirmação passou a levar 24,5 segundos.

Lembra da conta de capacidade do capítulo 4? Um processo que atende uma requisição em 80 ms aguenta cerca de 12 requisições por segundo. Uma rota síncrona do FastAPI (declarada com `def`) roda num pool de 40 threads por processo, e cada pedido ocupa uma thread durante 24,5 segundos. Com seis instâncias, bastaram pouco mais de 240 pedidos simultâneos para ocupar todas as threads. A partir daí, a listagem de restaurantes, que responde em milissegundos e não tem nada a ver com e-mail, ficou na fila atrás dos pedidos. O Rangô inteiro parou por causa de um serviço que só manda uma mensagem de "obrigado pela compra". Foi o agradecimento mais caro da história da empresa.

E veio o segundo problema. Depois de 15 segundos olhando o botão girar, alguns clientes clicaram de novo. A segunda requisição foi para outra instância, que cobrou o cartão outra vez. Na sexta de manhã, a sua sócia tinha 37 pedidos de reembolso no e-mail. Nenhum daqueles clientes tinha pedido duas lasanhas. O extrato do cartão discordava.

Nenhuma das duas falhas tem a ver com capacidade de processamento. A rota amarra o tempo de resposta ao pior tempo de três sistemas que você não controla, e ela não sabe distinguir um pedido novo de um pedido repetido.

## O que a API precisa esperar?

Pense em como funciona um restaurante de verdade. O garçom anota o pedido, leva a comanda até a cozinha, prende no trilho e volta para o salão. Ele não fica parado ao lado do fogão esperando a lasanha ficar pronta para só então atender a próxima mesa. Se ficasse, o restaurante atenderia uma mesa por hora e teria o garçom mais bem informado sobre lasanhas do país. A cozinha trabalha no ritmo dela, e o garçom continua atendendo.

Essa é a diferença entre comunicação **síncrona** e **assíncrona**. Na síncrona, quem chama espera a resposta para continuar, como uma chamada de função comum em Python. Na assíncrona, quem chama entrega o trabalho para alguém e segue em frente; o resultado chega depois, por outro caminho.

Cuidado com uma confusão comum aqui. O `async def` do FastAPI resolve outro problema. Ele permite que um processo atenda outras requisições enquanto espera a rede, mas o cliente daquela requisição continua esperando os 24,5 segundos. Ele só espera de um jeito mais elegante, como quem aguarda o ônibus lendo um livro: o ônibus não chega mais cedo por isso. O que buscamos é tirar o trabalho de dentro da requisição.

A pergunta certa para cada etapa do pedido é: o cliente precisa do resultado disto para receber a resposta?

- **Pagamento:** sim, em boa parte dos casos. Se o cartão for recusado, o cliente precisa saber agora, enquanto ainda está na tela, para tentar outro cartão.
- **Avisar o restaurante:** não. O cliente precisa saber que o pedido foi registrado. Se o restaurante vai receber o aviso em 200 milissegundos ou em 4 segundos, tanto faz para quem está na tela.
- **E-mail de confirmação:** não. Um e-mail que chega 30 segundos depois ninguém percebe. Um botão que gira 30 segundos todo mundo percebe.

Com essa divisão, a rota cobra o cartão, registra o pedido, deixa um recado dizendo "o pedido 8f3a... foi criado" e responde. O resto acontece depois. O tempo de resposta cai de 24,5 para cerca de 2,5 segundos, e o atraso do provedor de e-mail deixa de afetar a API. O provedor continua lento, só que agora lento no tempo dele, sem plateia.

> **Dica:** o pagamento também pode sair da requisição, com a tela mostrando "aguardando pagamento" até a confirmação chegar. Fica mais complexo, e o capítulo 21 mostra como orquestrar isso na AWS.

## Filas: a comanda presa no trilho

O "recado" precisa ficar em algum lugar. Esse lugar é uma **fila de mensagens**: um serviço que recebe mensagens de quem produz trabalho e as guarda até que alguém as retire para processar.

O vocabulário é curto. Quem coloca a mensagem na fila é o **produtor** (a API do Rangô). Quem retira e processa é o **consumidor**, também chamado de *worker* (um processo separado que manda e-mails). O serviço que guarda as mensagens no meio é o *broker*. Os mais conhecidos são RabbitMQ, Apache Kafka e o próprio Redis, que você já tem rodando. O Kafka ganhou o nome do escritor Franz Kafka porque, segundo Jay Kreps, um dos criadores, era um sistema otimizado para escrita e ele gostava do autor. Quem já configurou um cluster de Kafka desconfia que a homenagem foi ao clima kafkiano da configuração. Na AWS, o equivalente gerenciado é o Amazon SQS, assunto do capítulo 21.

A fila traz três benefícios que valem a pena separar.

O primeiro é o **desacoplamento no tempo**. O produtor e o consumidor não precisam estar no ar ao mesmo tempo. Se o worker de e-mail cair por 10 minutos, a API continua aceitando pedidos; as mensagens se acumulam e são processadas quando ele voltar. Na versão síncrona, 10 minutos de e-mail fora do ar eram 10 minutos sem pedidos.

O segundo é a **absorção de picos**. Se a TV gera 300 pedidos por minuto e o provedor de e-mail aguenta 100, a fila cresce durante o pico e esvazia depois, como uma caixa d'água. Os e-mails só chegam alguns minutos mais tarde, e ninguém na história abriu um e-mail de confirmação de pedido com pressa.

O terceiro é a **escala independente**. Se a fila de e-mails não para de crescer, você sobe mais workers de e-mail, sem tocar na API. Vários workers lendo a mesma fila disputam as mensagens, e cada mensagem vai para um só deles. Esse arranjo tem nome: *competing consumers*, consumidores concorrentes. Funciona como os cozinheiros pegando a próxima comanda do trilho.

Em troca, você ganha uma peça a mais para operar. A métrica que importa passa a ser a idade da mensagem mais antiga: 5 mil mensagens processadas em um minuto indicam saúde, 20 mensagens paradas há duas horas indicam um worker morto. Em sistemas distribuídos, ninguém morre de forma dramática: o processo só para de responder, como um colega em reunião com a câmera desligada.

## Pub/sub: um evento, vários interessados

Até aqui, a API manda um recado para o worker de e-mail. Mas o restaurante também precisa saber do pedido. Daqui a alguns meses, o time de dados vai querer contar pedidos por bairro (o time de dados sempre quer contar alguma coisa por bairro), e alguém vai querer dar pontos de fidelidade. A API vai ter que conhecer cada uma dessas filas e escrever em todas?

Existe uma forma mais elegante de pensar nisso. Em vez de mandar **comandos** ("envie este e-mail", "avise este restaurante"), a API publica um **evento**: um fato que aconteceu, com nome no passado. `pedido.criado`. Ela não sabe quem vai se interessar, e nem precisa saber. É a fofoca na sua forma mais pura: alguém conta o fato, e quem quiser que faça alguma coisa com ele.

Esse modelo se chama **publish/subscribe**, ou *pub/sub*. O publicador envia o evento para um tópico, e cada assinante recebe a sua própria cópia. É o mesmo princípio dos eventos do navegador que você usa no React: o botão dispara `click`, e quem registrou um listener reage. O botão não conhece os listeners.

A diferença para a fila simples está em quem recebe cada mensagem:

| | Fila | Pub/sub |
|---|---|---|
| Quem recebe cada mensagem | Um único consumidor | Todos os assinantes, cada um com sua cópia |
| Uso típico | Distribuir trabalho | Avisar que algo aconteceu |
| Analogia | Comanda no trilho da cozinha | Aviso no grupo da família |

Na prática, os dois se combinam. O evento `pedido.criado` é entregue a dois grupos de assinantes, "restaurante" e "e-mail", e dentro de cada grupo pode haver vários workers disputando as mensagens. Esse arranjo de um evento para vários destinos é chamado de *fan-out*. Na AWS, ele aparece como SNS publicando em várias filas SQS, ou como regras do Amazon EventBridge, ambos no capítulo 21. Na parte prática deste capítulo, o Rangô monta exatamente isso com Redis Streams.

Um evento bem desenhado carrega dados suficientes para os assinantes trabalharem sem voltar à API, incluindo o ID do pedido, que vai ser importante daqui a pouco.

## Pelo menos uma vez

Agora vem a parte em que sistemas distribuídos começam a ficar estranhos. Leslie Lamport já tinha avisado, numa definição famosa: um sistema distribuído é aquele em que a falha de um computador que você nem sabia que existia pode deixar o seu próprio computador inutilizável.

Um worker retira a mensagem da fila, envia o e-mail e avisa o broker: "pronto, pode apagar". Esse aviso se chama **confirmação**, ou *ack* (de *acknowledgement*). Enquanto o ack não chega, o broker mantém a mensagem guardada. Se o worker morrer antes de confirmar, o broker entrega a mensagem de novo, para ele mesmo quando voltar ou para outro worker.

Agora acompanhe o pior momento possível. O worker envia o e-mail com sucesso. Um milissegundo depois, antes de mandar o ack, o container é reiniciado por um deploy. Para o broker, a mensagem nunca foi processada. Ele a entrega de novo, e o cliente recebe dois e-mails. Ele não reclama; no máximo, conclui que o Rangô gosta muito dele.

Você poderia inverter a ordem: confirmar primeiro, processar depois. Aí o problema se inverte. Se o worker morrer entre o ack e o envio, a mensagem some e o e-mail nunca sai.

Não existe uma terceira ordem. Entre o efeito no mundo externo e o aviso ao broker sempre há um intervalo, e uma falha pode cair nele. Você precisa escolher qual erro prefere:

- **No máximo uma vez** (*at-most-once*): confirma antes de processar. Nunca duplica, às vezes perde.
- **Pelo menos uma vez** (*at-least-once*): confirma depois de processar. Nunca perde, às vezes duplica.

Para pedidos de comida, perder o aviso ao restaurante significa um cliente com fome esperando uma lasanha que ninguém vai preparar. Quase todo sistema escolhe **pelo menos uma vez**, e quase todos os brokers trabalham assim por padrão, incluindo o SQS.

Existe uma piada clássica entre quem trabalha com isso: "Os dois problemas mais difíceis em sistemas distribuídos são: 2. entregar a mensagem exatamente uma vez; 1. garantir a ordem das mensagens; 2. entregar a mensagem exatamente uma vez." Quem ri de nervoso já passou por isso.

> **Armadilha:** algumas ferramentas anunciam entrega "exatamente uma vez" (*exactly-once*). Leia as letras miúdas. Em geral, a garantia vale dentro do próprio sistema (o Kafka, por exemplo, consegue isso entre tópicos dele mesmo) ou dentro de uma janela de deduplicação limitada. No instante em que o worker manda um e-mail ou chama a API de um restaurante, a garantia acaba. O efeito "exatamente uma vez" no mundo real é algo que o seu código constrói.

E como o seu código constrói isso? Com idempotência.

## Idempotência: repetir sem estragar

Uma operação é **idempotente** quando executá-la duas vezes tem o mesmo efeito que executá-la uma vez. `pedido.status = "pago"` é idempotente: rodar de novo não muda nada. Já `saldo -= 58.90` tira mais dinheiro a cada execução. É a operação favorita do banco e a menos favorita do cliente.

Você já conhece isso do HTTP. `GET`, `PUT` e `DELETE` são idempotentes pela especificação; `POST` não. Foi por isso que, no capítulo 4, o Nginx reenviou as requisições `GET` para outra instância quando uma caiu, mas deixou o `POST /pedidos` falhar. Ele não tinha como saber se a instância chegou a cobrar o cartão antes de cair.

A solução clássica para tornar um `POST` seguro de repetir é a **chave de idempotência** (*idempotency key*). O cliente gera um identificador único para aquela intenção ("este pedido, desta tela") e o envia num cabeçalho. O servidor guarda a chave junto com a resposta. Se a mesma chave chegar de novo, ele devolve a resposta guardada, sem cobrar outra vez.

O detalhe que faz isso funcionar está em **quem gera a chave**. Se o servidor gerasse, cada clique viraria uma chave nova e nada mudaria. Quem gera é o React, uma única vez quando a tela de confirmação abre. O cliente pode clicar dez vezes (e vai, porque todo usuário acredita que clicar com mais força faz a internet andar mais rápido), a rede pode reenviar, o usuário pode atualizar a página no meio: todas as tentativas carregam a mesma chave.

> **Na vida real:** a API da Stripe, uma das mais usadas para pagamentos, aceita o cabeçalho `Idempotency-Key` em requisições `POST` exatamente para isso. Se uma requisição de cobrança falha por timeout, o cliente reenvia com a mesma chave, e a Stripe devolve o resultado da primeira tentativa em vez de cobrar duas vezes. Uma empresa que vive de cobrar levou muito a sério a ideia de não cobrar demais. O gateway do Rangô, nos exemplos deste capítulo, segue o mesmo modelo.

Do lado dos workers, vale o mesmo princípio. O evento chega com o ID do pedido. Antes de enviar o e-mail, o worker verifica se já existe um registro "e-mail do pedido 8f3a... enviado". Se existir, ele confirma a mensagem e segue. Assim, uma entrega repetida vira uma operação inofensiva.

Repare que a verificação reduz a janela de duplicação, sem fechá-la por completo. Se o worker enviar o e-mail e morrer antes de gravar a marca, a próxima entrega envia de novo. Para e-mail, um duplicado raro é aceitável. Para dinheiro, você empurra a idempotência até o sistema que move o dinheiro, passando a chave para o gateway, como a Stripe permite. A regra prática: a proteção mais forte fica o mais perto possível do efeito.

## Tentar de novo, mas com calma

Falhas passageiras são o normal em sistemas distribuídos. O provedor de e-mail devolve `503` por um segundo, uma conexão cai, um DNS demora. Tentar de novo resolve a maioria delas. Só que existe um jeito errado de tentar de novo, e ele já derrubou sistemas grandes.

O provedor de e-mail daquela quinta-feira falhava porque recebia mais do que aguentava. Se cada worker tentar de novo imediatamente, sem parar, a carga sobre quem já está caindo se multiplica, e ele não se recupera. Esse efeito se chama **tempestade de retentativas** (*retry storm*). É a estratégia de quem aperta F5 sem parar no site de venda de ingressos de um show disputado, só que automatizada e multiplicada por mil workers.

A primeira correção é o **backoff exponencial**: esperar cada vez mais entre as tentativas. Meio segundo, depois 1, depois 2, depois 4, com um teto (30 segundos, por exemplo). O sistema que está caindo ganha fôlego.

A segunda correção é menos óbvia. Se mil workers falharem no mesmo instante e todos usarem backoff exponencial, todos esperam exatamente 1 segundo e voltam juntos, como uma multidão empurrando a porta no mesmo segundo. A solução é o **jitter**: sortear o tempo de espera dentro do intervalo. Em vez de esperar 4 segundos, cada worker espera um valor aleatório entre 0 e 4. As tentativas se espalham. É o único lugar da computação em que um pouco de bagunça de propósito organiza tudo. É a mesma ideia do TTL com jitter que você usou no cache do capítulo 4.

```python
espera = random.uniform(0, min(teto, base * 2 ** tentativa))
```

Retentativa também precisa de limite. Sem ele, uma mensagem que nunca vai dar certo fica girando para sempre. E retentativa só é segura em operação idempotente: repetir uma cobrança sem chave de idempotência pode resolver um timeout e criar uma cobrança dupla.

> **Na vida real:** em 7 de dezembro de 2021, a região `us-east-1` da AWS teve uma interrupção de várias horas. Segundo o relatório publicado pela própria AWS, uma atividade automática de escala de um serviço provocou um comportamento inesperado em um grande número de clientes da rede interna, que geraram um pico de conexões e congestionaram os dispositivos entre a rede interna e a rede principal. O congestionamento aumentou a latência, o que provocou ainda mais tentativas de conexão e retentativas. Os clientes tinham lógica de backoff testada, mas um defeito latente impediu que ela funcionasse naquele evento. Até a AWS, que publicou o texto mais citado sobre backoff com jitter, foi atingida por retentativas que não recuaram.

## A mensagem envenenada

Algumas mensagens nunca vão dar certo. O e-mail do cliente é `ana@@exemplo.com`, e o provedor recusa. Alguém digitou com pressa, ou o arroba gaguejou. O evento foi publicado com um campo faltando por causa de um bug. Nenhuma quantidade de retentativas resolve isso.

Essa é a **mensagem envenenada** (*poison message*). O nome é dramático, mas justo: basta uma para estragar o almoço de todos os workers. Sem tratamento, ela é reentregue para sempre, consome o tempo dos workers e, em alguns brokers, bloqueia as mensagens que vêm atrás dela.

A saída é a **fila de mensagens mortas**, ou *dead letter queue* (DLQ). Depois de um número máximo de tentativas, a mensagem é movida para uma fila separada, junto com a causa do erro, e sai do caminho. A fila principal volta a andar. A DLQ funciona como a caixa de "pedidos com problema" no balcão: ninguém joga fora, alguém olha com calma depois, corrige a causa e reprocessa.

Uma DLQ só tem valor se alguém olhar para ela. Uma DLQ sem alarme é uma lixeira com nome bonito. O alarme que dispara quando ela recebe a primeira mensagem é assunto do capítulo 6 e, na AWS, do capítulo 22.

## Consistência eventual

Com o pedido assíncrono, aparece uma situação nova. O cliente recebe "pedido recebido" às 21h22min03s. O painel do restaurante mostra o pedido às 21h22min05s. Durante 2 segundos, o sistema discorda de si mesmo: para a API, o pedido existe; para o restaurante, ainda não.

É o "já estou saindo de casa" da computação: uma afirmação que vai ser verdade em algum momento, não necessariamente agora.

Isso se chama **consistência eventual**: se nada mais mudar, todas as partes acabam concordando, mas não instantaneamente. É o oposto do que você está acostumado com uma transação no Postgres, em que o `COMMIT` torna tudo visível de uma vez.

O cuidado está na interface. Se a tela seguinte busca "meus pedidos" num lugar atualizado por um worker, o pedido recém-criado pode não aparecer, e o cliente confirma de novo. Mostre o pedido a partir da resposta da própria API e deixe a atualização chegar depois.

A ordem também deixa de ser garantida: com vários workers, `pedido.cancelado` pode ser processado antes de `pedido.criado`, e o restaurante recebe o cancelamento de uma lasanha que nem sabia que existia. Eventos com número de versão permitem ao consumidor ignorar uma informação mais antiga do que a que já tem.

Por fim, a **escrita dupla**: a API grava o pedido e depois publica o evento. Se ela cair entre as duas operações, ninguém avisa o restaurante. O padrão **transactional outbox** resolve isso gravando o pedido e o evento numa tabela `outbox`, na mesma transação do banco, e deixando um processo separado publicar o que está nela. Quando os pedidos do Rangô forem para o Postgres, ele merece atenção.

## As oito falácias

Em 1994, Peter Deutsch, então na Sun Microsystems, listou suposições que todo desenvolvedor faz ao escrever o primeiro sistema distribuído, e que estão todas erradas. A lista original tinha sete; James Gosling acrescentou a oitava depois. Combina que a falácia da rede homogênea tenha vindo do criador do Java, a linguagem do slogan "escreva uma vez, rode em qualquer lugar". Ele conhecia de perto o trabalho que dava cumprir essa promessa. Elas ficaram conhecidas como **as falácias da computação distribuída**:

1. A rede é confiável.
2. A latência é zero.
3. A largura de banda é infinita.
4. A rede é segura.
5. A topologia não muda.
6. Existe um único administrador.
7. O custo de transporte é zero.
8. A rede é homogênea.

A lista tem mais de trinta anos e continua atual, o que diz pouco sobre a lista e bastante sobre nós.

A rota síncrona do Rangô acreditava nas duas primeiras: que o provedor de e-mail responderia sempre e rápido. O gateway, o provedor e a API do restaurante pertencem a empresas diferentes, cada uma com seus deploys de sexta-feira (falácia 6). E a falácia 7 vai aparecer na sua fatura no capítulo 24, como tráfego de saída.

## Na prática: o pedido sai da requisição

O exemplo reproduz a quinta-feira, separa o pedido em uma parte síncrona e uma assíncrona com Redis Streams, adiciona idempotência e mostra uma mensagem sendo reentregue e outra indo para a DLQ. As saídas aparecem todas, então dá para acompanhar a quinta-feira inteira sem precisar sofrer uma.

Pré-requisitos: o projeto como terminou o capítulo 4 (`compose.yaml` com `api`, `redis` e `proxy`, certificados do mkcert em `certs/`), Docker com Compose e o `uuidgen`, que vem no macOS e na maioria das distribuições Linux. Os comandos usam a variável `CA` do capítulo anterior:

```bash
CA="$(mkcert -CAROOT)/rootCA.pem"
```

### Etapa 1: serviços externos de mentira

O Rangô ainda não tem gateway de pagamento nem provedor de e-mail de verdade. Para os testes, entra em cena um módulo que simula os três serviços externos, com atraso e taxa de falha controlados por variáveis de ambiente. Eles têm uma vantagem enorme sobre os de verdade: falham exatamente quando alguém pede.

```python
# backend/app/externos.py
import os
import random
import time


class ServicoIndisponivel(Exception):
    pass


def _simular(nome: str, atraso_padrao: float) -> None:
    time.sleep(float(os.environ.get(f"ATRASO_{nome}", atraso_padrao)))
    if random.random() < float(os.environ.get(f"FALHA_{nome}", "0")):
        raise ServicoIndisponivel(f"{nome.lower()} respondeu 503")


def cobrar_cartao(pedido_id: str, total: float, chave: str) -> str:
    _simular("PAGAMENTO", 2.5)
    return f"cobranca-{chave[:8]}"


def avisar_restaurante(pedido: dict) -> None:
    _simular("RESTAURANTE", 2.0)
    print(f"restaurante avisado: pedido {pedido['id']}", flush=True)


def enviar_email(pedido: dict) -> None:
    _simular("EMAIL", 1.0)
    print(f"e-mail enviado: pedido {pedido['id']} para {pedido['usuario']}", flush=True)
```

Agora a versão síncrona da rota, igual à que travou na quinta-feira. No `main.py`, entra este trecho:

```python
# backend/app/main.py (versão síncrona, para reproduzir o problema)
import uuid

from app.externos import avisar_restaurante, cobrar_cartao, enviar_email


class NovoPedido(BaseModel):
    usuario: str
    restaurante: str
    total: float


@app.post("/pedidos")
def criar_pedido(novo: NovoPedido):
    pedido = {"id": str(uuid.uuid4()), **novo.model_dump()}
    cobrar_cartao(pedido["id"], novo.total, pedido["id"])
    avisar_restaurante(pedido)
    enviar_email(pedido)
    return {"id": pedido["id"], "status": "confirmado"}
```

No `compose.yaml`, a imagem da API muda para `rango-api:0.4.0` e o atraso do e-mail é repassado, com 1 segundo como padrão:

```yaml
# compose.yaml (trecho do serviço api)
  api:
    build: ./backend
    image: rango-api:0.4.0
    environment:
      CORS_ORIGINS: "https://rango.test:5173"
      REDIS_URL: "redis://redis:6379/0"
      ATRASO_EMAIL: "${ATRASO_EMAIL:-1}"
```

Com tudo de pé, a medição fica assim:

```bash
docker compose up -d --build --scale api=3
docker compose restart proxy

curl -s -o /dev/null --cacert "$CA" -w "%{http_code} em %{time_total}s\n" \
  -X POST https://api.rango.test:8443/pedidos \
  -H "Content-Type: application/json" \
  -d '{"usuario": "ana", "restaurante": "Cantina da Nona", "total": 58.9}'
```

```text
200 em 5.531s
```

Agora a quinta-feira. A API é recriada com o e-mail lento, e o mesmo `curl` é repetido:

```bash
ATRASO_EMAIL=20 docker compose up -d --scale api=3
docker compose restart proxy
```

```text
200 em 24.538s
```

Vinte e quatro segundos e meio. Nesse tempo, o cliente desiste, baixa o app do concorrente e ainda cria uma conta.

Com o e-mail lento, o teste seguinte dispara 150 pedidos em paralelo e mede a listagem de restaurantes logo em seguida:

```bash
for i in $(seq 150); do
  curl -s -o /dev/null --cacert "$CA" -X POST https://api.rango.test:8443/pedidos \
    -H "Content-Type: application/json" \
    -d '{"usuario": "ana", "restaurante": "Cantina da Nona", "total": 58.9}' &
done
sleep 1
curl -s -o /dev/null --cacert "$CA" -w "listagem em %{time_total}s\n" \
  https://api.rango.test:8443/restaurantes
```

As três instâncias rodam um processo Uvicorn cada, com 40 threads para rotas síncronas: 120 lugares para 150 pedidos. As threads ficam todas ocupadas esperando o e-mail, e a listagem, que respondia em milissegundos com o cache quente, entra na fila atrás dos pedidos e passa de 20 segundos. É a quinta-feira em miniatura.

Antes de seguir, é preciso esperar os pedidos concluírem.

### Etapa 2: o evento vai para um stream

O Redis tem uma estrutura feita para isso: o **stream**, um log de mensagens em que só se acrescenta no fim. Cada mensagem ganha um ID com o horário em milissegundos (`1760479323512-0`). Com os **grupos de consumidores** do Redis, cada grupo recebe todas as mensagens do stream (o pub/sub) e, dentro de um grupo, cada mensagem vai para um só consumidor (a fila). O Redis mantém, para cada grupo, uma lista de mensagens entregues e ainda sem ack, a *pending entries list*. É ela que garante o "pelo menos uma vez".

Os comandos que importam são poucos: `XADD` publica, `XREADGROUP` lê como membro de um grupo, `XACK` confirma. Os nomes parecem siglas de repartição pública, mas, ao contrário das repartições, fazem exatamente o que prometem.

A versão nova substitui o trecho inteiro da etapa anterior. Ela cobra o cartão, grava o pedido, publica `pedido.criado` e responde `202 Accepted`, o código HTTP para "recebi e vou processar". É o "pode deixar comigo" do protocolo, com a diferença de que, aqui, alguém vai mesmo fazer:

```python
# backend/app/main.py (pedido assíncrono e idempotente)
import json
import uuid
from typing import Annotated

from fastapi import Header, HTTPException

from app.externos import cobrar_cartao

STREAM_PEDIDOS = "eventos:pedidos"


class NovoPedido(BaseModel):
    usuario: str
    restaurante: str
    total: float


@app.post("/pedidos", status_code=202)
def criar_pedido(
    novo: NovoPedido,
    chave: Annotated[str, Header(alias="Idempotency-Key")],
):
    chave_idem = f"idem:{chave}"
    if not cache.set(chave_idem, "processando", nx=True, ex=86400):
        anterior = cache.get(chave_idem)
        if anterior == "processando":
            raise HTTPException(409, "Pedido em processamento")
        return json.loads(anterior)

    pedido = {"id": str(uuid.uuid4()), **novo.model_dump()}
    try:
        pedido["cobranca"] = cobrar_cartao(pedido["id"], novo.total, chave)
    except Exception:
        cache.delete(chave_idem)
        raise HTTPException(502, "Pagamento indisponível, tente de novo")

    cache.hset(f"pedido:{pedido['id']}", mapping={**pedido, "status": "recebido"})
    cache.xadd(STREAM_PEDIDOS, {"tipo": "pedido.criado", "dados": json.dumps(pedido)})

    resposta = {"id": pedido["id"], "status": "recebido"}
    cache.set(chave_idem, json.dumps(resposta), ex=86400)
    return resposta
```

A idempotência está nas primeiras linhas. O `SET` com `nx=True` só grava se a chave ainda não existir, e o Redis faz isso de forma atômica: se dois cliques chegarem a duas instâncias no mesmo milissegundo, só um deles consegue gravar. O outro encontra `"processando"` e recebe `409 Conflict`. Quando o pedido termina, a chave passa a guardar a resposta, e qualquer repetição nas próximas 24 horas recebe exatamente o mesmo pedido. Se o pagamento falhar, a chave é apagada, e o cliente pode tentar de novo com a mesma chave.

Note também que a chave de idempotência vai para o gateway em `cobrar_cartao`. Essa é a proteção mais perto do efeito: mesmo que tudo do lado do Rangô falhe, o gateway não cobra duas vezes a mesma chave.

> **Armadilha:** nesta demonstração, o pedido fica num hash do Redis para não precisarmos montar o Postgres agora. Como o capítulo 4 alertou, o Redis guarda tudo em memória. Pedido confirmado mora num banco com durabilidade, e o Rangô fará essa mudança no capítulo 12, com o Amazon RDS.

### Etapa 3: os workers

Cada assinante é um processo separado, usando a mesma imagem da API com outro comando. O worker fica assim:

```python
# backend/app/worker.py
import json
import os
import random
import socket
import sys
import time

import redis

from app.externos import avisar_restaurante, enviar_email

STREAM = "eventos:pedidos"
DLQ = "eventos:pedidos:dlq"
TAREFAS = {"restaurante": avisar_restaurante, "email": enviar_email}
MAX_TENTATIVAS = 5

r = redis.Redis.from_url(os.environ["REDIS_URL"], decode_responses=True)


def criar_grupo(grupo: str) -> None:
    try:
        r.xgroup_create(STREAM, grupo, id="0", mkstream=True)
    except redis.ResponseError as erro:
        if "BUSYGROUP" not in str(erro):
            raise


def com_retentativas(tarefa, pedido: dict) -> None:
    for tentativa in range(1, MAX_TENTATIVAS + 1):
        try:
            tarefa(pedido)
            return
        except Exception as erro:
            if tentativa == MAX_TENTATIVAS:
                raise
            espera = random.uniform(0, min(30, 0.5 * 2**tentativa))
            print(f"tentativa {tentativa} falhou ({erro}); nova em {espera:.1f}s", flush=True)
            time.sleep(espera)


def processar(grupo: str, msg_id: str, campos: dict) -> None:
    pedido = json.loads(campos["dados"])
    marca = f"feito:{grupo}:{pedido['id']}"
    if r.exists(marca):
        print(f"pedido {pedido['id']} já processado, ignorando", flush=True)
    else:
        try:
            com_retentativas(TAREFAS[grupo], pedido)
            r.set(marca, 1, ex=7 * 86400)
        except Exception as erro:
            r.xadd(DLQ, {**campos, "grupo": grupo, "erro": str(erro)})
            print(f"pedido {pedido['id']} foi para a DLQ: {erro}", flush=True)
    r.xack(STREAM, grupo, msg_id)


def main() -> None:
    grupo = sys.argv[1]
    consumidor = socket.gethostname()
    criar_grupo(grupo)
    print(f"worker {grupo} ({consumidor}) aguardando eventos", flush=True)
    inicio = "0"
    while True:
        resposta = r.xreadgroup(grupo, consumidor, {STREAM: inicio}, count=10, block=5000)
        mensagens = resposta[0][1] if resposta else []
        if inicio == "0" and not mensagens:
            inicio = ">"
            continue
        for msg_id, campos in mensagens:
            processar(grupo, msg_id, campos)


if __name__ == "__main__":
    main()
```

Ao iniciar, o worker lê com o ID `"0"`, que no `XREADGROUP` significa "me devolva as mensagens entregues a mim e não confirmadas", ou seja, as que ele processava quando morreu. Só depois de esvaziar essa lista ele passa para `">"`, as mensagens novas. O nome do consumidor vem do hostname do container, que se mantém quando o mesmo container é reiniciado. Antes de pegar trabalho novo, ele termina o que deixou pela metade, um hábito que muita gente com anos de carreira ainda não adquiriu.

Em `processar`, a ordem é: o trabalho, depois a marca `feito:email:<id>`, por último o `XACK`. Uma mensagem que vai para a DLQ também recebe ack, porque foi tratada, só que com outro destino.

O `compose.yaml` ganha os dois workers, com os atrasos e as falhas liberados por variável:

```yaml
# compose.yaml
services:
  api:
    build: ./backend
    image: rango-api:0.4.0
    environment:
      CORS_ORIGINS: "https://rango.test:5173"
      REDIS_URL: "redis://redis:6379/0"
    depends_on:
      - redis
    restart: unless-stopped

  worker-restaurante:
    build: ./backend
    image: rango-api:0.4.0
    command: ["python", "-m", "app.worker", "restaurante"]
    environment:
      REDIS_URL: "redis://redis:6379/0"
      ATRASO_RESTAURANTE: "${ATRASO_RESTAURANTE:-2}"
      FALHA_RESTAURANTE: "${FALHA_RESTAURANTE:-0}"
    depends_on:
      - redis
    restart: unless-stopped

  worker-email:
    build: ./backend
    image: rango-api:0.4.0
    command: ["python", "-m", "app.worker", "email"]
    environment:
      REDIS_URL: "redis://redis:6379/0"
      ATRASO_EMAIL: "${ATRASO_EMAIL:-1}"
      FALHA_EMAIL: "${FALHA_EMAIL:-0}"
    depends_on:
      - redis
    restart: unless-stopped

  redis:
    image: redis:7.4-alpine
    restart: unless-stopped

  proxy:
    image: nginx:1.27-alpine
    ports:
      - "127.0.0.1:8443:443"
    volumes:
      - ./nginx/rango.conf:/etc/nginx/conf.d/default.conf:ro
      - ./certs:/etc/nginx/certs:ro
    depends_on:
      - api
    restart: unless-stopped
```

Os três serviços apontam para a mesma imagem com `build`, para que o Compose saiba construí-la em vez de tentar baixá-la de um registry. Tudo sobe com o e-mail lento de novo, para comparar com a quinta-feira:

```bash
ATRASO_EMAIL=20 docker compose up -d --build --scale api=3
docker compose restart proxy
```

Agora, um pedido com uma chave de idempotência:

```bash
CHAVE=$(uuidgen)
curl -s --cacert "$CA" -w "\n%{http_code} em %{time_total}s\n" \
  -X POST https://api.rango.test:8443/pedidos \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $CHAVE" \
  -d '{"usuario": "ana", "restaurante": "Cantina da Nona", "total": 58.9}'
```

```text
{"id":"8f3a2c1e-5b7d-4e9a-a1c2-3d4e5f6a7b8c","status":"recebido"}
202 em 2.524s
```

De 24,5 para 2,5 segundos, com o mesmo provedor de e-mail lento. Os logs dos workers contam o resto:

```bash
docker compose logs -f worker-restaurante worker-email
```

```text
worker-restaurante-1  | restaurante avisado: pedido 8f3a2c1e-5b7d-4e9a-a1c2-3d4e5f6a7b8c
worker-email-1        | e-mail enviado: pedido 8f3a2c1e-5b7d-4e9a-a1c2-3d4e5f6a7b8c para ana
```

O restaurante foi avisado 2 segundos depois, e o e-mail saiu 20 segundos depois, sem ninguém esperando por ele. Repetindo exatamente o mesmo `curl`, com a mesma `$CHAVE`, a resposta é:

```text
{"id":"8f3a2c1e-5b7d-4e9a-a1c2-3d4e5f6a7b8c","status":"recebido"}
202 em 0.011s
```

Mesmo ID, 11 milissegundos, nenhuma cobrança nova e nenhum evento novo. Para simular o clique duplo, o exemplo gera outra chave e dispara duas requisições ao mesmo tempo:

```bash
CHAVE=$(uuidgen)
for i in 1 2; do
  curl -s --cacert "$CA" -o /dev/null -w "%{http_code}\n" \
    -X POST https://api.rango.test:8443/pedidos \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: $CHAVE" \
    -d '{"usuario": "ana", "restaurante": "Cantina da Nona", "total": 58.9}' &
done
wait
```

```text
409
202
```

Uma passou, a outra foi barrada. Se essa rota existisse naquela quinta-feira, a caixa de e-mail da sua sócia teria amanhecido bem mais tranquila.

### Etapa 4: a chave nasce no React

No navegador, a chave precisa nascer uma vez por tela de confirmação. Um componente mínimo:

```tsx
// frontend/src/ConfirmarPedido.tsx
import { useState } from "react";

const API = import.meta.env.VITE_API_URL ?? "http://localhost:8000";

type Props = { usuario: string; restaurante: string; total: number };

export function ConfirmarPedido({ usuario, restaurante, total }: Props) {
  const [chave] = useState(() => crypto.randomUUID());
  const [enviando, setEnviando] = useState(false);
  const [status, setStatus] = useState<string | null>(null);

  async function confirmar() {
    setEnviando(true);
    try {
      const resposta = await fetch(`${API}/pedidos`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Idempotency-Key": chave },
        body: JSON.stringify({ usuario, restaurante, total }),
      });
      const corpo = await resposta.json();
      setStatus(resposta.ok ? corpo.status : corpo.detail);
    } finally {
      setEnviando(false);
    }
  }

  return (
    <div>
      <button onClick={confirmar} disabled={enviando}>
        {enviando ? "Enviando..." : "Confirmar pedido"}
      </button>
      {status && <p>{status}</p>}
    </div>
  );
}
```

O `disabled` no botão ajuda, mas não cobre uma requisição repetida pela rede ou por um retry. Ele é o equivalente de interface a esconder o pote de biscoitos no alto do armário: funciona até alguém achar um banquinho. A chave no `useState` com função inicializadora é gerada uma vez e sobrevive às novas renderizações. O `crypto.randomUUID()` só existe em contextos seguros, como HTTPS ou `localhost`, e o Rangô já roda em `https://rango.test` desde o capítulo 2.

Falta um ajuste no backend. O CORS tem esse talento: some durante semanas e reaparece justo quando tudo parecia pronto. O do `main.py` ainda libera só `GET`, como ficou desde o capítulo 1, e o navegador vai barrar o `POST` na requisição de *preflight*. A linha corrigida fica assim:

```python
    allow_methods=["GET", "POST"],
```

O `allow_headers=["*"]` já cobre o cabeçalho `Idempotency-Key`.

### Etapa 5: derrubando um worker no meio do trabalho

Com o e-mail ainda em 20 segundos, o exemplo envia um pedido novo (com uma chave nova) e, logo depois, mata o worker de e-mail sem dar tempo de ele terminar:

```bash
CHAVE=$(uuidgen)
curl -s --cacert "$CA" -X POST https://api.rango.test:8443/pedidos \
  -H "Content-Type: application/json" -H "Idempotency-Key: $CHAVE" \
  -d '{"usuario": "bruno", "restaurante": "Sabor do Sertão", "total": 42.0}'
sleep 5
docker compose kill worker-email
```

O `kill` manda `SIGKILL`, o equivalente a puxar o cabo da tomada. O processo não tem direito nem a últimas palavras. O Redis, porém, anotou tudo:

```bash
docker compose exec redis redis-cli XPENDING eventos:pedidos email
```

```text
1) (integer) 1
2) "1760479401733-0"
3) "1760479401733-0"
4) 1) 1) "9b1c4d2e8f7a"
      2) "1"
```

Uma mensagem entregue ao consumidor `9b1c4d2e8f7a` (o hostname do container) e nunca confirmada. O worker volta com os comandos abaixo, e os logs mostram:

```bash
docker compose start worker-email
docker compose logs -f worker-email
```

```text
worker-email-1  | worker email (9b1c4d2e8f7a) aguardando eventos
worker-email-1  | e-mail enviado: pedido 4e7d1a9b-... para bruno
```

O worker leu primeiro a própria lista de pendentes e terminou o trabalho interrompido. Nada se perdeu. Lavoisier ficaria orgulhoso.

### Etapa 6: a mensagem que vai para a DLQ

Agora o provedor de e-mail passa a falhar sempre, com atraso curto:

```bash
ATRASO_EMAIL=0.2 FALHA_EMAIL=1 docker compose up -d --scale api=3
docker compose restart proxy
```

Depois de enviar outro pedido com uma chave nova (o mesmo `curl` da etapa anterior), os logs mostram o backoff com jitter trabalhando. O worker insiste com a paciência de quem liga para o SAC e, na quinta tentativa, desiste com dignidade:

```text
worker-email-1  | tentativa 1 falhou (email respondeu 503); nova em 0.7s
worker-email-1  | tentativa 2 falhou (email respondeu 503); nova em 1.3s
worker-email-1  | tentativa 3 falhou (email respondeu 503); nova em 0.4s
worker-email-1  | tentativa 4 falhou (email respondeu 503); nova em 6.2s
worker-email-1  | pedido c2a9e0f4-... foi para a DLQ: email respondeu 503
```

Os tempos variam a cada execução, por causa do jitter. A consulta à DLQ:

```bash
docker compose exec redis redis-cli XRANGE eventos:pedidos:dlq - +
```

A mensagem está lá, com o evento original, o grupo e o erro. O worker do restaurante, em outro grupo, avisou o restaurante normalmente.

### Limpeza

Tudo roda local. Para derrubar:

```bash
docker compose down
```

O Redis não tem volume, então o stream, a DLQ e os pedidos somem junto. É a faxina mais rápida deste livro.

## Armadilhas e casos reais

> **Armadilha:** retentativa em várias camadas. Se o React tenta 3 vezes, o Nginx tenta 3 vezes e a API tenta 3 vezes no gateway, uma única falha vira 27 chamadas ao serviço que já estava com problema. São os juros compostos, aplicados ao pior dia do seu fornecedor. Escolha uma camada para tentar de novo, normalmente a mais próxima da chamada, e faça as outras falharem rápido.

> **Armadilha:** timeout ausente. Uma chamada sem timeout pode esperar para sempre, e um worker preso para sempre é um worker a menos. A biblioteca `requests`, por exemplo, não define timeout nenhum por padrão. Ela confia na rede com o otimismo de quem nunca leu a falácia número 1. Toda chamada de rede precisa de um limite explícito, menor que o timeout de quem está esperando por você.

> **Armadilha:** worker que demora mais que o prazo do broker. No Redis Streams, uma mensagem pendente fica com o consumidor original até alguém reivindicá-la com `XAUTOCLAIM`. No SQS, a mensagem volta a ficar visível para outros workers depois de um prazo chamado *visibility timeout*. Se o processamento demorar mais que esse prazo, dois workers acabam processando a mesma mensagem ao mesmo tempo. O capítulo 21 mostra como ajustar isso.

> **Armadilha:** o stream do Rangô mora no Redis, em memória e sem persistência. Se o container for recriado, os eventos pendentes desaparecem. Serviços como o SQS gravam as mensagens em disco e replicam entre máquinas.

> **Armadilha:** chave de idempotência sem relação com o conteúdo. Se o cliente reenviar a mesma chave com outro total, o Rangô devolve a resposta antiga. Implementações mais cuidadosas guardam um hash do corpo junto com a chave e devolvem erro quando ele muda, como faz a Stripe.

> **Dica:** no SQS, a idade da mensagem mais antiga é a métrica `ApproximateAgeOfOldestMessage`, e o Rangô ganha um alarme para ela no capítulo 22.

## Resumo

- Comunicação síncrona amarra o tempo de resposta ao pior serviço da cadeia. A pergunta para cada etapa: o cliente precisa deste resultado para receber a resposta?
- Uma fila desacopla produtor e consumidor no tempo, absorve picos e permite escalar os workers de forma independente.
- Pub/sub entrega uma cópia de cada evento a cada assinante. Eventos descrevem fatos no passado (`pedido.criado`) e não conhecem quem os consome.
- Entre o efeito e o ack sempre existe uma janela. Quase todo sistema escolhe "pelo menos uma vez" e aceita duplicatas.
- Idempotência torna a repetição inofensiva: chave gerada pelo cliente, gravada com `SET NX` no servidor, repassada ao gateway, e marca de "já processado" nos workers.
- Retentativas precisam de backoff exponencial, jitter, limite e operação idempotente. Sem isso, viram tempestade.
- A DLQ tira do caminho mensagens que nunca vão dar certo, e só serve se alguém for avisado.
- Consistência eventual exige uma interface que tolere segundos de discordância e eventos fora de ordem.

## Ponte: três da manhã

Sábado, 3h07. O Rangô está mais calmo do que nunca. Os pedidos entram, a API responde em 2,5 segundos, os workers avisam restaurantes e mandam e-mails, e a DLQ está vazia.

Às 3h12, o disco da máquina onde roda o Postgres de produção apresenta defeito. O banco volta, mas a tabela de pedidos está corrompida. Às 3h40, você está acordado, de pijama, olhando o terminal. Incidentes graves têm uma preferência inexplicável pela madrugada de sábado. Alguém lembra que existe um script de backup. Ele rodava no notebook do desenvolvedor que saiu da empresa em março. O backup, como a samambaia da recepção, era responsabilidade de alguém que não trabalha mais aqui. O último arquivo `.sql` que você encontra é de três semanas atrás, e ninguém nunca testou restaurar um deles.

Quantos pedidos você aceita perder? Quanto tempo o Rangô pode ficar fora do ar enquanto você restaura? Como saber que algo quebrou antes de um cliente reclamar no Instagram? E como fazer um deploy às 18h de uma sexta sem prender a respiração? No próximo capítulo, o último da Parte I, você vai ver o que separa um sistema que funciona de um sistema pronto para produção: backups, réplicas, RPO e RTO, infraestrutura como código, pipelines de deploy e observabilidade.

## Referências

- Redis, introdução a Streams e grupos de consumidores: https://redis.io/docs/latest/develop/data-types/streams/
- Redis, comando `XREADGROUP`: https://redis.io/docs/latest/commands/xreadgroup/
- Redis, comando `XPENDING`: https://redis.io/docs/latest/commands/xpending/
- Redis, comando `XAUTOCLAIM`: https://redis.io/docs/latest/commands/xautoclaim/
- Redis, comando `SET` (opções `NX` e `EX`): https://redis.io/docs/latest/commands/set/
- FastAPI, parâmetros de cabeçalho: https://fastapi.tiangolo.com/tutorial/header-params/
- RFC 9110, métodos idempotentes: https://www.rfc-editor.org/rfc/rfc9110#section-9.2.2
- Stripe, requisições idempotentes: https://docs.stripe.com/api/idempotent_requests
- MDN, `crypto.randomUUID()`: https://developer.mozilla.org/en-US/docs/Web/API/Crypto/randomUUID
- Marc Brooker, "Exponential Backoff And Jitter", AWS Architecture Blog: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
- Amazon Builders' Library, "Timeouts, retries, and backoff with jitter": https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/
- Amazon Builders' Library, "Making retries safe with idempotent APIs": https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/
- AWS, resumo da interrupção de 7 de dezembro de 2021 em `us-east-1`: https://aws.amazon.com/message/12721/
- Chris Richardson, padrão Transactional Outbox: https://microservices.io/patterns/data/transactional-outbox.html
- Falácias da computação distribuída: https://en.wikipedia.org/wiki/Fallacies_of_distributed_computing
