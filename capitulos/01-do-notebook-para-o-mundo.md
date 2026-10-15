# Do notebook para o mundo

Este livro foi escrito para quem já constrói aplicações completas, do banco de dados ao botão na tela, mas sempre teve alguém (ou alguma plataforma mágica) cuidando de onde elas rodam. Você sabe escrever uma API, sabe montar um front em React, sabe depurar uma query lenta. O que acontece entre o `git push` e o usuário abrindo o app no celular continua meio nebuloso. É esse trecho que vamos percorrer juntos.

O livro tem duas partes. Na Parte I, que começa agora, você vai ver os conceitos de infraestrutura e DevOps sem nenhum provedor de nuvem no meio: redes, DNS, servidores, containers, escala, filas, backups, deploy. A ideia é montar o vocabulário e entender o porquê de cada peça. Na Parte II, a partir do capítulo 7, cada um desses conceitos volta, agora implementado na AWS e com profundidade.

Para não ficar só na teoria, vamos acompanhar um único projeto do começo ao fim: o **Rangô**, um app de pedidos de comida. O cliente escolhe um restaurante, monta o pedido, paga e acompanha a entrega. Hoje ele vive inteiro no seu notebook. No último capítulo, ele estará em produção na AWS, aguentando tráfego, com backups, monitoramento e uma fatura que não assusta ninguém.

### Conhecendo o Rangô

O Rangô tem um backend em **FastAPI** e um frontend em React, criado com Vite. Os dados ficam num PostgreSQL rodando localmente.

Se você vem do Flask, o FastAPI vai parecer familiar logo de cara. As rotas também são funções decoradas com `@app.get` ou `@app.post`. A diferença principal é que ele usa as anotações de tipo do Python para validar a entrada e gerar a documentação da API automaticamente, e aceita funções `async` sem cerimônia. Quem roda a aplicação é o **Uvicorn**, um servidor ASGI (o equivalente assíncrono do WSGI que o Gunicorn usa com Flask e Django).

Por enquanto, o backend do Rangô é bem pequeno. Ele tem uma rota de saúde e uma lista fixa de restaurantes, guardada em memória enquanto o banco não entra em cena:

```python
# backend/app/main.py
import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="Rangô")

origens = os.getenv("CORS_ORIGINS", "http://localhost:5173").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origens,
    allow_methods=["GET"],
    allow_headers=["*"],
)

RESTAURANTES = [
    {"id": 1, "nome": "Cantina da Nona", "cozinha": "italiana"},
    {"id": 2, "nome": "Sabor do Sertão", "cozinha": "nordestina"},
]


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/restaurantes")
def listar_restaurantes():
    return RESTAURANTES
```

O frontend busca essa lista e mostra na tela:

```tsx
// frontend/src/App.tsx
import { useEffect, useState } from "react";

type Restaurante = { id: number; nome: string; cozinha: string };

const API_URL = import.meta.env.VITE_API_URL ?? "http://localhost:8000";

export default function App() {
  const [restaurantes, setRestaurantes] = useState<Restaurante[]>([]);

  useEffect(() => {
    fetch(`${API_URL}/restaurantes`)
      .then((resposta) => resposta.json())
      .then(setRestaurantes);
  }, []);

  return (
    <main>
      <h1>Rangô</h1>
      <ul>
        {restaurantes.map((r) => (
          <li key={r.id}>
            {r.nome} ({r.cozinha})
          </li>
        ))}
      </ul>
    </main>
  );
}
```

Para rodar, você precisa de Python 3.12 ou mais recente e Node.js 20 ou mais recente. Em dois terminais:

```bash
# Terminal 1: backend
cd backend
python -m venv .venv
source .venv/bin/activate        # no Windows: .venv\Scripts\activate
pip install "fastapi[standard]"
uvicorn app.main:app --reload --port 8000
```

```bash
# Terminal 2: frontend
cd frontend
npm install
npm run dev
```

Abra `http://localhost:5173` no navegador e os dois restaurantes aparecem. Funciona. Os problemas começam quando outra pessoa tenta abrir.

## O link que não abriu

A sua sócia no Rangô mora em Recife. Ela cuida da parte comercial e quer ver o app antes de mostrar para os primeiros restaurantes parceiros. Você, animado, manda uma mensagem: "Está rodando, abre aí: http://localhost:5173".

Dois minutos depois, chega a resposta com um print. O navegador dela mostra "Não é possível acessar esse site. A conexão com localhost foi recusada."

Você pensa um pouco e lembra que `localhost` é a sua máquina. Abre o terminal, descobre que o seu notebook tem o endereço `192.168.0.12` e manda de novo: "Tenta http://192.168.0.12:5173". Desta vez o navegador dela fica girando por quase meio minuto até desistir com um erro de tempo esgotado.

Repare que os dois erros são diferentes. No primeiro, alguém respondeu "não" na hora. No segundo, ninguém respondeu nada. Essa diferença, que parece detalhe, diz muito sobre o que está acontecendo, e você vai aprender a ler esse tipo de sinal ao longo deste capítulo.

A pergunta que fica é simples de fazer e trabalhosa de responder: o que precisa acontecer para que uma requisição saia do celular da sua sócia, em Recife, atravesse o país e chegue ao processo do Uvicorn rodando no seu notebook? Para responder, vamos seguir o caminho dessa requisição peça por peça.

## Localhost: o endereço que nunca sai de casa

Quando você digita `localhost`, o sistema operacional traduz esse nome para `127.0.0.1` (ou `::1`, a versão em IPv6). Esse endereço pertence a uma interface de rede especial chamada **loopback**. Ela existe só em software, e tudo o que entra nela volta para a própria máquina. Nenhum pacote enviado para `127.0.0.1` passa pelo Wi-Fi ou pelo cabo.

Por isso o primeiro link falhou de forma tão rápida. O navegador da sua sócia tentou se conectar ao `localhost` dela, ou seja, ao celular dela. Lá não havia nada escutando na porta 5173, e o próprio sistema do celular respondeu na hora: conexão recusada.

Toda máquina tem o seu próprio `localhost`. Mandar esse endereço para alguém é como dizer "passa aqui em casa" sem dizer onde fica a casa.

## Endereços IP: o CEP de cada máquina

Para uma máquina encontrar outra, cada uma precisa de um endereço. Na internet, esse endereço é o **endereço IP** (de *Internet Protocol*). Na versão mais usada, o **IPv4**, ele tem 32 bits, escritos como quatro números de 0 a 255 separados por pontos: `192.168.0.12`, `200.147.67.142`, `8.8.8.8`.

Um detalhe que costuma surpreender: o IP pertence a uma **interface de rede**, e uma máquina pode ter várias. O seu notebook tem pelo menos duas: a loopback, com `127.0.0.1`, e a placa de Wi-Fi, com algo como `192.168.0.12`. Se você conectar um cabo de rede, ganha uma terceira, com outro IP.

Com 32 bits, cabem cerca de 4,3 bilhões de endereços IPv4. Parecia muito nos anos 1980. Hoje existem mais celulares do que isso, e os blocos livres de IPv4 já se esgotaram nos registros regionais que distribuem esses endereços. A resposta de longo prazo é o **IPv6**, com 128 bits e endereços como `2804:14c:65:8a00::1`. Ele já carrega boa parte do tráfego no Brasil, mas o IPv4 continua presente em quase tudo, e foram as gambiarras para fazer o IPv4 durar que criaram metade dos conceitos deste capítulo. Vamos chegar nelas.

## Portas: o apartamento dentro do prédio

O IP leva a requisição até a máquina certa. Só que no seu notebook rodam dezenas de programas que usam a rede ao mesmo tempo: o Uvicorn, o Vite, o PostgreSQL, o navegador, o Slack. Quando um pacote chega, como o sistema operacional sabe para qual deles entregar?

É para isso que existem as **portas**. Uma porta é um número de 0 a 65535 que identifica um processo escutando conexões naquela máquina. Se o IP é o endereço do prédio, a porta é o número do apartamento.

Essa analogia pode ir um passo além, com algo que você já conhece. Numa URL como `http://192.168.0.12:8000/restaurantes`, cada pedaço resolve um nível:

- o IP (`192.168.0.12`) escolhe a máquina;
- a porta (`8000`) escolhe o processo dentro dela, no caso o Uvicorn;
- o caminho (`/restaurantes`) escolhe a função dentro do processo, a que tem o decorator `@app.get("/restaurantes")`.

O roteamento do FastAPI faz, dentro da aplicação, o que o IP e a porta fazem na rede.

Algumas portas viraram convenção. HTTP usa a 80, HTTPS usa a 443, SSH usa a 22 e o PostgreSQL usa a 5432. Quando você digita `https://google.com` sem porta, o navegador assume a 443. As portas abaixo de 1024 são chamadas de **privilegiadas**: em Linux, um processo comum precisa de permissão especial para escutar nelas. É por isso que, no desenvolvimento, usamos 8000 e 5173 em vez de 80. No capítulo 3, você vai ver como um servidor em produção resolve isso com um proxy reverso.

Uma porta só pode ter um dono por vez, para um mesmo endereço. Se você tentar subir um segundo Uvicorn na 8000 enquanto o primeiro está rodando, recebe o famoso `[Errno 48] Address already in use` (no Linux, o número do erro é 98). A mensagem quer dizer exatamente isso: o apartamento já tem morador.

### Escutar em qual endereço?

Lembra que o notebook tem várias interfaces, cada uma com um IP? Quando um processo começa a escutar numa porta, ele escolhe também em qual endereço vai escutar. Esse passo se chama *bind*.

O Uvicorn, por padrão, faz bind em `127.0.0.1`. Ele aceita conexões que chegam pela loopback e ignora as que chegam pelo Wi-Fi. É uma escolha segura: você não quer que qualquer pessoa no Wi-Fi da cafeteria acesse a sua API de desenvolvimento. O Vite faz o mesmo.

Para aceitar conexões de outras máquinas, você precisa fazer bind em `0.0.0.0`. Nesse contexto, `0.0.0.0` significa "todas as interfaces desta máquina". Guarde essa distinção, porque ela vai aparecer de novo na seção de armadilhas, em uma história nada agradável.

## TCP e UDP: como a conversa acontece

Saber o IP e a porta permite que um pacote chegue ao destino. Mas uma requisição HTTP com uma resposta de alguns megabytes vira centenas de pacotes. Eles podem se perder no caminho, chegar fora de ordem ou chegar duplicados. Alguém precisa organizar essa bagunça, e é aí que entram os protocolos de transporte.

O **TCP** (*Transmission Control Protocol*) cria uma conexão confiável entre os dois lados. Antes de qualquer dado, os dois lados fazem o *three-way handshake*, um aperto de mão em três passos:

```text
Cliente                          Servidor
   |  ---- SYN ------------------>  |   "quero conversar"
   |  <--- SYN-ACK ---------------  |   "ok, eu também"
   |  ---- ACK ------------------>  |   "combinado"
   |                                |
   |  ==== dados (HTTP) =========>  |
```

Depois disso, o TCP numera cada pedaço de dado, confirma o que recebeu, reenvia o que se perdeu e entrega tudo na ordem certa para a aplicação. O Uvicorn nunca vê um pacote perdido. Ele recebe a requisição inteira, como se a rede fosse perfeita. HTTP/1.1 e HTTP/2, que carregam praticamente todas as APIs que você já escreveu, rodam sobre TCP.

O handshake explica os dois erros que a sua sócia viu. Quando o navegador manda um SYN para uma máquina que existe, mas não tem ninguém escutando naquela porta, o sistema operacional dessa máquina responde com um pacote **RST** (*reset*). O navegador traduz isso como "conexão recusada", e acontece em milissegundos. Quando o SYN nunca chega a lugar nenhum, ou chega e é descartado em silêncio, o navegador fica esperando um SYN-ACK que nunca vem. Depois de algumas tentativas, desiste com um *timeout*.

Essa diferença vale ouro na hora de investigar problemas de rede:

| Sintoma | O que provavelmente aconteceu |
|---------|-------------------------------|
| Conexão recusada, na hora | A máquina foi encontrada, mas nada escuta naquela porta (ou o processo fez bind só em `127.0.0.1`) |
| Timeout, depois de vários segundos | O pacote não chegou: endereço inalcançável, firewall descartando ou rota inexistente |

O **UDP** (*User Datagram Protocol*) segue o caminho oposto. Ele não faz handshake, não confirma recebimento e não reenvia nada. Manda o pacote e pronto. Parece pior, mas é a escolha certa quando rapidez importa mais do que garantia: numa chamada de vídeo, um quadro perdido deve ser simplesmente ignorado, porque reenviá-lo meio segundo depois só atrapalharia. O DNS, que você vai conhecer no próximo capítulo, usa UDP na maior parte das consultas. E o HTTP/3 roda sobre o QUIC, um protocolo construído em cima do UDP que reimplementa a confiabilidade do seu próprio jeito.

## Roteamento: de salto em salto até o destino

Agora você sabe como dois processos conversam quando um sabe o IP do outro. Mas entre o celular em Recife e o seu notebook existem dezenas de equipamentos. Quem decide o caminho?

Ninguém decide o caminho inteiro. A internet funciona de salto em salto. Cada equipamento no meio do caminho, chamado **roteador**, olha o IP de destino do pacote, consulta a sua própria **tabela de rotas** e decide só qual é o próximo salto. O roteador seguinte faz o mesmo, e assim por diante. É parecido com pedir informação na rua: ninguém te explica o trajeto completo, cada pessoa só aponta para a próxima esquina.

O seu notebook também tem uma tabela de rotas, e ela costuma ser bem curta. Em geral diz duas coisas: "endereços da rede local, entregue direto" e "todo o resto, mande para o roteador de casa". Esse "todo o resto" é a **rota padrão**, e o roteador para onde ela aponta é o **gateway padrão**.

Quando várias rotas servem para um mesmo destino, vence a mais específica. Esse critério se chama *longest prefix match*. Se você já escreveu rotas no FastAPI, conhece a ideia: uma rota `/restaurantes/destaques` precisa ser tratada antes de `/restaurantes/{id}`, senão a palavra "destaques" seria interpretada como um id. Na tabela de rotas, a rota padrão é escrita como `0.0.0.0/0`, que quer dizer "qualquer endereço". Ela é a menos específica de todas, uma espécie de rota curinga, usada só quando nenhuma outra serve. Em breve você vai entender exatamente o que esse `/0` significa.

## IP público, IP privado e o truque do NAT

Volte ao segundo link, o `http://192.168.0.12:5173`. Por que ele deu timeout?

Porque `192.168.0.12` é um **IP privado**. Para adiar o esgotamento do IPv4, a RFC 1918 reservou três faixas de endereços para uso interno, que qualquer rede pode usar à vontade e que nunca são roteadas na internet pública:

| Faixa | Notação CIDR | Uso típico |
|-------|--------------|------------|
| 10.0.0.0 a 10.255.255.255 | `10.0.0.0/8` | Empresas e redes na nuvem |
| 172.16.0.0 a 172.31.255.255 | `172.16.0.0/12` | Empresas, redes do Docker |
| 192.168.0.0 a 192.168.255.255 | `192.168.0.0/16` | Redes domésticas |

Neste exato momento, milhões de casas usam o endereço `192.168.0.12`. Quando o celular da sua sócia tentou alcançá-lo, os roteadores entre ela e a internet não tinham rota para esse endereço fora da rede local dela. O pacote foi descartado em silêncio e o navegador esperou até desistir.

Um **IP público**, por outro lado, é único no mundo inteiro e roteável na internet. O seu roteador de casa recebe um do provedor. Todas as máquinas da sua casa saem para a internet usando esse mesmo IP público. Como isso funciona?

### NAT: a portaria do condomínio

O truque se chama **NAT** (*Network Address Translation*). Quando o seu notebook faz uma requisição para fora, o roteador troca o IP privado de origem (`192.168.0.12`) pelo IP público dele e anota essa troca numa tabela. Quando a resposta volta, ele consulta a tabela, descobre que aquela conexão pertence ao notebook e entrega o pacote para `192.168.0.12`.

Se você quiser pensar em código, a tabela do NAT é um dicionário Python mais ou menos assim:

```python
# Visão simplificada da tabela de NAT do roteador
tabela_nat = {
    # (IP público, porta pública): (IP privado, porta privada)
    ("203.0.113.45", 51001): ("192.168.0.12", 62344),  # notebook
    ("203.0.113.45", 51002): ("192.168.0.23", 49210),  # celular
}
```

Os endereços `203.0.113.x` usados aqui fazem parte de uma faixa reservada para documentação (RFC 5737) e não pertencem a ninguém. Vamos usar essa faixa e a `198.51.100.x` em todos os exemplos de IP público do livro.

Agora pense no que acontece quando chega um pacote de fora que não responde a nenhuma requisição anterior. A sua sócia tenta se conectar ao IP público da sua casa, na porta 5173. O roteador procura na tabela, não encontra nenhuma entrada para aquela porta e descarta o pacote. Por isso o NAT, além de economizar endereços, funciona como uma barreira involuntária: conexões de entrada não solicitadas simplesmente não entram.

Existe um jeito de furar essa barreira, o *port forwarding*: você configura no roteador uma regra fixa do tipo "tudo que chegar na porta 5173 vai para `192.168.0.12`". Funciona, mas deixa a sua máquina exposta para a internet inteira, e não só para a sua sócia. Logo você vai ver por que isso é uma péssima ideia.

### CGNAT: quando nem o roteador tem IP público

Em muitas conexões residenciais e quase todas as conexões móveis no Brasil, existe ainda uma segunda camada. O provedor coloca vários clientes atrás de um único IP público, fazendo NAT do lado dele. Isso se chama **CGNAT** (*Carrier-Grade NAT*). O roteador da sua casa recebe um endereço da faixa `100.64.0.0/10`, reservada para esse fim, e não um IP público de verdade.

Com CGNAT, nem o port forwarding resolve, porque você não controla o NAT do provedor. Um jeito fácil de desconfiar disso é comparar o IP que o seu roteador mostra no painel de administração com o IP que um serviço externo enxerga. Se forem diferentes, há um NAT a mais no caminho.

## CIDR e subnets: fatiando endereços

Você já esbarrou em notações como `192.168.0.0/16` e `0.0.0.0/0`. Chegou a hora de entender o que essa barra quer dizer, porque ela vai acompanhar você por todo o livro e, na Parte II, vai aparecer em praticamente toda configuração de rede.

Um IPv4 tem 32 bits. A notação **CIDR** (*Classless Inter-Domain Routing*) descreve um bloco de endereços dizendo quantos bits do começo são fixos. O número depois da barra é essa quantidade. Os bits restantes podem variar, e cada combinação é um endereço do bloco.

Em `192.168.0.0/24`, os primeiros 24 bits (os três primeiros números, `192.168.0`) são fixos. Sobram 8 bits livres, que geram 2⁸ = 256 endereços, de `192.168.0.0` até `192.168.0.255`. A regra geral é que um bloco `/n` tem 2^(32−n) endereços. Quanto maior o número depois da barra, menor o bloco:

| CIDR | Bits livres | Endereços | Exemplo |
|------|-------------|-----------|---------|
| `/32` | 0 | 1 | Um único host |
| `/28` | 4 | 16 | Uma subnet bem pequena |
| `/24` | 8 | 256 | Uma rede doméstica típica |
| `/16` | 16 | 65.536 | Uma rede corporativa ou de nuvem |
| `/0` | 32 | Todos | A rota padrão, "qualquer lugar" |

Agora o `0.0.0.0/0` da tabela de rotas fica claro: zero bits fixos, qualquer endereço serve. O *longest prefix match* também. Uma rota para `192.168.0.0/24` fixa 24 bits, então é mais específica que `0.0.0.0/0`, que não fixa nenhum.

Na prática, nem todos os endereços de um bloco podem ser usados por máquinas. Em redes tradicionais, o primeiro endereço identifica a própria rede e o último é o de *broadcast*. A AWS vai além e reserva cinco endereços em cada subnet, então um bloco `/24` lá oferece 251 endereços utilizáveis. Você vai encontrar isso de novo no capítulo 10.

### Subnet: quem conversa direto com quem

Uma **subnet** é um bloco de endereços cujas máquinas se falam diretamente, sem passar por um roteador. A rede da sua casa é uma subnet, quase sempre `192.168.0.0/24` ou `192.168.1.0/24`. Quando o notebook quer falar com o celular, que está em `192.168.0.23`, ele consulta a tabela de rotas, vê que o destino está na mesma subnet e entrega direto. Para qualquer outro destino, manda para o gateway.

Subnets servem para organizar e para isolar. Numa empresa, você pode colocar os servidores numa subnet, os notebooks dos funcionários em outra e as impressoras numa terceira, controlando o que passa de uma para outra. Na nuvem, a separação mais comum é entre **subnets públicas**, que têm rota para a internet, e **subnets privadas**, que não têm. O servidor web fica na pública. O banco de dados fica na privada, onde ninguém de fora consegue chegar. Guarde essa imagem, porque o Rangô vai precisar dela.

## Mão na massa: seguindo os pacotes do Rangô

Chega de teoria. Vamos usar o terminal para enxergar tudo isso no seu próprio notebook e, no fim, colocar o Rangô no celular. Os comandos abaixo funcionam em macOS e Linux. Quando o Windows tiver um equivalente diferente, ele aparece no comentário.

### Descubra os seus endereços

Primeiro, o IP privado do notebook na rede local:

```bash
# macOS (en0 costuma ser o Wi-Fi)
ipconfig getifaddr en0

# Linux
ip -4 addr show

# Windows: rode "ipconfig" e procure "Endereço IPv4"
```

Algo como `192.168.0.12` deve aparecer. No Linux, você verá também a interface `lo`, com `127.0.0.1`: é a loopback.

Agora, o IP público com que o mundo enxerga você:

```bash
curl https://checkip.amazonaws.com
```

```text
203.0.113.45
```

São dois endereços diferentes. O primeiro só existe dentro da sua casa. O segundo pertence ao roteador, ou ao provedor, se houver CGNAT. Se você abrir o painel do roteador e o IP de WAN mostrado lá começar com `100.`, entre 100.64 e 100.127, você está atrás de CGNAT.

### Veja quem está escutando

Suba o backend do Rangô do jeito padrão e, em outro terminal, pergunte ao sistema quem está escutando na porta 8000:

```bash
lsof -nP -iTCP:8000 -sTCP:LISTEN

# Linux, alternativa: ss -ltnp | grep 8000
# Windows: netstat -ano | findstr :8000
```

```text
COMMAND   PID  USER   FD   TYPE  DEVICE  SIZE/OFF NODE NAME
Python  41233  voce    3u  IPv4  0x9a1c       0t0  TCP 127.0.0.1:8000 (LISTEN)
```

A coluna `NAME` mostra o bind: `127.0.0.1:8000`. O Uvicorn só aceita conexões pela loopback. Teste com o `nc` (netcat), que tenta abrir uma conexão TCP e informa o resultado:

```bash
nc -zv 127.0.0.1 8000
nc -zv 127.0.0.1 8001
```

```text
Connection to 127.0.0.1 port 8000 [tcp/*] succeeded!
nc: connectx to 127.0.0.1 port 8001 (tcp) failed: Connection refused
```

O texto exato muda um pouco entre sistemas, mas o resultado é o mesmo: a 8000 completou o handshake, e a 8001 respondeu com RST, porque ninguém mora lá.

Agora faça o teste mais revelador. Tente se conectar à porta 8000 usando o IP do Wi-Fi, e não o da loopback:

```bash
curl http://192.168.0.12:8000/health
```

```text
curl: (7) Failed to connect to 192.168.0.12 port 8000 after 2 ms: Couldn't connect to server
```

Conexão recusada, na própria máquina. O Uvicorn está rodando, mas fez bind só em `127.0.0.1`, então ignora o que chega pela interface do Wi-Fi. Para comparar, veja como é um timeout de verdade, usando um IP de documentação que não leva a lugar nenhum:

```bash
curl --connect-timeout 5 http://203.0.113.10:8000/health
```

```text
curl: (28) Failed to connect to 203.0.113.10 port 8000 after 5002 ms: Timeout was reached
```

Dois milissegundos contra cinco segundos. Agora você reconhece a assinatura de cada erro.

### Olhe a tabela de rotas

```bash
# Linux
ip route

# macOS: netstat -rn -f inet
# Windows: route print
```

```text
default via 192.168.0.1 dev wlan0 proto dhcp metric 600
192.168.0.0/24 dev wlan0 proto kernel scope link src 192.168.0.12 metric 600
```

São as duas regras que você já conhece. A segunda diz que a subnet `192.168.0.0/24` é entregue direto pela interface `wlan0`. A primeira é a rota padrão: todo o resto vai para `192.168.0.1`, o roteador de casa. No macOS, a rota padrão aparece como `default` na coluna `Destination`.

### Siga os saltos

O `traceroute` mostra cada roteador no caminho até um destino. Ele envia pacotes com um limite de saltos crescente e anota quem devolve o aviso de "limite esgotado" em cada etapa:

```bash
traceroute checkip.amazonaws.com
# Windows: tracert checkip.amazonaws.com
```

```text
 1  192.168.0.1      2.1 ms
 2  100.64.0.1       8.4 ms
 3  198.51.100.17   11.9 ms
 4  198.51.100.94   14.2 ms
 5  * * *
 6  203.0.113.201  142.7 ms
```

A saída acima foi simplificada, e os endereços dos saltos externos foram trocados por IPs de documentação. Mesmo assim, ela mostra uma história típica. O primeiro salto é o seu roteador. O segundo, com `100.64.0.1`, denuncia o CGNAT do provedor. Os asteriscos indicam um roteador que não responde a esse tipo de sonda, o que é comum e não significa que o caminho esteja quebrado. E o salto de 142 ms mostra o pacote atravessando um oceano: `checkip.amazonaws.com` costuma responder de servidores nos Estados Unidos. Guarde esse número, porque a distância até a região escolhida na AWS vai importar bastante na Parte II.

### Calcule blocos CIDR com Python

O módulo `ipaddress`, da biblioteca padrão, é ótimo para conferir contas de CIDR sem papel e caneta:

```python
>>> import ipaddress
>>> casa = ipaddress.ip_network("192.168.0.0/24")
>>> casa.num_addresses
256
>>> ipaddress.ip_address("192.168.0.23") in casa
True
>>> ipaddress.ip_address("192.168.1.23") in casa
False
>>> ipaddress.ip_address("192.168.0.12").is_private
True
>>> ipaddress.ip_network("10.0.0.0/16").num_addresses
65536
>>> list(casa.subnets(new_prefix=26))
[IPv4Network('192.168.0.0/26'), IPv4Network('192.168.0.64/26'),
 IPv4Network('192.168.0.128/26'), IPv4Network('192.168.0.192/26')]
```

A última linha divide o `/24` da sua casa em quatro subnets de 64 endereços. É exatamente esse tipo de divisão que você vai fazer quando desenhar a rede do Rangô na AWS.

### Coloque o Rangô no celular

Com tudo isso, dá para fazer o Rangô funcionar pelo menos no seu celular, conectado ao mesmo Wi-Fi. Os dois estão na mesma subnet, então não há NAT nem roteador no meio. Só falta o bind.

Suba o backend escutando em todas as interfaces e liberando a origem do front acessado pelo IP:

```bash
cd backend
CORS_ORIGINS="http://localhost:5173,http://192.168.0.12:5173" \
  uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

No front, o Vite tem a opção `--host` para o mesmo fim:

```bash
cd frontend
npm run dev -- --host
```

```text
  VITE v6.x  ready in 312 ms

  ➜  Local:   http://localhost:5173/
  ➜  Network: http://192.168.0.12:5173/
```

Na primeira vez, o macOS ou o Windows podem perguntar se você quer permitir conexões de entrada para o Python ou o Node. Permita só para redes privadas.

Abra `http://192.168.0.12:5173` no celular. A página carrega, o título "Rangô" aparece... e a lista de restaurantes fica vazia.

Pare um instante e tente descobrir o motivo antes de ler a próxima linha.

O código React roda no navegador do celular. Quando ele executa `fetch("http://localhost:8000/restaurantes")`, o `localhost` é o próprio celular, onde não existe API nenhuma. É o mesmo erro do link que você mandou para a sua sócia, só que escondido dentro do código. O front precisa saber o endereço real da API. Crie o arquivo `frontend/.env.local`:

```bash
# frontend/.env.local
VITE_API_URL=http://192.168.0.12:8000
```

Reinicie o `npm run dev -- --host`, porque o Vite só lê as variáveis de ambiente na inicialização, e recarregue a página no celular. Os dois restaurantes aparecem.

Esse bug vai voltar, em outras formas, durante todo o livro. Qualquer endereço fixo no código é uma aposta sobre onde a aplicação vai rodar, e essa aposta quase sempre perde quando o código muda de máquina. Por isso o endereço da API e as origens do CORS vieram de variáveis de ambiente desde o começo.

E a sua sócia em Recife? Continua sem acesso. O seu notebook tem um IP privado, atrás de um NAT, talvez atrás de dois. Para ela alcançar o Rangô, ele precisa estar numa máquina com IP público, ligada o tempo todo, e não num notebook que você fecha para ir almoçar.

## Armadilhas e casos reais

### O `0.0.0.0` no lugar errado

Na sua rede de casa, fazer bind em `0.0.0.0` expõe o serviço para quem estiver no mesmo Wi-Fi, e o NAT do roteador barra o resto. Num servidor com IP público, não existe essa proteção. Escutar em `0.0.0.0` significa aceitar conexões da internet inteira, a menos que um firewall diga o contrário.

> **Na vida real:** no começo de janeiro de 2017, grupos de atacantes passaram a varrer a internet atrás de servidores MongoDB acessíveis publicamente e sem senha de administrador. Ferramentas de busca como o Shodan listavam dezenas de milhares deles. Os atacantes copiavam os dados, apagavam tudo e deixavam uma nota pedindo resgate em bitcoin. Em poucos dias, mais de 27 mil bancos tinham sido sequestrados. Em muitos casos, a causa era a mesma: o banco escutando em todas as interfaces de um servidor com IP público, sem autenticação e sem firewall na frente.

O PostgreSQL do Rangô, instalado localmente, escuta só em `localhost` por padrão, e é bom que continue assim. A pergunta "quem consegue chegar nesta porta?" deve ser feita para cada serviço, e a resposta para o banco de dados deveria ser "só a aplicação".

### O Docker que fura o firewall

> **Armadilha:** em Linux, publicar uma porta com `docker run -p 5432:5432 postgres` faz bind em `0.0.0.0` por padrão, e o Docker cria as próprias regras de firewall no `iptables`. Na prática, isso pode passar por cima de regras do `ufw` que você achava que estavam bloqueando a porta. Se o container só precisa ser acessado pela própria máquina, publique com `-p 127.0.0.1:5432:5432`.

Você vai conhecer containers a fundo no capítulo 3, mas essa armadilha vale ser conhecida desde já, porque muita gente sobe um Postgres em container no primeiro servidor alugado.

### Port forwarding como atalho

Liberar uma porta no roteador de casa para mostrar o app para alguém parece inofensivo. O problema é que, em poucos minutos, robôs que varrem a internet sem parar vão encontrar essa porta aberta e começar a testar o que há do outro lado. Um servidor de desenvolvimento com `--reload`, rotas de debug e sem autenticação é exatamente o que eles procuram. E, se você estiver atrás de CGNAT, o atalho nem funciona, o que pode ser uma sorte.

### Faixas privadas que colidem

> **Armadilha:** duas redes privadas podem usar a mesma faixa sem problema algum, até o dia em que precisam se conectar. Se a VPN da empresa usa `192.168.0.0/24` e a sua casa também, o notebook não sabe para qual lado mandar os pacotes para `192.168.0.10`. A tabela de rotas tem duas respostas para a mesma pergunta, e algum serviço some. Na nuvem, escolher faixas que não se sobreponham às redes da empresa e de outros ambientes economiza muita dor de cabeça futura. Esse assunto volta no capítulo 10.

### IPv6 e a falsa sensação de segurança

Com IPv6 há endereços de sobra, então cada dispositivo pode receber um endereço público e o NAT deixa de ser necessário. Isso também quer dizer que a barreira involuntária do NAT desaparece. Os roteadores domésticos modernos costumam bloquear conexões de entrada em IPv6 por padrão, mas o ponto importante é outro: quem protege um serviço é um firewall configurado de propósito, e não um efeito colateral da falta de endereços.

## Resumo

- `localhost` (`127.0.0.1`) aponta para a loopback, uma interface que nunca sai da máquina. Cada máquina tem o seu.
- Um endereço IP identifica uma interface de rede. O IPv4 tem 32 bits e está esgotado. O IPv6 tem 128 bits.
- A porta escolhe o processo dentro da máquina. IP, porta e caminho da URL resolvem máquina, processo e função.
- Fazer bind em `127.0.0.1` aceita só conexões locais. Em `0.0.0.0`, aceita por todas as interfaces.
- O TCP abre conexões com o handshake SYN, SYN-ACK, ACK e garante entrega em ordem. O UDP manda e esquece.
- Conexão recusada significa que a máquina respondeu, mas nada escuta na porta. Timeout significa que o pacote não chegou ou foi descartado.
- O roteamento acontece salto a salto. Vence a rota mais específica, e `0.0.0.0/0` é a rota padrão.
- IPs privados (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) não circulam na internet. O NAT traduz para um IP público e barra conexões de entrada não solicitadas. O CGNAT adiciona mais uma camada no provedor.
- No CIDR, o número depois da barra diz quantos bits são fixos. Um `/24` tem 256 endereços, e um `/16` tem 65.536.
- Uma subnet agrupa máquinas que se falam direto. Subnets públicas e privadas separam o que a internet pode alcançar.
- O Rangô agora roda no celular, na mesma rede, com o endereço da API vindo de `VITE_API_URL` e as origens do CORS vindo de `CORS_ORIGINS`.

## Próxima parada: um nome e um cadeado

Digamos que, num passe de mágica, o Rangô já estivesse rodando numa máquina com IP público, `203.0.113.45`. A sua sócia conseguiria acessar. Mas ela teria de digitar `http://203.0.113.45:5173` no navegador, e nenhum cliente faz pedido de comida digitando quatro números separados por pontos.

O que ela quer, e o que os clientes esperam, é digitar `rango.com.br` e ver um cadeado ao lado do endereço. Isso levanta duas perguntas novas. Como um nome vira um IP, se nenhum computador do caminho sabe o que é "rangô"? E, quando o navegador mostra o cadeado, quem garante que aquele site é mesmo o seu, e não o de alguém que interceptou a conexão no Wi-Fi da praça de alimentação? No próximo capítulo, vamos abrir o DNS e o TLS por dentro para responder a essas duas perguntas.

## Referências

- RFC 791, *Internet Protocol* (IPv4): https://www.rfc-editor.org/rfc/rfc791
- RFC 9293, *Transmission Control Protocol* (TCP): https://www.rfc-editor.org/rfc/rfc9293
- RFC 768, *User Datagram Protocol* (UDP): https://www.rfc-editor.org/rfc/rfc768
- RFC 1918, *Address Allocation for Private Internets*: https://www.rfc-editor.org/rfc/rfc1918
- RFC 4632, *Classless Inter-domain Routing* (CIDR): https://www.rfc-editor.org/rfc/rfc4632
- RFC 6598, faixa `100.64.0.0/10` para CGNAT: https://www.rfc-editor.org/rfc/rfc6598
- RFC 5737, endereços IPv4 reservados para documentação: https://www.rfc-editor.org/rfc/rfc5737
- Documentação do FastAPI: https://fastapi.tiangolo.com/
- Configurações do Uvicorn (`--host`, `--port`): https://www.uvicorn.org/settings/
- Variáveis de ambiente no Vite: https://vite.dev/guide/env-and-mode
- Módulo `ipaddress` do Python: https://docs.python.org/3/library/ipaddress.html
- Ataques de resgate a bancos MongoDB, janeiro de 2017 (The Register): https://www.theregister.com/2017/01/09/mongodb/
- Mesma onda de ataques (SiliconANGLE): https://siliconangle.com/2017/01/10/27000-mongodb-installs-hijacked-held-ransom/
