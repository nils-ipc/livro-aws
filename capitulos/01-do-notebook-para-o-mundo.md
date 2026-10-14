# Do notebook para o mundo

Você sabe escrever software. Sabe modelar um banco, desenhar uma API, montar uma interface em React, escrever testes que pegam bug antes do usuário. O que talvez você nunca tenha precisado fazer é a parte que acontece depois do `git push`: colocar aquilo no ar, manter no ar e descobrir por que caiu às 3h da manhã. Em muitas empresas, alguém do time de infraestrutura cuidava disso. Este livro é para o dia em que esse alguém não está lá.

O livro tem duas partes. Na primeira, com seis capítulos, você vai aprender o vocabulário e os conceitos de infraestrutura que a AWS pressupõe que você já conhece: redes, DNS, TLS, servidores, containers, escala, filas, backups, deploy, observabilidade. Sem AWS ainda. A ideia é que, quando você abrir o console pela primeira vez, as palavras na tela façam sentido. Na segunda parte, com dezoito capítulos, cada um desses conceitos volta, agora implementado com os serviços da AWS, em profundidade e com comandos de verdade.

O tempo todo, vamos trabalhar com um único projeto.

## Conheça o Rangô

O **Rangô** é um aplicativo de pedidos de comida. Restaurantes cadastram o cardápio, clientes fazem pedidos, o restaurante confirma, o entregador leva. Nada que você não conseguiria construir num fim de semana prolongado, e é justamente essa a graça: a aplicação é simples o bastante para não roubar a atenção, e realista o bastante para enfrentar os problemas de qualquer sistema em produção.

O Rangô tem duas partes:

- um backend em **FastAPI**, que expõe a API de cardápios e pedidos e conversa com um banco PostgreSQL;
- um frontend em **React**, criado com Vite, que consome essa API.

Hoje ele roda inteiro no seu notebook. A estrutura de pastas é esta:

```text
rango/
├── backend/
│   ├── app/
│   │   └── main.py
│   └── requirements.txt
└── frontend/
    ├── src/
    │   └── App.tsx
    └── package.json
```

O ponto de partida do backend é pequeno. Um endpoint de saúde e uma listagem de restaurantes, ainda com dados fixos em memória para simplificar:

```python
# backend/app/main.py
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="Rangô")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_methods=["*"],
    allow_headers=["*"],
)

RESTAURANTES = [
    {"id": 1, "nome": "Cantina da Nona", "categoria": "italiana"},
    {"id": 2, "nome": "Sabor do Sertão", "categoria": "nordestina"},
]


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/restaurantes")
def listar_restaurantes():
    return RESTAURANTES
```

E o frontend busca a lista assim:

```tsx
// frontend/src/App.tsx
import { useEffect, useState } from "react";

type Restaurante = { id: number; nome: string; categoria: string };

const API_URL = "http://localhost:8000";

export default function App() {
  const [restaurantes, setRestaurantes] = useState<Restaurante[]>([]);

  useEffect(() => {
    fetch(`${API_URL}/restaurantes`)
      .then((resp) => resp.json())
      .then(setRestaurantes);
  }, []);

  return (
    <ul>
      {restaurantes.map((r) => (
        <li key={r.id}>{r.nome}</li>
      ))}
    </ul>
  );
}
```

Para rodar, são dois terminais, como você já faz no dia a dia (os pré-requisitos são Python 3.12+ com `fastapi` e `uvicorn` instalados, e Node.js 20+):

```bash
# terminal 1
cd rango/backend
uvicorn app.main:app --reload

# terminal 2
cd rango/frontend
npm run dev
```

O Uvicorn avisa que a API está em `http://127.0.0.1:8000`, o Vite avisa que o frontend está em `http://localhost:5173`, você abre o navegador e lá estão a Cantina da Nona e o Sabor do Sertão. Funciona.

Ao longo do livro, esse projeto vai sair do seu notebook e terminar em produção na AWS, com banco gerenciado, containers, deploy automático, monitoramento e uma fatura que você entende. Mas tudo começa com uma pergunta bem mais simples.

## O link que não abre

Sua sócia no Rangô mora em Recife. Você mora em Porto Alegre. Ela quer ver o protótipo, e você manda no chat:

```text
Dá uma olhada: http://localhost:5173
```

Ela abre o link e o navegador responde com algo como "Não é possível acessar esse site. A conexão com localhost foi recusada." Ela manda um print. Você testa de novo aí do seu lado e funciona perfeitamente.

A explicação curta você provavelmente já conhece: `localhost` significa "esta máquina". Quando sua sócia abre `localhost:5173`, o navegador dela procura um programa ouvindo na porta 5173 do notebook dela, em Recife. Não há nenhum, e a conexão é recusada.

A explicação longa é o assunto deste capítulo. Porque a pergunta seguinte é inevitável: se `localhost` não serve, qual endereço eu mando? E aí as perguntas se multiplicam. Qual é o endereço do meu notebook? Por que o comando que mostra o meu IP dá um número e o site "qual é o meu IP" dá outro? Por que, mesmo com o número certo, ela continua sem acessar? Por que o Uvicorn diz `127.0.0.1` e o Vite diz `localhost`, e isso faz diferença?

Para responder, vamos acompanhar o caminho de uma requisição entre o navegador em Recife e o processo Python no seu notebook. Cada etapa tem um conceito de rede por trás, e todos eles voltam quando você criar sua primeira rede na AWS.

## Endereços: o IP

Toda máquina conectada a uma rede tem pelo menos um endereço. Na internet, esse endereço é o **IP** (de *Internet Protocol*). A versão mais comum ainda é o IPv4, que você já viu mil vezes: quatro números de 0 a 255 separados por pontos, como `192.168.0.15` ou `203.0.113.42`.

Cada um desses números ocupa 8 bits, então um endereço IPv4 tem 32 bits no total, o que dá cerca de 4,3 bilhões de endereços. Parecia muito na década de 1980. Hoje há mais celulares no mundo do que isso, e os endereços IPv4 acabaram há anos. O mundo encontrou dois remédios. O primeiro é o IPv6, com endereços de 128 bits (como `2001:db8::1`), que resolve a escassez de vez mas ainda convive com o IPv4 em quase toda a internet. O segundo é um truque chamado NAT, que você vai entender daqui a pouco e que explica boa parte da confusão do início do capítulo.

Por enquanto, guarde o seguinte: um IP identifica uma **interface de rede**, e uma mesma máquina pode ter vários. Seu notebook tem pelo menos dois:

- `127.0.0.1`, o endereço de **loopback**. Ele nunca sai da máquina. Qualquer pacote enviado para lá volta para o próprio computador, sem passar pela placa de rede. `localhost` é apenas um nome que aponta para esse endereço.
- O endereço da interface Wi-Fi ou cabeada, algo como `192.168.0.15`, que identifica seu notebook na rede da sua casa.

Com isso, o comportamento do Uvicorn se explica. Quando ele diz `Uvicorn running on http://127.0.0.1:8000`, está dizendo que só aceita conexões que chegam pela interface de loopback. Quem está dentro da sua máquina consegue falar com ele. Quem está fora, mesmo na mesma sala, não consegue.

## Portas: qual programa atende

O IP leva o pacote até a máquina certa. Mas numa máquina há dezenas de programas usando a rede ao mesmo tempo: o Uvicorn, o Vite, o PostgreSQL, o navegador, o cliente de chat. Como o sistema operacional sabe para qual deles entregar cada pacote que chega?

Pela **porta**. A porta é um número de 0 a 65535 que identifica um ponto de entrada dentro da máquina. Um programa que quer receber conexões pede ao sistema operacional para **ouvir** (*listen*) numa porta. A partir daí, tudo que chega naquele IP e naquela porta é entregue a ele.

No Rangô, você tem três portas em uso:

| Porta | Programa | Quem conversa com ele |
|-------|----------|----------------------|
| 8000 | Uvicorn (API FastAPI) | O frontend, pelo navegador |
| 5173 | Vite (servidor de desenvolvimento do React) | O navegador |
| 5432 | PostgreSQL | O backend |

Pense no IP como o endereço de um prédio e na porta como o número do apartamento. A analogia de desenvolvedor também funciona: o IP escolhe o servidor, a porta escolhe o processo, e o caminho da URL (`/restaurantes`) escolhe a função dentro do processo, que é o trabalho do roteador do FastAPI.

Algumas portas têm dono por convenção. HTTP usa 80, HTTPS usa 443, SSH usa 22, PostgreSQL usa 5432. É por isso que você digita `https://github.com` e não `https://github.com:443`: o navegador presume a porta padrão do protocolo. Portas abaixo de 1024 são chamadas de **portas privilegiadas**, e em Linux e macOS um programa comum precisa de permissão especial para ouvir nelas. Esse detalhe vai voltar no capítulo 3, quando colocarmos um proxy reverso na frente da API.

Repare numa coisa: a combinação de IP e porta precisa estar livre. Se você tentar subir um segundo Uvicorn na porta 8000, ele falha com `[Errno 48] Address already in use` no macOS (ou `[Errno 98]` no Linux). Esse erro você provavelmente já viu. Agora sabe o que ele quer dizer: outro processo já está ouvindo naquele IP e naquela porta.

## TCP e UDP: como a conversa acontece

Saber o endereço e a porta resolve o "para onde". Falta o "como". Na internet, os dados viajam em pedaços chamados **pacotes**, e cada pacote é tratado de forma independente. Pacotes podem se perder, chegar fora de ordem ou chegar duplicados. Alguém precisa lidar com isso, e na maior parte dos casos esse alguém é o **TCP** (*Transmission Control Protocol*).

O TCP cria uma **conexão** entre os dois lados antes de enviar qualquer dado. Essa abertura é o famoso *three-way handshake*:

```text
navegador                          servidor (porta 8000)
    |  ---- SYN ------------------->  |   "quero conversar"
    |  <--- SYN-ACK ----------------  |   "pode falar, também quero"
    |  ---- ACK ------------------->  |   "combinado"
    |                                 |
    |  ---- GET /restaurantes ----->  |   agora sim, o HTTP
    |  <--- 200 OK + JSON ----------  |
```

Depois disso, o TCP numera cada pedaço enviado, confirma o que chegou, reenvia o que se perdeu e entrega tudo ao programa na ordem certa. Para o FastAPI, a requisição chega inteira e organizada. Ele nunca fica sabendo que um pacote se perdeu no meio do caminho e precisou ser reenviado.

Lembra a mensagem "A conexão com localhost foi recusada"? Ela vem daqui. O navegador da sua sócia mandou um SYN para a porta 5173 da máquina dela, e o sistema operacional respondeu com um pacote de recusa (um RST), porque nenhum programa ouvia ali. Uma conexão recusada é uma resposta rápida e clara: a máquina existe, mas a porta está fechada. Guarde essa diferença, porque existe outro erro, o *timeout*, que significa algo bem diferente e vai aparecer na seção de armadilhas.

O outro protocolo de transporte importante é o **UDP** (*User Datagram Protocol*). Ele não faz handshake, não confirma entrega e não reordena nada. Serve quando a resposta é pequena e rápida, ou quando um dado atrasado já perdeu o valor. As consultas de DNS usam UDP na maior parte do tempo, e chamadas de vídeo também, porque um quadro que chega meio segundo atrasado já não serve para nada. O HTTP/3 roda sobre o QUIC, um protocolo construído em cima do UDP que reimplementa as garantias que interessam.

Para o Rangô, por enquanto, tudo é TCP: HTTP do navegador para a API, e a conexão da API com o PostgreSQL. Quando você configurar regras de firewall na AWS, vai precisar escolher entre TCP e UDP para cada porta liberada, e agora você sabe o que está escolhendo.

## Roteamento: o caminho até o destino

Seu notebook sabe o IP de destino. Mas ele não tem um cabo ligado diretamente a cada computador do mundo. Como o pacote chega lá?

Passando de mão em mão. Cada equipamento no caminho é um **roteador**, e cada roteador tem uma **tabela de rotas** que responde a uma única pergunta: "para chegar a este destino, para quem eu entrego o pacote agora?". O roteador não conhece o caminho inteiro. Ele só conhece o próximo salto. O seguinte decide o salto depois, e assim por diante, até o pacote chegar à rede do destino.

Seu notebook também tem uma tabela de rotas, e ela é curtíssima. Na prática, diz duas coisas: "endereços da minha rede local eu entrego direto" e "todo o resto eu mando para o **gateway padrão**". O gateway padrão, numa casa, é o roteador Wi-Fi que a operadora instalou.

Se você já escreveu rotas no FastAPI, a lógica da tabela vai parecer familiar. O roteador compara o destino do pacote com as rotas que conhece e escolhe a **mais específica** que combina, do mesmo jeito que um framework web prefere `/restaurantes/destaques` a `/restaurantes/{id}` quando os dois casam com a URL. Essa regra se chama *longest prefix match*. A rota menos específica de todas, a que casa com qualquer destino, é a rota padrão, escrita como `0.0.0.0/0`. Ela é o `catch-all` da rede. Essa notação com barra vai ficar clara em algumas páginas, e `0.0.0.0/0` vai aparecer em praticamente toda configuração de rede que você fizer na AWS.

Cada salto acrescenta um pouco de tempo. Um pacote do Brasil para um servidor na Virgínia, nos Estados Unidos, costuma levar mais de 100 milissegundos para ir e voltar, o que vai pesar na escolha de região quando chegarmos à AWS.

## IP público, IP privado e o truque do NAT

Agora a parte que explica a confusão do começo. Rode no seu notebook um comando para ver o IP da interface Wi-Fi (os comandos exatos estão na seção prática, logo adiante). Você vai ver algo como `192.168.0.15`. Depois abra um site que mostra "qual é o seu IP". Ele vai mostrar outro número, algo como `203.0.113.42`. Qual dos dois é o seu IP?

Os dois, em contextos diferentes.

Lembra que os endereços IPv4 acabaram? Uma das soluções foi reservar algumas faixas de endereços para uso **privado**, dentro de redes locais. Esses endereços podem ser repetidos à vontade em redes diferentes, porque nunca aparecem na internet pública. As faixas, definidas na RFC 1918, são três:

| Faixa | Tamanho | Onde você costuma ver |
|-------|---------|----------------------|
| `10.0.0.0` a `10.255.255.255` | cerca de 16,7 milhões de endereços | Redes corporativas e redes na nuvem |
| `172.16.0.0` a `172.31.255.255` | cerca de 1 milhão | Redes do Docker, algumas empresas |
| `192.168.0.0` a `192.168.255.255` | 65.536 | Roteadores domésticos |

O `192.168.0.15` do seu notebook é um **IP privado**. Milhões de notebooks no mundo têm exatamente esse mesmo endereço neste momento, cada um na sua própria rede doméstica. O IP que o site mostrou é um **IP público**: único na internet inteira, atribuído pela sua operadora ao seu roteador.

Então como o seu notebook, com um endereço que só vale dentro de casa, consegue abrir um site? Quem resolve isso é o roteador, com o **NAT** (*Network Address Translation*). Quando um pacote sai da sua rede, o roteador troca o IP de origem privado pelo IP público dele e anota a troca numa tabela. Quando a resposta volta, ele consulta a tabela e devolve o pacote ao notebook certo.

A tabela de NAT parece um dicionário Python:

```text
lado de dentro (privado)       lado de fora (público)        destino
192.168.0.15:51234        ->   203.0.113.42:40001       ->   140.82.112.3:443
192.168.0.22:49876        ->   203.0.113.42:40002       ->   140.82.112.3:443
192.168.0.15:51240        ->   203.0.113.42:40003       ->   151.101.1.69:443
```

Repare que dois aparelhos da casa podem acessar o mesmo site ao mesmo tempo, e o roteador os diferencia pela porta pública que escolheu para cada conexão. Para o mundo lá fora, existe uma única máquina em `203.0.113.42` fazendo muitas conexões.

O NAT tem uma consequência que responde à pergunta do capítulo. Ele funciona muito bem para conexões que **saem** da rede, porque o roteador cria a anotação na tabela quando o pacote sai. Uma conexão que **chega** de fora, sem ninguém ter pedido, não encontra anotação nenhuma. Quando sua sócia tenta se conectar a `203.0.113.42:5173`, o roteador recebe o pacote e não sabe para qual aparelho da casa entregá-lo. Então descarta.

Isso é ótimo para a segurança da sua rede doméstica e péssimo para quem quer mostrar um protótipo. É possível configurar o roteador para encaminhar uma porta específica para um aparelho interno (o *port forwarding*), mas há um obstáculo cada vez mais comum no Brasil, que veremos nas armadilhas.

Um aviso sobre os exemplos: os IPs públicos deste livro, como `203.0.113.42` e `198.51.100.7`, pertencem a faixas reservadas para documentação. Eles não pertencem a ninguém e servem justamente para exemplos.

## Subnets e CIDR: dividindo endereços em blocos

Quando falamos de "a sua rede doméstica", estamos falando de uma **subnet** (sub-rede): um bloco contínuo de endereços IP cujas máquinas conseguem se falar diretamente, sem passar por um roteador. Seu roteador Wi-Fi provavelmente usa o bloco de `192.168.0.0` a `192.168.0.255`. Todo aparelho com IP nesse intervalo está "na mesma rede".

Para escrever esses blocos de forma compacta, usa-se a notação **CIDR** (*Classless Inter-Domain Routing*). O bloco acima vira `192.168.0.0/24`. O número depois da barra diz quantos bits, da esquerda para a direita, são fixos. Os bits restantes variam e formam os endereços dentro do bloco.

Se você já trabalhou com máscaras de bits, a ideia é a mesma. Um IPv4 tem 32 bits. Em `/24`, os primeiros 24 bits (os três primeiros números, `192.168.0`) são fixos, e os últimos 8 bits variam: 2⁸ = 256 endereços. Cada bit a menos na barra dobra o tamanho do bloco:

| CIDR | Bits livres | Endereços | Exemplo |
|------|-------------|-----------|---------|
| `/32` | 0 | 1 | Um único IP, como `203.0.113.42/32` |
| `/28` | 4 | 16 | Uma subnet bem pequena |
| `/24` | 8 | 256 | Uma rede doméstica típica |
| `/16` | 16 | 65.536 | Uma rede inteira de uma empresa ou na nuvem |
| `/0` | 32 | todos | A internet inteira, `0.0.0.0/0` |

A rota padrão da seção anterior fica clara: `0.0.0.0/0` é o bloco com zero bits fixos, que contém todos os endereços IPv4. Na outra ponta, `/32` fixa todos os bits e representa um único IP. Quando você estiver configurando um firewall na AWS e quiser liberar o acesso só para o IP do seu escritório, vai escrever algo como `203.0.113.42/32`. Quando escrever `0.0.0.0/0`, está liberando para o planeta.

Dentro de uma subnet, nem todo endereço pode ir para uma máquina. Tradicionalmente, o primeiro endereço identifica a própria rede e o último é o de *broadcast* (enviar para todos). A AWS reserva ainda mais: cinco endereços em cada subnet. Por isso uma subnet `/24` na AWS tem 251 endereços utilizáveis, e não 256. Detalhes como esse vão importar no capítulo 10.

Por que dividir endereços em subnets? Porque subnets são a unidade de organização e de isolamento de uma rede. Você pode decidir que uma subnet tem rota para a internet e outra não, e colocar o banco de dados na segunda. É exatamente isso que faremos com o Rangô na AWS: uma rede `/16` dividida em subnets menores, algumas públicas e outras privadas. Por enquanto, basta saber ler a notação.

## Mão na massa: investigando a rede do seu notebook

Chega de teoria. Vamos ver tudo isso acontecendo na sua máquina. Os comandos abaixo funcionam no macOS e no Linux; quando forem diferentes, os dois aparecem. No Windows, use o WSL para acompanhar.

### Descobrindo seus IPs

O IP privado da interface Wi-Fi:

```bash
# macOS (en0 costuma ser o Wi-Fi)
ipconfig getifaddr en0

# Linux
ip -4 addr show
```

Saída típica no macOS:

```text
192.168.0.15
```

O IP público, visto de fora:

```bash
curl https://checkip.amazonaws.com
```

```text
203.0.113.42
```

Esse endpoint, mantido pela própria AWS, devolve apenas o IP de onde a requisição veio. Se os dois números forem diferentes (e quase sempre são), você acabou de ver o NAT em ação.

### Quem está ouvindo em cada porta

Com o backend e o frontend do Rangô rodando, pergunte ao sistema quais processos estão ouvindo:

```bash
# macOS e Linux
lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(8000|5173|5432)'
```

```text
Python    41822 voce   3u  IPv4 0x...  0t0  TCP 127.0.0.1:8000 (LISTEN)
node      41907 voce  23u  IPv6 0x...  0t0  TCP [::1]:5173 (LISTEN)
postgres    812 voce   7u  IPv4 0x...  0t0  TCP 127.0.0.1:5432 (LISTEN)
```

A coluna que interessa é a do endereço. O Uvicorn ouve em `127.0.0.1:8000`, o loopback IPv4. O Vite ouve em `[::1]:5173`, que é o loopback do IPv6 (dependendo da versão do Node e do sistema, pode aparecer `127.0.0.1`). O PostgreSQL, instalado com a configuração padrão, também só ouve no loopback. Todos os três estão acessíveis apenas de dentro do notebook. Essa configuração padrão é proposital: ferramentas de desenvolvimento escolhem o loopback para que você não exponha nada por acidente.

### Abrindo a API para a rede local

Para que outros aparelhos da sua casa acessem a API, o Uvicorn precisa ouvir em todas as interfaces, e não só no loopback. O endereço especial para isso é `0.0.0.0`, que no contexto de um servidor significa "qualquer interface desta máquina":

```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Confira de novo com `lsof`, e o endereço terá mudado para `*:8000`. Agora pegue o celular, conectado ao mesmo Wi-Fi, e abra `http://192.168.0.15:8000/health` (com o IP do seu notebook). A resposta `{"status":"ok"}` aparece na tela. No macOS, pode surgir uma janela do firewall perguntando se o Python pode aceitar conexões de entrada. Ela é o firewall do próprio sistema fazendo o trabalho dele.

Faça o mesmo com o frontend. O Vite aceita a opção `--host` para ouvir em todas as interfaces:

```bash
npm run dev -- --host
```

Ele vai listar um endereço `Network`, como `http://192.168.0.15:5173/`. Abra no celular. A página carrega, mas a lista de restaurantes fica vazia.

Por quê? Releia o `App.tsx`: a URL da API é `http://localhost:8000`. O código React roda **no navegador do celular**, e para o celular, `localhost` é o próprio celular. O `fetch` vai bater na porta 8000 do telefone, onde não há nada. É o mesmo erro da sua sócia em Recife, só que agora escondido dentro do código.

Para corrigir, a URL da API precisa vir de configuração, e não ficar fixa no código. O Vite lê variáveis de ambiente que começam com `VITE_`:

```tsx
// frontend/src/App.tsx
const API_URL = import.meta.env.VITE_API_URL ?? "http://localhost:8000";
```

```bash
# frontend/.env.local
VITE_API_URL=http://192.168.0.15:8000
```

E o backend precisa aceitar a nova origem no CORS, também por variável de ambiente:

```python
# backend/app/main.py
import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="Rangô")

ORIGENS = os.getenv("CORS_ORIGINS", "http://localhost:5173").split(",")

app.add_middleware(
    CORSMiddleware,
    allow_origins=ORIGENS,
    allow_methods=["*"],
    allow_headers=["*"],
)
```

```bash
CORS_ORIGINS="http://localhost:5173,http://192.168.0.15:5173" \
  uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Reinicie o Vite para ele ler o `.env.local`, recarregue a página no celular, e a Cantina da Nona aparece. A mudança é pequena, mas acompanha o Rangô até o fim do livro: em cada lugar onde o código rodar, a URL da API e as origens permitidas serão diferentes.

### Testando uma porta sem navegador

O `nc` (netcat) tenta abrir uma conexão TCP e diz se conseguiu. É o jeito mais rápido de separar "o problema é a rede" de "o problema é a aplicação":

```bash
nc -zv 192.168.0.15 8000
```

```text
Connection to 192.168.0.15 port 8000 [tcp/irdmi] succeeded!
```

Agora derrube o Uvicorn e repita. A resposta muda para `Connection refused`. A máquina respondeu, só que ninguém atende na porta. Você vai usar esse teste muitas vezes na Parte II, quando um servidor na AWS não responder e for preciso descobrir se a culpa é da aplicação ou de uma regra de firewall.

### Olhando a tabela de rotas e os saltos

A tabela de rotas do notebook:

```bash
# macOS
netstat -rn -f inet | head -n 5

# Linux
ip route
```

No Linux, a saída costuma ser curta assim:

```text
default via 192.168.0.1 dev wlp2s0 proto dhcp metric 600
192.168.0.0/24 dev wlp2s0 proto kernel scope link src 192.168.0.15
```

Leia linha a linha. A segunda diz que a subnet `192.168.0.0/24` é entregue diretamente pela interface Wi-Fi. A primeira é a rota padrão: todo o resto vai para `192.168.0.1`, o roteador da casa. Duas linhas, e o seu notebook já sabe chegar a qualquer lugar da internet.

Para ver os saltos até um destino, use o `traceroute` (no Linux, pode ser preciso instalar o pacote `traceroute`):

```bash
traceroute -n checkip.amazonaws.com
```

```text
 1  192.168.0.1      2.1 ms   1.8 ms   1.9 ms
 2  100.64.12.1      9.4 ms   8.7 ms   9.1 ms
 3  * * *
 4  198.51.100.17   14.2 ms  13.9 ms  14.5 ms
 ...
14  203.0.113.200  131.6 ms 129.8 ms 130.4 ms
```

O primeiro salto é o seu roteador. Os seguintes são da sua operadora e das redes por onde o pacote passa. Os asteriscos indicam roteadores que não respondem a esse tipo de sonda, o que é comum e não significa problema. Repare no tempo crescendo até passar de 100 ms: é a viagem até os Estados Unidos, onde esse serviço provavelmente está respondendo. E repare no segundo salto, com um endereço começando em `100.64`. Ele vai ser importante daqui a pouco.

### Fazendo contas de CIDR com Python

Você não precisa fazer contas de bits de cabeça. A biblioteca padrão do Python tem o módulo `ipaddress`:

```python
import ipaddress

rede = ipaddress.ip_network("192.168.0.0/24")
print(rede.num_addresses)          # 256
print(rede[0], rede[-1])           # 192.168.0.0 192.168.0.255

print(ipaddress.ip_address("192.168.0.15") in rede)  # True
print(ipaddress.ip_address("192.168.1.15") in rede)  # False

print(ipaddress.ip_address("192.168.0.15").is_private)  # True
print(ipaddress.ip_address("8.8.8.8").is_private)       # False

# dividir uma rede /16 em subnets /24, como faremos na AWS
vpc = ipaddress.ip_network("10.0.0.0/16")
subnets = list(vpc.subnets(new_prefix=24))
print(len(subnets))                # 256
print(subnets[0], subnets[1])      # 10.0.0.0/24 10.0.1.0/24
```

Guarde esse trecho. Quando você estiver planejando as subnets do Rangô na AWS e se perguntar se dois blocos se sobrepõem, o método `overlaps` deste mesmo módulo responde em uma linha.

### E a sócia em Recife?

Com tudo isso, você consegue mostrar o Rangô para quem está na sua casa. Para quem está em Recife, ainda falta passar pelo NAT do seu roteador. Você teria de configurar port forwarding, torcer para a operadora não estar no seu caminho (veja a próxima seção) e manter o notebook ligado, acordado e na mesma rede o tempo todo. Existem serviços de túnel que criam uma URL pública apontando para uma porta do seu notebook, e eles servem para uma demonstração rápida. Para um app de verdade, a resposta é outra: colocar o Rangô numa máquina que tenha um IP público, fique ligada o tempo todo e não durma quando você fecha a tampa. Essa máquina vai existir no capítulo 9, já na AWS.

## Armadilhas e casos reais

### `0.0.0.0` em qualquer rede

Subir o Uvicorn com `--host 0.0.0.0` é a coisa certa dentro de um container ou de um servidor (vamos fazer isso muitas vezes). No notebook, num café ou num aeroporto, significa que qualquer pessoa conectada ao mesmo Wi-Fi pode acessar a sua API de desenvolvimento, incluindo a documentação automática em `/docs`, que lista todos os endpoints. Se o seu backend local tem algum endpoint de administração sem autenticação "porque é só local", ele deixou de ser só local.

> **Dica:** use `0.0.0.0` apenas quando precisar, e volte para o padrão (`127.0.0.1`) quando terminar o teste. Se o objetivo é acessar só pelo celular, o firewall do sistema operacional pode restringir quem se conecta.

### O banco de dados que ouvia a internet inteira

O mesmo raciocínio vale para servidores, com consequências bem maiores. Um banco de dados configurado para ouvir em todas as interfaces, numa máquina com IP público e sem firewall, está aceitando conexões do planeta. Robôs varrem a internet o tempo todo procurando exatamente isso, testando portas conhecidas como 5432 (PostgreSQL), 3306 (MySQL), 6379 (Redis) e 27017 (MongoDB).

> **Na vida real:** em janeiro de 2017, milhares de instalações de MongoDB expostas na internet sem autenticação foram apagadas por atacantes, que deixavam no lugar uma nota pedindo resgate em bitcoin. Em poucos dias, o número de bancos afetados passou de 27 mil, segundo pesquisadores que acompanhavam os ataques. Ninguém invadiu nada de forma sofisticada: os bancos estavam ouvindo em um IP público, sem senha, e os atacantes simplesmente se conectaram.

Essa história vai reaparecer no capítulo 10, que abre justamente com o banco do Rangô acessível pela internet inteira. A solução terá a ver com as subnets privadas que você acabou de conhecer.

### Connection refused e timeout são problemas diferentes

Quando uma conexão falha, a mensagem de erro diz muito sobre onde está o problema:

- **Connection refused**: o pacote chegou à máquina, e ela respondeu que ninguém ouve naquela porta. O processo caiu, está em outra porta ou está ouvindo só no loopback.
- **Timeout**: o pacote não teve resposta nenhuma. Algo no caminho descartou o pacote em silêncio. Pode ser um firewall, um NAT sem regra de encaminhamento ou uma rota errada.

Na AWS, o timeout é o sintoma clássico de uma regra de firewall faltando. Quem não conhece essa diferença costuma passar uma hora mexendo no código da aplicação quando o problema está na rede.

### O IP público compartilhado com os vizinhos

Lembra do segundo salto do `traceroute`, com endereço começando em `100.64`? Essa faixa, `100.64.0.0/10`, é reservada para um tipo de NAT feito pela operadora, o **CGNAT** (*Carrier-Grade NAT*). Como as operadoras também não têm IPv4 público para todos os clientes, muitas colocam centenas de casas atrás de um mesmo IP público, com mais uma camada de NAT na rede delas. No Brasil, isso é bastante comum em internet residencial e quase universal na rede móvel.

Com CGNAT, o IP que aparece no `checkip.amazonaws.com` pertence à operadora e é compartilhado com seus vizinhos. Configurar port forwarding no seu roteador não adianta nada, porque o NAT que bloqueia a entrada está na operadora, fora do seu alcance.

> **Armadilha:** liberar acesso a um servidor apenas para o IP público da sua casa parece seguro, mas com CGNAT esse IP é de muitas outras pessoas e pode mudar sem aviso. Na Parte II, vamos ver formas de acessar servidores sem depender do seu IP.

### `localhost` no código do frontend

Toda URL fixa no código React é avaliada no navegador de quem usa o app, então `localhost` no frontend significa o computador do usuário. Esse erro costuma passar despercebido no desenvolvimento e aparecer no primeiro deploy, quando o site em produção tenta chamar `http://localhost:8000` e o console do navegador se enche de erros de conexão. Configuração por variável de ambiente, desde o primeiro dia, evita a surpresa.

## Resumo

- `localhost` e `127.0.0.1` apontam para a própria máquina. Um link com `localhost` só funciona para quem o abre no mesmo computador.
- O IP identifica uma interface de rede; a porta identifica o processo que atende. IPv4 tem 32 bits e os endereços acabaram, o que levou ao IPv6 e ao NAT.
- Um servidor ouvindo em `127.0.0.1` só aceita conexões locais. Em `0.0.0.0`, aceita por qualquer interface, com os riscos que isso traz.
- TCP abre uma conexão com handshake e garante entrega e ordem. UDP manda e não confirma, e serve a DNS, vídeo e HTTP/3.
- Roteadores encaminham pacotes salto a salto, escolhendo a rota mais específica. A rota padrão é `0.0.0.0/0`.
- IPs privados (RFC 1918) valem só dentro de uma rede. O NAT os traduz para um IP público na saída e bloqueia conexões não solicitadas na entrada. CGNAT repete o truque na operadora.
- CIDR descreve blocos de endereços: `/24` tem 256 endereços, `/16` tem 65.536, `/32` é um único IP. Subnets organizam e isolam redes.
- Connection refused indica que a máquina respondeu e a porta está fechada; timeout indica que algo no caminho descartou o pacote.
- O Rangô agora lê a URL da API (`VITE_API_URL`) e as origens de CORS (`CORS_ORIGINS`) de variáveis de ambiente.

## Próxima parada: um nome em vez de um número

O Rangô agora abre no celular, desde que o celular esteja na sua casa e você mande um endereço como `http://192.168.0.15:5173`. Mesmo quando ele estiver num servidor com IP público, o link que você mandar para os clientes vai ser algo como `http://203.0.113.42:8000`. Ninguém decora isso, ninguém confia nisso, e o navegador ainda vai exibir, bem ao lado do endereço, um aviso de "Não seguro".

O que você quer, claro, é que o cliente digite `rango.com.br` e o cardápio apareça, com o cadeado ao lado do endereço. Como um nome vira um IP? Quem garante que o `rango.com.br` que o cliente acessou é mesmo o seu, e não o de alguém no meio do caminho lendo os pedidos e os dados de pagamento? Essas duas perguntas, uma sobre DNS e outra sobre TLS, são o assunto do próximo capítulo.

## Referências

- RFC 791, Internet Protocol: <https://www.rfc-editor.org/rfc/rfc791>
- RFC 9293, Transmission Control Protocol (TCP): <https://www.rfc-editor.org/rfc/rfc9293>
- RFC 768, User Datagram Protocol: <https://www.rfc-editor.org/rfc/rfc768>
- RFC 9000, QUIC: <https://www.rfc-editor.org/rfc/rfc9000>
- RFC 1918, Address Allocation for Private Internets: <https://www.rfc-editor.org/rfc/rfc1918>
- RFC 4632, Classless Inter-domain Routing (CIDR): <https://www.rfc-editor.org/rfc/rfc4632>
- RFC 6598, faixa compartilhada `100.64.0.0/10` para CGNAT: <https://www.rfc-editor.org/rfc/rfc6598>
- RFC 5737, faixas de IPv4 reservadas para documentação: <https://www.rfc-editor.org/rfc/rfc5737>
- Documentação do módulo `ipaddress` do Python: <https://docs.python.org/3/library/ipaddress.html>
- Configurações do Uvicorn (`--host`, `--port`): <https://www.uvicorn.org/settings/>
- Opções do servidor do Vite (`server.host`): <https://vite.dev/config/server-options>
- Variáveis de ambiente no Vite: <https://vite.dev/guide/env-and-mode>
- Endereços reservados em subnets da AWS: <https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html>
- CSO Online, sobre os ataques de resgate a MongoDB expostos em 2017: <https://www.csoonline.com/article/3154190/exposed-mongodb-installs-being-erased-held-for-ransom.html>
