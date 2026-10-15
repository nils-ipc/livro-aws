# Arquitetura que escala

No capítulo anterior, o Rangô deixou de depender da sua máquina. A API virou a imagem `rango-api:0.1.1`, roda atrás de um Nginx que cuida do TLS, e o `compose.yaml` sobe os dois juntos em qualquer lugar que tenha Docker. Você também viu um orquestrador manter três réplicas vivas num cluster local. No fim, ficou uma ameaça marcada para quinta-feira: um programa de culinária vai falar do Rangô ao vivo, e um servidor só não vai dar conta.

## Quinta-feira, 21h14

Veja como seria a noite se nada mudasse.

O Rangô roda num servidor com 2 vCPUs e 4 GB de memória. Num dia comum, o pico do almoço chega a umas 5 requisições por segundo, e cada uma leva uns 80 milissegundos. A CPU passa o dia entre 10% e 15%. Ninguém pensa em infraestrutura.

Às 21h14, o apresentador prova a lasanha da Cantina da Nona e diz: "e dá para pedir pelo Rangô". Em dois minutos, o tráfego sobe de 5 para 250 requisições por segundo. A CPU vai a 100%, as requisições se acumulam na fila do Nginx, e o tempo de resposta passa de 80 milissegundos para 12 segundos. Às 21h19, o processo fica sem memória, o kernel o mata, e o `restart: unless-stopped` o recria só para ele morrer de novo um minuto depois. Quem estava montando um pedido perde o carrinho. Quem clicou em "Confirmar" não sabe se o pedido foi feito.

O capítulo anterior terminou com três perguntas: compra-se um servidor maior ou vários pequenos? Como a requisição chega ao servidor menos ocupado? E o que acontece com quem estava no meio de um pedido quando um servidor cai? Este capítulo responde as três, e no caminho você vai descobrir uma decisão escondida no código do Rangô que impede qualquer resposta de funcionar.

## Primeiro, as contas

Se cada requisição consome uns 80 milissegundos de processador, um processo Python atende por volta de 12 requisições por segundo (1 dividido por 0,08). A aproximação é grosseira, mas dá a ordem de grandeza: para 250 requisições por segundo, você precisaria de uns 21 processos trabalhando ao mesmo tempo, mais uma margem. E repare no efeito da lentidão: com 12 segundos por requisição, a mesma taxa de chegada significa 3.000 requisições acumuladas esperando. A lentidão aumenta a fila, e a fila aumenta a lentidão.

Agora, as duas formas de conseguir esses 21 processos.

## Para cima ou para os lados

**Escala vertical** é trocar o servidor por um maior: de 2 para 16 vCPUs, de 4 para 64 GB de memória. **Escala horizontal** é colocar mais servidores iguais lado a lado e dividir o trabalho entre eles. Em inglês, você vai ouvir *scale up* para a primeira e *scale out* para a segunda.

A vertical é tentadora porque dispensa mudanças no código: você desliga o servidor, escolhe um tamanho maior e liga de novo. Para muitas aplicações, isso resolve por anos. Mas existe um teto (o maior servidor à venda), a troca quase sempre exige desligar a máquina, e, o mais grave, continua existindo um único servidor. Se ele cair, o Rangô inteiro cai junto. Isso tem nome, **ponto único de falha** (*single point of failure*), e você vai ouvir essa expressão muitas vezes neste livro.

E há uma pegadinha específica para quem programa em Python.

> **Armadilha:** o `CMD` do Dockerfile do Rangô roda o Uvicorn com um único processo. Por causa do GIL, um processo Python executa código Python em um núcleo de cada vez. Se você trocar o servidor de 2 para 16 vCPUs sem mudar mais nada, o Rangô continua usando praticamente um núcleo, e os outros 15 ficam olhando. Para aproveitar a máquina maior, seria preciso rodar vários processos, com `--workers` no Uvicorn ou vários containers. (O Python 3.13 trouxe uma versão experimental sem GIL, mas ela ainda está longe de ser o padrão em produção.)

A escala horizontal resolve esses limites: sempre dá para adicionar mais uma máquina, sem desligar as outras, e se uma cair as demais continuam atendendo. Em troca, alguém precisa distribuir as requisições, e a aplicação precisa funcionar quando requisições do mesmo usuário caem em servidores diferentes. A primeira exigência é um componente novo. A segunda é uma mudança no seu código, e é a que pega a maioria das equipes desprevenida.

## O balanceador de carga

Com três servidores rodando a API, `rango.com.br` precisa apontar para algum lugar. Você poderia colocar os três IPs no DNS, e alguns sistemas fazem isso, mas você lembra do capítulo 2: resolvers guardam a resposta em cache pelo tempo do TTL, e um servidor que caiu continua recebendo usuários até o cache expirar. O DNS não sabe se o servidor está vivo.

A solução comum é colocar um componente na frente de todos: o **balanceador de carga** (*load balancer*). O usuário fala com um único endereço, o do balanceador, e ele repassa cada requisição para um dos servidores de trás. Os servidores que recebem o tráfego costumam ser chamados de *backends* ou alvos.

```text
                         ┌──────────────┐
                    ┌───►│  API (1)     │
                    │    └──────────────┘
 usuário ──► balanceador ──► API (2)
                    │    ┌──────────────┐
                    └───►│  API (3)     │
                         └──────────────┘
```

Se isso lembrou o proxy reverso do capítulo 3, a lembrança está certa: com mais de um backend, o Nginx passa a ser também um balanceador.

### Camada 4 e camada 7

Você vai ver balanceadores classificados por "camada", uma referência ao modelo de camadas de rede. Na prática, a diferença é o que o balanceador enxerga.

Um balanceador de **camada 4** trabalha no nível do TCP (ou UDP). Ele vê IPs e portas e encaminha a conexão inteira para um backend, sem ler o HTTP. Por isso é muito rápido e serve para qualquer protocolo, inclusive conexões com bancos de dados.

Um balanceador de **camada 7** entende HTTP. Ele termina o TLS, lê a requisição e decide pelo conteúdo: `/api/*` para um grupo de servidores, `/admin/*` para outro, `Host: parceiros.rango.com.br` para um terceiro. Também adiciona cabeçalhos como o `X-Forwarded-For` e responde redirecionamentos. Custa um pouco mais de processamento, e compensa na maioria das aplicações web.

O Nginx com `proxy_pass`, do jeito que o Rangô usa, é um balanceador de camada 7. Na AWS, as duas variedades existem como serviços separados, e o capítulo 13 coloca o Rangô atrás do de camada 7.

### Como escolher o servidor

A forma mais simples de distribuir é o **round robin**: a primeira requisição vai para o servidor 1, a segunda para o 2, a terceira para o 3, a quarta de volta para o 1. Funciona bem quando as requisições custam mais ou menos a mesma coisa.

Quando algumas requisições são muito mais pesadas (um relatório de 3 segundos ao lado de listagens de 20 milissegundos), o round robin pode empilhar trabalho num servidor enquanto outro está livre. O algoritmo de **menos conexões** (*least connections*) manda cada requisição para o servidor com menos requisições em andamento, e responde a pergunta sobre o servidor menos ocupado.

Existe uma terceira família, que escolhe o servidor por um *hash* de alguma coisa da requisição, como o IP do cliente. O mesmo cliente cai sempre no mesmo servidor. Guarde essa ideia, porque ela vai voltar daqui a pouco como uma tentação perigosa.

### Health checks: quem está vivo?

Distribuir requisições para um servidor morto é pior que não ter balanceador. O balanceador precisa saber quem está em condições de receber tráfego, e ele descobre isso com **health checks**.

No **health check ativo**, o balanceador consulta cada backend periodicamente, por exemplo `GET /health` a cada 10 segundos; quem falha duas vezes seguidas sai da lista e volta quando se recupera. No **health check passivo**, ele observa o tráfego real: se as requisições para um backend falham com erro de conexão ou *timeout*, ele o deixa de lado por um tempo.

O endpoint `/health` que o Rangô tem desde o capítulo 1 existe exatamente para isso. E o `readinessProbe` do Kubernetes, que você configurou no capítulo 3, é um health check ativo feito pelo orquestrador.

> **Armadilha:** um health check "profundo", que testa o banco, o Redis e a API de pagamento antes de responder 200, parece mais responsável. Pense no que acontece quando o Redis fica lento por um minuto. Todas as instâncias da API respondem 500 no `/health` ao mesmo tempo, o balanceador tira todas de circulação, e uma lentidão parcial vira o Rangô inteiro fora do ar. O health check usado pelo balanceador deve responder à pergunta "este processo consegue atender requisições?". Problemas de dependências compartilhadas são assunto de alarme e monitoramento, que o capítulo 6 apresenta.

## O segredo que o código guardava

Com balanceador e health checks, bastaria subir três cópias da API atrás do Nginx. Antes de fazer isso, pense no carrinho de compras.

A forma mais natural de implementar um carrinho num protótipo é um dicionário em memória: `CARRINHOS["ana"] = {"Lasanha": 2}`. Com um processo só, funciona. Com três atrás de um round robin, a Ana adiciona a lasanha na instância 1, e o React pede o carrinho à instância 2, que nunca ouviu falar da Ana. O carrinho aparece vazio. Ela adiciona de novo, cai na instância 3, e agora existem três carrinhos diferentes da Ana.

Esse é o problema do **estado local**. Uma aplicação é **stateful** quando guarda, no próprio processo ou no próprio disco, informação de que requisições futuras dependem. É **stateless** quando cada requisição traz ou busca tudo o que precisa, e qualquer instância pode atendê-la igualmente bem. Para escalar horizontalmente, a aplicação precisa ser stateless.

Pense numa função pura em Python, que não depende de nada guardado entre uma chamada e outra. Numa instância stateless, o estado existe (o carrinho precisa ficar em algum lugar), mas fica fora dela, num lugar que todas compartilham. O processo pode morrer ou ser multiplicado por dez sem que ninguém perca nada.

Além do carrinho, o estado costuma se esconder em outros lugares:

- **Sessões de login** em memória ou no disco local: o usuário loga na instância 1, a próxima requisição cai na 2, e ele está deslogado.
- **Uploads** salvos no disco do servidor. O capítulo 11 leva as fotos do Rangô para o Amazon S3 por isso.
- **Caches em memória** do processo, como um `functools.lru_cache` sobre dados que mudam: cada instância fica com uma versão.
- **Tarefas agendadas** dentro do processo da API: o e-mail "você esqueceu algo no carrinho" sai uma vez por instância.

> **Armadilha:** resolver o carrinho com **sessões aderentes** (*sticky sessions*), aquela escolha de servidor por hash que apareceu há pouco. O balanceador manda a Ana sempre para a instância 1, e o carrinho volta a funcionar. Mas quando a instância 1 cair, ou for substituída num deploy, os carrinhos de todo mundo "grudado" nela somem. E, se a aderência for por IP, os usuários atrás do mesmo CGNAT que você viu no capítulo 1 caem todos no mesmo servidor.

Para sessões de login, há duas saídas comuns. Uma é guardar a sessão num armazenamento compartilhado. A outra é usar um token assinado, como um JWT, que o próprio cliente envia em cada requisição: qualquer instância verifica a assinatura e sabe quem é o usuário sem consultar nada. Para o carrinho, o Rangô vai usar um armazenamento compartilhado e rápido: o Redis.

## Cache: a resposta mais barata é a que você não calcula

O Redis aparece em quase todo sistema que escala também por outro motivo: cache. Um **cache** é uma cópia de um dado guardada num lugar mais rápido ou mais próximo que a origem. Você já viu o cache do navegador e o da CDN no capítulo 2. Do lado do servidor, a aplicação pode guardar resultados prontos num armazenamento em memória compartilhado.

O **Redis** é um banco de dados chave-valor que mantém os dados em memória e responde em menos de um milissegundo dentro da mesma rede. Pense num dicionário Python acessível pela rede por todas as instâncias, com estruturas como hashes e contadores e um prazo de validade em cada chave. Em 2024, o Redis mudou de licença, e parte da comunidade criou um fork compatível, o Valkey; o capítulo 12 volta a isso com o cache gerenciado da AWS.

### O padrão cache-aside

A forma mais comum de usar um cache na aplicação se chama **cache-aside**. A lógica cabe em três passos:

1. Procure o dado no cache.
2. Se estiver lá (um *hit*), devolva.
3. Se não estiver (um *miss*), busque na origem, grave no cache com um prazo de validade e devolva.

É o mesmo raciocínio do `@lru_cache`, só que compartilhado entre processos e com expiração. A lista de restaurantes do Rangô é uma candidata perfeita: todo usuário que abre o app a pede, ela muda poucas vezes por dia, e uma versão com um minuto de atraso não prejudica ninguém. Na noite da TV, com 250 requisições por segundo, um cache de 60 segundos transforma 15 mil consultas por minuto ao banco em uma.

### O difícil: quando o dado muda

Quando a Cantina da Nona muda a taxa de entrega de R$ 6,90 para R$ 7,90, o cache continua servindo o valor antigo até expirar. Você tem duas ferramentas. A primeira é o TTL: aceitar que o dado pode ficar velho por no máximo aquele tempo. A segunda é a invalidação explícita: no mesmo código que atualiza a taxa no banco, apagar a chave do cache para que a próxima leitura busque o valor novo. Na prática, as duas andam juntas, porque a invalidação explícita às vezes falha (o processo cai entre gravar no banco e apagar a chave), e o TTL limita o estrago.

O que pode ser cacheado é uma decisão de negócio. A lista com um minuto de atraso é aceitável. O valor cobrado ao confirmar o pedido vem da origem, sempre, ou você terá um problema com o Procon ou com a Cantina da Nona.

> **Armadilha:** o **estouro de cache** (*cache stampede*). Às 21h15 da noite da TV, a chave `restaurantes` expira, centenas de requisições fazem miss no mesmo instante, e todas vão ao banco executar a mesma consulta. As defesas usuais são deixar uma única requisição recalcular enquanto as outras recebem o valor antigo e acrescentar uma variação aleatória ao TTL, para que as chaves não expirem todas no mesmo segundo.

## Mão na massa: três APIs, um Nginx e um Redis

Hora de transformar o Rangô. O plano tem duas etapas. Primeiro, você vai multiplicar a API e ver o balanceamento funcionar e o carrinho quebrar. Depois, vai corrigir o carrinho com Redis e acrescentar cache à lista de restaurantes.

Pré-requisitos: o projeto do capítulo 3 com Docker e Docker Compose, o certificado do `mkcert` em `certs/` e a entrada `api.rango.test` no arquivo hosts.

### Etapa 1: mostrando quem atendeu

Para enxergar o balanceamento, cada instância vai se identificar num cabeçalho da resposta. Dentro de um container, o nome do host é o ID curto do container, e isso basta. Em `backend/app/main.py`, acrescente os imports que faltam no topo e o middleware logo depois de criar o `app`:

```python
# backend/app/main.py (trechos novos)
import socket
from collections import defaultdict

from pydantic import BaseModel

INSTANCIA = socket.gethostname()


@app.middleware("http")
async def marcar_instancia(request, call_next):
    resposta = await call_next(request)
    resposta.headers["X-Rango-Instancia"] = INSTANCIA
    return resposta
```

E agora o carrinho, implementado do jeito ingênuo, em memória. O nome do usuário vai no path para simplificar o exemplo; numa aplicação real, ele viria do token de autenticação.

```python
# backend/app/main.py (continuação)
CARRINHOS: dict[str, dict[str, int]] = defaultdict(dict)


class Item(BaseModel):
    prato: str
    quantidade: int = 1


@app.post("/carrinho/{usuario}/itens")
def adicionar_item(usuario: str, item: Item):
    carrinho = CARRINHOS[usuario]
    carrinho[item.prato] = carrinho.get(item.prato, 0) + item.quantidade
    return carrinho


@app.get("/carrinho/{usuario}")
def ver_carrinho(usuario: str):
    return CARRINHOS[usuario]
```

No Nginx, troque o destino único por um grupo de servidores. Edite `nginx/rango.conf`:

```nginx
# nginx/rango.conf
upstream rango_api {
    server api:8000 max_fails=2 fail_timeout=10s;
}

server {
    listen 443 ssl;
    server_name api.rango.test;
    ssl_certificate     /etc/nginx/certs/rango.test+1.pem;
    ssl_certificate_key /etc/nginx/certs/rango.test+1-key.pem;

    location / {
        proxy_pass http://rango_api;
        proxy_connect_timeout 2s;
        proxy_next_upstream error timeout;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

O bloco `upstream` define o grupo. Há uma única linha `server`, mas, com o serviço escalado, o DNS interno do Compose devolve o IP de todas as réplicas para o nome `api`, e o Nginx usa todos em round robin. `max_fails=2 fail_timeout=10s` é o health check passivo: duas falhas em 10 segundos tiram o backend de circulação por 10 segundos. O `proxy_connect_timeout 2s` evita esperar os 60 segundos padrão por um backend mudo, e `proxy_next_upstream` passa a requisição adiante quando a conexão falha.

No `compose.yaml`, só a tag da imagem muda, para `rango-api:0.2.0`. Repare que o serviço `api` não publica portas nem tem `container_name`, e é isso que permite criar várias réplicas dele. Suba com três:

```bash
docker compose up -d --build --scale api=3
docker compose ps
```

```text
NAME            IMAGE               SERVICE   STATUS          PORTS
rango-api-1     rango-api:0.2.0     api       Up 8 seconds
rango-api-2     rango-api:0.2.0     api       Up 8 seconds
rango-api-3     rango-api:0.2.0     api       Up 8 seconds
rango-proxy-1   nginx:1.27-alpine   proxy     Up 7 seconds    127.0.0.1:8443->443/tcp
```

O prefixo dos nomes vem da pasta do projeto, então no seu terminal pode ser diferente. Agora faça seis requisições e olhe o cabeçalho:

```bash
CA="$(mkcert -CAROOT)/rootCA.pem"
for i in 1 2 3 4 5 6; do
  curl -s -o /dev/null -D - --cacert "$CA" https://api.rango.test:8443/health \
    | grep -i x-rango-instancia
done
```

```text
x-rango-instancia: 4be1f07c2a93
x-rango-instancia: 9d02c6e8b17f
x-rango-instancia: e57a3b90d4c1
x-rango-instancia: 4be1f07c2a93
x-rango-instancia: 9d02c6e8b17f
x-rango-instancia: e57a3b90d4c1
```

Os IDs vão ser outros na sua máquina, mas o padrão é este: um, dois, três, de volta ao um. Round robin funcionando.

### O carrinho quebra, como previsto

Adicione duas lasanhas ao carrinho da Ana e depois consulte o carrinho três vezes:

```bash
curl -s --cacert "$CA" -X POST https://api.rango.test:8443/carrinho/ana/itens \
  -H "Content-Type: application/json" \
  -d '{"prato": "Lasanha", "quantidade": 2}'
echo
for i in 1 2 3; do
  curl -s --cacert "$CA" https://api.rango.test:8443/carrinho/ana
  echo
done
```

```text
{"Lasanha":2}
{}
{}
{"Lasanha":2}
```

A primeira linha é a resposta do `POST`. Das três consultas, só a que caiu na mesma instância do `POST` encontra a lasanha; a posição dela varia, mas duas das três vêm vazias.

### Derrubando uma instância

Antes de corrigir, veja o health check passivo trabalhar. Pare uma das réplicas e repita o laço do cabeçalho:

```bash
docker stop "$(docker compose ps -q api | head -n 1)"
for i in 1 2 3 4 5 6; do
  curl -s -o /dev/null -D - --cacert "$CA" https://api.rango.test:8443/health \
    | grep -i x-rango-instancia
done
```

Todas as respostas vêm das duas instâncias restantes, e nenhuma falha chega ao `curl`. Uma requisição pode demorar até 2 segundos: é o Nginx esbarrando no `proxy_connect_timeout`, marcando a falha e repassando a requisição para a próxima instância.

Agora o detalhe que responde a terceira pergunta do capítulo anterior. Por padrão, o Nginx só repassa para outro backend requisições idempotentes, como `GET`. Um `POST /pedidos` que falhou no meio do caminho fica sem reenvio, porque o Nginx não sabe se a instância chegou a gravar o pedido antes de cair. Com o estado fora da instância, o carrinho sobrevive. Mas a requisição em andamento naquele instante falha, e o cliente precisa tentar de novo sem duplicar nada. Isso se chama idempotência, um dos assuntos do capítulo 5.

Suba a instância de volta e reinicie o proxy:

```bash
docker compose up -d --scale api=3
docker compose restart proxy
```

> **Armadilha:** o Nginx resolve o nome `api` uma única vez, quando inicia. Se você muda o número de réplicas, ou se uma réplica é recriada com outro IP, ele continua usando a lista antiga até ser reiniciado. Balanceadores gerenciados mantêm a lista de alvos atualizada sozinhos, como você verá no capítulo 13.

### Etapa 2: o estado vai para o Redis

Acrescente o Redis ao `compose.yaml` e diga à API onde encontrá-lo:

```yaml
# compose.yaml
services:
  api:
    build: ./backend
    image: rango-api:0.3.0
    environment:
      CORS_ORIGINS: "https://rango.test:5173"
      REDIS_URL: "redis://redis:6379/0"
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

O Redis não publica porta nenhuma: só a API, dentro da rede do Compose, fala com ele. Lembra dos bancos MongoDB sequestrados do capítulo 1? Redis exposto na internet sem senha teve o mesmo destino muitas vezes.

Instale o cliente Python e atualize o `requirements.txt`, com o ambiente virtual do backend ativado:

```bash
cd backend
pip install redis
pip freeze > requirements.txt
cd ..
```

No `main.py`, apague o dicionário `CARRINHOS` e o import de `defaultdict`, mantenha a classe `Item` e troque as duas rotas do carrinho:

```python
# backend/app/main.py (carrinho com Redis)
import redis

cache = redis.Redis.from_url(os.environ["REDIS_URL"], decode_responses=True)


def ler_carrinho(chave: str) -> dict[str, int]:
    return {prato: int(qtd) for prato, qtd in cache.hgetall(chave).items()}


@app.post("/carrinho/{usuario}/itens")
def adicionar_item(usuario: str, item: Item):
    chave = f"carrinho:{usuario}"
    cache.hincrby(chave, item.prato, item.quantidade)
    cache.expire(chave, 3600)
    return ler_carrinho(chave)


@app.get("/carrinho/{usuario}")
def ver_carrinho(usuario: str):
    return ler_carrinho(f"carrinho:{usuario}")
```

Cada carrinho vira um *hash* do Redis, um pequeno dicionário guardado sob a chave `carrinho:ana`. O `HINCRBY` soma a quantidade de forma atômica: se duas instâncias adicionarem lasanha ao mesmo carrinho no mesmo instante, nenhuma das somas se perde. O `EXPIRE` faz o carrinho abandonado sumir depois de uma hora, sem nenhuma rotina de limpeza.

Agora a lista de restaurantes com cache-aside. Para sentir a diferença, a busca vai simular uma consulta lenta ao Postgres com um `time.sleep`. Substitua a rota `/restaurantes`:

```python
# backend/app/main.py (restaurantes com cache-aside)
import json
import random
import time


def buscar_restaurantes() -> list[dict]:
    time.sleep(0.3)  # simula uma consulta de 300 ms ao Postgres
    return [
        {**r, "taxa_entrega_fmt": formatar_reais(r["taxa_entrega"])}
        for r in RESTAURANTES
    ]


@app.get("/restaurantes")
def listar_restaurantes():
    em_cache = cache.get("restaurantes")
    if em_cache is not None:
        return json.loads(em_cache)
    restaurantes = buscar_restaurantes()
    cache.set("restaurantes", json.dumps(restaurantes), ex=60 + random.randint(0, 10))
    return restaurantes
```

O `ex` define o TTL em segundos, e o `random.randint(0, 10)` é a variação aleatória contra o estouro de cache. Os imports podem ficar todos juntos no topo do arquivo, como de costume; aqui eles aparecem perto do código que os usa para facilitar a leitura.

Reconstrua e suba tudo:

```bash
docker compose up -d --build --scale api=3
docker compose restart proxy
```

Repita o teste do carrinho:

```text
{"Lasanha":2}
{"Lasanha":2}
{"Lasanha":2}
{"Lasanha":2}
```

As três consultas, cada uma numa instância diferente, encontram a mesma lasanha. Se quiser ver o dado na fonte, pergunte ao próprio Redis:

```bash
docker compose exec redis redis-cli HGETALL carrinho:ana
```

```text
1) "Lasanha"
2) "2"
```

Para medir o efeito do cache, dispare 100 requisições, 10 de cada vez, e cronometre. Esvazie o cache antes da primeira rodada para começar do zero:

```bash
docker compose exec redis redis-cli DEL restaurantes
time (seq 100 | xargs -P 10 -I{} curl -s -o /dev/null -w "%{http_code}\n" \
  --cacert "$CA" https://api.rango.test:8443/restaurantes | sort | uniq -c)
```

```text
    100 200

real    0m0.71s
```

Agora troque temporariamente a linha `em_cache = cache.get("restaurantes")` por `em_cache = None`, reconstrua, e rode de novo para comparar. Sem o cache, cada requisição paga os 300 milissegundos da consulta simulada, e a mesma rodada leva perto de 3 segundos. Os números exatos variam com a máquina; a proporção é o que importa. Desfaça a troca antes de seguir.

Ao terminar, desligue tudo com `docker compose down`. Os dados do Redis somem junto, o que para um carrinho de teste está ótimo.

## Monolito, microsserviços e serverless

Repare no que o Rangô é agora: um único código, empacotado numa única imagem, rodando em três cópias idênticas. Isso é um **monolito**, e ele acabou de escalar horizontalmente sem dificuldade. Essa observação desmonta um argumento comum a favor de microsserviços.

Na arquitetura de **microsserviços**, a aplicação é dividida em serviços pequenos e independentes, cada um com o seu código, o seu deploy e, idealmente, o seu banco de dados. O Rangô poderia virar um serviço de catálogo, um de pedidos, um de pagamentos e um de entregas, conversando entre si por HTTP ou por mensagens.

A vantagem principal aparece em organizações grandes: equipes diferentes fazem deploy sem coordenar entre si, e uma falha no serviço de recomendações não derruba o checkout. Os custos costumam ser subestimados. Uma chamada de função vira uma chamada de rede, que pode ficar lenta, falhar ou chegar duas vezes. Uma transação que garantia "pedido criado e estoque baixado juntos" vira uma coordenação entre dois serviços, sem `BEGIN` e `COMMIT` para proteger. E cada serviço precisa do seu pipeline, do seu monitoramento e de alguém de plantão. Para uma equipe de três pessoas, microsserviços costumam trazer o custo sem o benefício.

> **Na vida real:** em 2023, a equipe do Prime Video que monitora a qualidade dos streams publicou que migrou um serviço de uma arquitetura distribuída, com AWS Step Functions orquestrando funções AWS Lambda, para um processo único em containers no Amazon ECS. Segundo a equipe, o custo de infraestrutura caiu mais de 90%. O caso gerou discussão por vir de dentro da própria Amazon.

O caminho mais seguro para o Rangô é um **monolito modular**: um único deploy, com o código organizado em módulos de fronteiras claras (`catalogo`, `pedidos`, `pagamentos`), sem um acessar as tabelas do outro. Se um dia uma parte precisar ser extraída, a fronteira já existe.

### Serverless como ideia

Existe uma terceira forma de pensar a execução do código. No modelo **serverless**, você entrega uma função ao provedor de nuvem e ele cuida de todo o resto: em quais máquinas rodar, quantas cópias manter, como escalar. O nome engana, porque os servidores continuam existindo; você só deixa de vê-los e de administrá-los.

A função roda quando um evento chega (uma requisição HTTP, um arquivo enviado, um horário agendado), e você paga pelo tempo de execução. Sem tráfego, a conta fica perto de zero; com mil requisições simultâneas, o provedor sobe mil cópias. Por isso a função precisa ser stateless. As contrapartidas: a primeira requisição depois de um período parado espera a cópia ser criada (o *cold start*), as execuções têm duração máxima, e com tráfego alto e constante pagar por execução pode sair mais caro que manter servidores. O capítulo 19 aprofunda o modelo com AWS Lambda.

## Os gargalos que aparecem depois

Escalar a API resolve o primeiro gargalo e revela o próximo. Alguns aparecem em quase todo sistema.

### O banco de dados

Todas as réplicas da API falam com o mesmo Postgres. Cada processo Python costuma manter um *pool* de conexões abertas com o banco para não pagar o custo de abrir uma a cada consulta. O SQLAlchemy, por padrão, mantém até 5 conexões por pool e permite mais 10 temporárias em momentos de pico, ou seja, até 15 por processo. O Postgres, por padrão, aceita 100 conexões no total.

Faça a conta da noite da TV. Com 21 processos da API, são até 315 conexões tentando entrar num banco que aceita 100. A partir da centésima, o Postgres recusa com uma mensagem que você não quer ler às 21h20:

```text
FATAL:  sorry, too many clients already
```

As saídas são reduzir o pool de cada processo, colocar um intermediário que reaproveita conexões entre processos (o PgBouncer é o mais conhecido no mundo Postgres) e, para a carga de leitura, usar réplicas do banco, que o capítulo 6 apresenta e o capítulo 12 coloca em prática. O cache que você acabou de implementar também ajuda muito aqui, porque cada consulta evitada é uma conexão a menos ocupada.

### O balanceador como ponto único de falha

Você tirou o ponto único de falha da API e o colocou no Nginx. Se o servidor dele cair, as três instâncias ficam vivas e inalcançáveis. Os balanceadores gerenciados da nuvem já rodam distribuídos em várias máquinas e data centers, e esse é um dos argumentos mais concretos para usar o da AWS em vez de manter um Nginx próprio na borda.

### O tempo para escalar

Escala horizontal automática, o *auto scaling*, acompanha uma métrica (CPU acima de 60% por três minutos, por exemplo) e adiciona instâncias quando ela passa do limite. Só que uma instância nova leva alguns minutos para ligar, baixar a imagem, iniciar e passar no health check. Na noite da TV, o tráfego subiu cinquenta vezes em dois minutos. Para eventos com hora marcada, a saída é escalar antes: às 20h30, o Rangô já precisa estar com a capacidade da noite. O auto scaling fica para os picos que ninguém avisou e para devolver as máquinas depois. O capítulo 13 configura as duas coisas na AWS.

> **Na vida real:** no lançamento do Pokémon GO, em julho de 2016, a Niantic e o Google planejaram a infraestrutura com uma estimativa de pior caso de cerca de 5 vezes o tráfego de referência. O tráfego real chegou a 50 vezes, dez vezes o pior caso. Os primeiros dias tiveram instabilidade, e o post do Google sobre o episódio lista entre as lições provisionar capacidade com mais folga.

### Chamadas lentas a terceiros

Há um último gargalo que nenhuma quantidade de réplicas resolve. Se uma rota espera um serviço externo (o gateway de pagamento, o provedor de e-mail), cada requisição prende um processo durante toda a espera. Se o provedor de e-mail passar de 1 para 10 segundos, cada processo atende dez vezes menos requisições. Guarde isso para a ponte.

## Armadilhas e casos reais

Algumas armadilhas apareceram ao longo do capítulo. Estas são as que faltam:

> **Armadilha:** escalar horizontalmente uma aplicação com tarefas agendadas dentro do processo. Se a API do Rangô tem um agendador que fecha o caixa do dia à meia-noite, três réplicas fecham o caixa três vezes. Tarefas agendadas precisam rodar num processo separado, com uma única cópia, ou usar um mecanismo de trava que garanta uma execução só. Os capítulos 19 e 21 mostram como a AWS resolve agendamentos fora da API.

> **Armadilha:** tratar o Redis como banco de dados definitivo. Ele guarda tudo em memória, e uma reinicialização sem persistência configurada apaga todos os carrinhos. Para carrinhos com prazo de uma hora, a perda é tolerável. Para pedidos confirmados, o lugar é o Postgres.

> **Dica:** antes de um evento previsto, faça um teste de carga com tráfego parecido com o esperado, num ambiente igual ao de produção. É no teste que você descobre o `too many clients already`, e não às 21h14 de quinta-feira. Ferramentas como k6 e Locust (esta escrita em Python) simulam milhares de usuários seguindo roteiros realistas, como abrir o app, ver a lista e montar um carrinho.

## Resumo

- Escala vertical troca o servidor por um maior e mantém o ponto único de falha. Escala horizontal adiciona servidores iguais e exige balanceador e aplicação stateless.
- Em Python, mais vCPUs só ajudam com mais processos.
- Balanceadores de camada 4 encaminham conexões TCP; os de camada 7 entendem HTTP. Round robin distribui em sequência; menos conexões escolhe o servidor mais livre.
- Health checks ativos consultam os backends; passivos observam o tráfego. O do balanceador testa o processo, sem depender de recursos compartilhados.
- Estado guardado na instância impede a escala horizontal. Sticky sessions só escondem o problema.
- Cache-aside com TTL e variação aleatória; invalidar é a parte difícil.
- O Rangô roda como `rango-api:0.3.0` em três réplicas atrás de um `upstream` no Nginx, com carrinho e cache no Redis.
- Monolito escala horizontalmente. Microsserviços servem a equipes grandes. Serverless entrega a escala ao provedor.
- Próximos gargalos: conexões com o banco, o balanceador, o tempo para escalar e a espera por serviços externos.

## Ponte: o botão que trava tudo

Quinta-feira, 21h14, de novo, agora com o Rangô preparado. Seis instâncias da API sobem às 20h30, o cache segura a lista de restaurantes, os carrinhos sobrevivem a qualquer instância que caia. O tráfego chega, a CPU fica em 45%, e a sua sócia manda uma figurinha comemorando.

Às 21h22, os gráficos mudam. A listagem continua rápida, mas o botão "Confirmar pedido" começa a girar sem parar. A rota `POST /pedidos` faz tudo em sequência: cobra o cartão no gateway de pagamento (2,5 segundos), avisa o restaurante pela API dele (2 segundos) e envia o e-mail de confirmação (1 segundo). Naquela noite, o provedor de e-mail, também sobrecarregado, passa a levar 20 segundos para responder. Cada pedido prende um processo da API por quase meio minuto. Em pouco tempo, todos os processos das seis instâncias estão parados esperando o e-mail, e até a listagem, que não tem nada a ver com isso, deixa de responder. Pior: alguns clientes, cansados de esperar, clicam de novo em "Confirmar", e o cartão é cobrado duas vezes.

Por que um e-mail atrasado consegue derrubar a confirmação do pedido? A API precisa mesmo esperar o restaurante e o e-mail para dizer ao cliente que o pedido foi recebido? E como garantir que um clique repetido não vire uma cobrança dupla? No próximo capítulo, você vai ver como filas e eventos desacoplam as partes de um sistema, e o que muda quando as coisas passam a acontecer fora de ordem.

## Referências

- Nginx, balanceamento de carga HTTP: https://nginx.org/en/docs/http/load_balancing.html
- Nginx, módulo `upstream` (`max_fails`, `fail_timeout`, `least_conn`): https://nginx.org/en/docs/http/ngx_http_upstream_module.html
- Nginx, módulo `proxy` (`proxy_next_upstream`, `proxy_connect_timeout`): https://nginx.org/en/docs/http/ngx_http_proxy_module.html
- Docker Compose, `docker compose up` e a opção `--scale`: https://docs.docker.com/reference/cli/docker/compose/up/
- Redis, documentação oficial: https://redis.io/docs/latest/
- redis-py, cliente Python: https://redis.readthedocs.io/
- Valkey: https://valkey.io/
- The Twelve-Factor App, processos stateless: https://12factor.net/processes
- PostgreSQL, `max_connections`: https://www.postgresql.org/docs/current/runtime-config-connection.html
- SQLAlchemy, pool de conexões: https://docs.sqlalchemy.org/en/20/core/pooling.html
- Martin Fowler, "Microservices": https://martinfowler.com/articles/microservices.html
- Martin Fowler, "MonolithFirst": https://martinfowler.com/bliki/MonolithFirst.html
- Google Cloud, "Bringing Pokémon GO to life on Google Cloud" (2016): https://cloud.google.com/blog/products/containers-kubernetes/bringing-pokemon-go-to-life-on-google-cloud
- InfoQ, sobre a migração do monitoramento do Prime Video para um monolito (2023): https://www.infoq.com/news/2023/05/prime-ec2-ecs-saves-costs/
