# DNS, HTTPS e TLS

No capítulo anterior, você seguiu uma requisição do celular até o processo do Uvicorn: endereço IP para achar a máquina, porta para achar o processo, TCP para manter a conversa em ordem, roteamento salto a salto e o NAT barrando quem chega de fora sem ser chamado. No fim, o Rangô rodava no seu notebook e abria no seu celular, pela rede de casa, e a sua sócia em Recife continuava sem acesso. Ficamos com uma máquina imaginária de IP público, `203.0.113.45`, e com duas perguntas: como um nome vira esse número, e quem garante que o site com cadeado é mesmo o seu.

## Quatro números e um aviso vermelho

Volte à máquina mágica com IP público. Você manda o link para a sua sócia, `http://203.0.113.45:5173`, e funciona. Ela mostra para o dono da Cantina da Nona, que gosta e pergunta qual endereço divulgar no cardápio. Não dá para imprimir aquilo num folheto.

E há um problema menos visível: na barra de endereços aparece "Não seguro". O Chrome marca assim qualquer página em HTTP puro desde 2018. O dono da cantina não sabe o que isso quer dizer, mas não vai digitar o número do cartão numa página que o próprio navegador chama de insegura.

E o aviso tem fundamento. Uma requisição HTTP viaja em texto puro. No Wi-Fi aberto de uma praça de alimentação, qualquer pessoa na mesma rede, com um programa gratuito de captura de pacotes, lê o endereço de entrega, o token de sessão e a senha do login. E quem controla o roteador do shopping pode trocar o JavaScript do Rangô por outro, que o navegador vai executar sem reclamar.

Então são dois problemas, e eles se resolvem com duas peças separadas. O DNS transforma `rango.com.br` em `203.0.113.45`. O TLS, a camada que transforma HTTP em HTTPS, cifra a conversa e prova que quem responde em `rango.com.br` é mesmo o dono desse nome. Vamos ver uma de cada vez.

## DNS: a agenda de contatos da internet

O *DNS* (*Domain Name System*) é o sistema que traduz nomes em endereços. A analogia mais próxima é a agenda do celular: você procura "Mãe" e o telefone disca o número. Só que essa agenda tem bilhões de entradas, muda o tempo todo e não pode ficar num lugar só, porque ninguém aguentaria responder às consultas do planeta inteiro.

A solução foi distribuir a agenda numa hierarquia. Leia o nome de trás para a frente: `rango.com.br.` (sim, com um ponto no final, que normalmente fica oculto). O ponto final é a **raiz**. Abaixo dela vem `br`, o domínio de topo do Brasil. Abaixo de `br` vem `com.br`, e abaixo dele vem `rango`. Cada nível sabe apenas quem cuida do nível de baixo. Os servidores da raiz não fazem ideia de qual é o IP do Rangô, mas sabem quem responde por `br`. Os servidores de `br`, mantidos pelo Registro.br, sabem quem responde por `rango.com.br`. E esse último servidor, escolhido por você, sabe o IP.

Essa ideia de "eu não sei, mas sei quem sabe" se chama **delegação**, e é ela que permite que a agenda cresça sem um dono central.

### Quem faz as perguntas: o resolver

O navegador da sua sócia não sai perguntando para a raiz por conta própria. Ele pede ajuda ao sistema operacional, que repassa a pergunta para um **resolver recursivo**. Normalmente é um servidor do provedor de internet, configurado automaticamente quando o celular entra na rede. Também pode ser um resolver público, como o `1.1.1.1` da Cloudflare ou o `8.8.8.8` do Google.

O resolver faz o trabalho pesado. Ao receber a pergunta "qual é o IP de `rango.com.br`?", ele segue a cadeia:

1. Pergunta a um servidor raiz. A resposta é: "não sei, mas `br` está com estes servidores aqui", seguida de uma lista como `a.dns.br`, `b.dns.br` e outros.
2. Pergunta a um servidor de `br`. A resposta é: "não sei o IP, mas `rango.com.br` está delegado para `ns1.provedor-dns.example` e `ns2.provedor-dns.example`".
3. Pergunta a um desses servidores. Esse sabe: "`rango.com.br` é `203.0.113.45`".
4. Devolve a resposta ao celular e guarda uma cópia.

O servidor do passo 3 é o **servidor autoritativo** do domínio: ele não repassa nada, responde com autoridade sobre a zona que lhe pertence. A **zona** é o conjunto de registros de um domínio, mais ou menos como uma tabela no banco: cada linha diz que tal nome, de tal tipo, tem tal valor. Quem edita essa tabela é você, pelo painel do provedor de DNS que escolheu.

A raiz tem 13 nomes de servidores, de `a.root-servers.net` a `m.root-servers.net`, e cada um responde de muitos lugares do mundo ao mesmo tempo com *anycast*: o mesmo IP anunciado em vários pontos, e o roteamento leva cada pacote ao mais próximo. São mais de mil instâncias no total.

Quanto ao transporte, a consulta típica é um pacote UDP para a porta 53 e outro de volta, sem handshake. Respostas grandes demais são repetidas por TCP, na mesma porta.

### TTL: o prazo de validade da resposta

Se todo acesso disparasse a cadeia inteira, a raiz e os servidores de `br` estariam soterrados. O que salva o sistema é o cache. Cada resposta vem com um **TTL** (*Time To Live*), em segundos, que diz por quanto tempo ela pode ser reaproveitada. Com TTL de 3600, o resolver do provedor da sua sócia responde com a cópia guardada durante uma hora, sem consultar ninguém. Pense no `max_age` de um decorator de cache em Python. E há várias camadas de cache no caminho (navegador, sistema operacional, resolver), cada uma contando o próprio relógio.

Isso explica a famosa "propagação de DNS". Quando você muda o IP de um domínio, nada se propaga: a mudança vale na hora no servidor autoritativo. As cópias antigas, espalhadas por resolvers do mundo inteiro, só expiram quando o TTL delas vence.

### Os tipos de registro que você vai usar

Cada linha da zona tem um tipo. Existem dezenas, mas o Rangô vai precisar de poucos:

| Tipo | O que diz | Exemplo no Rangô |
|------|-----------|------------------|
| `A` | Nome aponta para um IPv4 | `rango.com.br` → `203.0.113.45` |
| `AAAA` | Nome aponta para um IPv6 | `rango.com.br` → `2001:db8::45` |
| `CNAME` | Nome é um apelido de outro nome | `www.rango.com.br` → `rango.com.br` |
| `MX` | Servidores que recebem e-mail do domínio | `rango.com.br` → `10 mx.provedor-email.example` |
| `TXT` | Texto livre, usado para verificações | prova de posse do domínio para uma autoridade certificadora |
| `NS` | Quais servidores são autoritativos | `rango.com.br` → `ns1.provedor-dns.example` |

O `CNAME` merece um parágrafo. Ele diz "para saber o valor deste nome, vá perguntar por aquele outro". É como um alias de import em Python: `www.rango.com.br` vira só outro nome para `rango.com.br`. Ele tem uma restrição que pega muita gente. Um nome com `CNAME` não pode ter nenhum outro registro, e o domínio raiz (o `rango.com.br` sem prefixo, chamado de *apex*) sempre precisa ter registros `NS` e `SOA`. Resultado: você não pode colocar um `CNAME` no apex. Os provedores de DNS criaram soluções próprias para contornar isso, e a AWS tem a dela, que você vai conhecer no capítulo 14.

O `TXT` é o canal pelo qual você prova a terceiros que controla um domínio: eles pedem um valor aleatório num registro `TXT`, e se ele aparecer na consulta, você manda na zona.

### Registrar o nome e apontar para quem responde

Para que `rango.com.br` exista, alguém precisa registrá-lo no Registro.br, por algumas dezenas de reais por ano. No registro, você informa quais servidores autoritativos respondem pelo domínio, e o Registro.br publica isso como registros `NS` na zona de `br`: é a delegação do passo 2. O registrador e o provedor de DNS podem ser empresas diferentes. Na Parte II, a zona do Rangô vai morar no Amazon Route 53.

## HTTP por baixo dos panos

Com o IP em mãos, o navegador abre uma conexão TCP com `203.0.113.45` na porta 80 e manda a requisição. Você usa HTTP todos os dias, mas talvez nunca tenha visto como ele é no fio. É texto, linha por linha:

```text
GET /restaurantes HTTP/1.1
Host: rango.com.br
User-Agent: Mozilla/5.0 ...
Accept: application/json

```

A linha em branco marca o fim dos cabeçalhos. Repare no `Host`. O IP já levou o pacote até a máquina, então por que repetir o nome? Porque uma máquina com um único IP pode servir dezenas de sites, e o servidor web lê o `Host` para decidir qual aplicação responde. Isso se chama *virtual hosting*, e o TLS vai precisar de algo parecido.

O HTTP/2 e o HTTP/3 mudaram o transporte (várias requisições numa conexão, formato binário e, no HTTP/3, QUIC sobre UDP), mas rotas, verbos, cabeçalhos e status continuam iguais para o seu código FastAPI. Na prática, os navegadores só usam essas versões sobre TLS.

## TLS: o cadeado

O *TLS* (*Transport Layer Security*) é uma camada que fica entre o TCP e o HTTP. O HTTP continua igual, mas, em vez de ir em texto puro, vai cifrado. HTTPS é simplesmente HTTP dentro de TLS, por padrão na porta 443. O nome antigo, SSL, ainda aparece em todo lugar (`--ssl-keyfile`, "certificado SSL"), mas as versões de SSL estão aposentadas há anos por falhas de segurança. Hoje se usa TLS 1.2 e, cada vez mais, TLS 1.3.

O TLS garante sigilo (quem captura os pacotes vê bytes embaralhados), integridade (um byte alterado no caminho derruba a conexão) e autenticação (o navegador verifica que fala com o dono de `rango.com.br`, e não com o roteador do shopping). A autenticação é a parte difícil, e é nela que os certificados entram.

### O problema de combinar uma senha em público

Para cifrar a conversa, o navegador e o servidor precisam de uma chave em comum. Só que eles nunca se viram antes, e todo pacote entre os dois passa por máquinas desconhecidas. Como combinar um segredo gritando numa sala cheia?

A criptografia resolve isso com uma troca de chaves (no TLS moderno, uma variante chamada ECDHE). Cada lado gera um par de números, troca a parte pública e combina com a própria parte privada. Os dois chegam ao mesmo segredo, e quem só viu as partes públicas não consegue calculá-lo. É matemática, e funciona.

Só que há um furo. Se o roteador do shopping estiver no meio, ele pode fazer a troca de chaves com o navegador fingindo ser o Rangô, e outra troca com o Rangô fingindo ser o navegador. Os dois lados acham que têm uma conexão segura, e o intermediário lê tudo. É o ataque conhecido como *man-in-the-middle*. A troca de chaves, sozinha, garante que você está falando em segredo com alguém. Não garante quem é esse alguém.

### Certificados: o documento de identidade do site

O **certificado** fecha o furo. Ele é um arquivo que diz, em essência: "a chave pública X pertence a quem controla `rango.com.br`, válido de tal data a tal data", com a assinatura digital de uma **autoridade certificadora** (a *CA*, de *Certificate Authority*). Durante o handshake, o servidor envia o certificado e prova que tem a chave privada correspondente, assinando os dados daquela conexão específica. O intermediário do shopping pode copiar o certificado do Rangô, que é público, mas não tem a chave privada, então não consegue produzir essa assinatura.

E por que o navegador confia na assinatura da CA? Porque o sistema operacional e o navegador vêm de fábrica com uma lista de CAs confiáveis, o chamado **repositório de raízes** (*root store*). São algumas dezenas de organizações auditadas, e a chave pública de cada uma está gravada no seu computador. A analogia mais próxima é o cartório: você confia na firma reconhecida porque confia no cartório, e confia no cartório porque o Estado o credenciou.

Na prática, a raiz fica guardada offline e assina certificados **intermediários**, que assinam os dos sites. O resultado é uma **cadeia**: `rango.com.br` assinado pelo intermediário, assinado pela raiz que está no repositório do navegador. O servidor envia o próprio certificado e os intermediários; a raiz o navegador já tem.

Antes de mostrar o cadeado, o navegador confere se a cadeia termina numa raiz confiável, se nada está vencido e se o nome digitado aparece no campo *Subject Alternative Name* (SAN) do certificado. Um certificado para `rango.com.br` não vale para `www.rango.com.br`, a menos que os dois estejam no SAN ou que se use um curinga, `*.rango.com.br`. E o curinga cobre um nível só: vale para `api.rango.com.br`, mas não para `rango.com.br` nem para `v2.api.rango.com.br`.

### Como a CA sabe que o domínio é seu

A CA não pede documento com foto. Para os certificados comuns, chamados de *Domain Validated*, ela só verifica se você controla o domínio. Os desafios mais usados são dois. No desafio por HTTP, a CA pede que você publique um arquivo com um conteúdo aleatório num caminho específico do site, e depois tenta baixá-lo. No desafio por DNS, ela pede um registro `TXT` com um valor aleatório. Se você consegue fazer qualquer um dos dois, controla o domínio.

Até meados da década passada, certificados custavam dinheiro e davam trabalho para renovar, o que mantinha boa parte da web em HTTP. Isso mudou com o **Let's Encrypt**, uma CA sem fins lucrativos que emite certificados gratuitos, de forma automatizada, pelo protocolo ACME. Ferramentas como o Certbot pedem o certificado, respondem ao desafio e renovam sozinhas. Na AWS, o AWS Certificate Manager faz o mesmo papel para os serviços dela, também sem custo, e você vai usá-lo no capítulo 14.

A validade dos certificados vem encolhendo. Os do Let's Encrypt valem 90 dias. Em 2025, o CA/Browser Forum, que reúne CAs e fabricantes de navegadores, aprovou uma redução gradual do prazo máximo: 200 dias a partir de março de 2026, 100 dias a partir de março de 2027 e 47 dias a partir de março de 2029. Renovar à mão, com lembrete no calendário, deixa de ser viável.

### O handshake, passo a passo

Juntando as peças, um handshake de TLS 1.3 fica assim:

```text
Navegador                                         Servidor
   |                                                  |
   |--- ClientHello -------------------------------->|
   |    versões e cifras aceitas, parte pública da    |
   |    troca de chaves, SNI: rango.com.br            |
   |                                                  |
   |<-- ServerHello ---------------------------------|
   |    cifra escolhida, parte pública da troca       |
   |<-- Certificado + cadeia (já cifrados) ----------|
   |<-- Assinatura com a chave privada --------------|
   |<-- Finished ------------------------------------|
   |                                                  |
   |--- Finished ----------------------------------->|
   |--- GET /restaurantes (cifrado) ---------------->|
```

Repare no campo **SNI** (*Server Name Indication*) do primeiro pacote. Lembra do `Host` no HTTP? O problema é o mesmo: um IP com vários sites. Só que, no TLS, o servidor precisa escolher qual certificado enviar antes de qualquer HTTP ser trocado. Então o navegador já diz no `ClientHello` qual nome quer acessar. Esse campo ainda viaja visível na maioria das conexões, e por isso quem observa a rede consegue saber qual site você acessou, mesmo sem ver o conteúdo.

No TLS 1.3, o handshake custa uma ida e volta antes da primeira requisição (no TLS 1.2 eram duas). Some o TCP, o DNS e a própria requisição: com 140 ms de ida e volta até um servidor nos Estados Unidos, a primeira visita gasta perto de meio segundo antes do primeiro byte do Rangô.

## CDN e cache na borda

Resta a distância. Os arquivos do React e as fotos dos pratos são iguais para todo mundo, mas cada cliente em Manaus ou Porto Alegre busca tudo no mesmo servidor, pagando todas as idas e voltas até lá.

Uma **CDN** (*Content Delivery Network*) é uma rede de servidores espalhados pelo mundo, os **pontos de presença** ou servidores de **borda** (*edge*), que guardam cópias do seu conteúdo perto dos usuários. O DNS da CDN, ou o anycast, manda cada cliente para a borda mais próxima. Se a borda já tem o arquivo, responde na hora, e isso é um *cache hit*. Se não tem, busca no seu servidor (que, nesse contexto, se chama **origem**), entrega ao cliente e guarda uma cópia: um *cache miss*.

O handshake TLS também passa a acontecer na borda, a poucos milissegundos do cliente, e a borda reaproveita conexões já abertas com a origem. Mesmo para a API, que não dá para cachear, isso encurta a primeira resposta.

Quem decide o que pode ficar em cache, e por quanto tempo, é você, com o cabeçalho `Cache-Control` da resposta. A analogia com o TTL do DNS é direta. O build do Vite ajuda muito aqui: ele gera arquivos com um hash no nome, como `assets/index-4f9a1c2b.js`. Se o conteúdo muda, o nome muda. Por isso esses arquivos podem ser cacheados por um ano:

```text
Cache-Control: public, max-age=31536000, immutable
```

O `index.html` é o oposto. Ele tem sempre o mesmo nome e aponta para os arquivos com hash da versão atual. Se ficar em cache por um dia, os clientes vão continuar carregando a versão antiga do front durante um dia inteiro depois do deploy. Para ele, use:

```text
Cache-Control: no-cache
```

Apesar do nome, `no-cache` permite guardar uma cópia, desde que o cache confirme com a origem, a cada uso, se ela ainda vale. Quem proíbe guardar é o `no-store`, que é o que você quer para respostas com dados pessoais.

Na AWS, a CDN se chama Amazon CloudFront, e o front do Rangô vai morar nela no capítulo 14.

## Mão na massa: um nome e um cadeado para o Rangô local

Sem máquina com IP público, dá para montar quase tudo localmente: um nome apontando para o seu notebook e HTTPS com certificado confiável. Os pré-requisitos são o Rangô do capítulo anterior, o `curl`, o `openssl` e o `dig` (no Debian e no Ubuntu, pacote `dnsutils`). No Windows, rode os comandos dentro do WSL.

### Consulte o DNS com dig

Comece consultando um domínio real. Os exemplos abaixo usam `rango.com.br` como se ele fosse nosso, com IPs de documentação. Para ver números reais, repita com qualquer domínio, como `registro.br`:

```bash
dig rango.com.br A
```

```text
;; QUESTION SECTION:
;rango.com.br.                  IN      A

;; ANSWER SECTION:
rango.com.br.           3600    IN      A       203.0.113.45

;; Query time: 38 msec
;; SERVER: 192.168.0.1#53(192.168.0.1) (UDP)
```

A saída foi encurtada. O `3600` é o TTL restante, em segundos. A linha `SERVER` mostra qual resolver respondeu (no caso, o roteador de casa, que repassa para o provedor) e confirma o UDP. Rode o mesmo comando de novo:

```text
rango.com.br.           3421    IN      A       203.0.113.45

;; Query time: 1 msec
```

O TTL diminuiu e o tempo caiu para 1 ms. A resposta veio do cache. Agora peça ao `dig` para fazer o papel do resolver, começando pela raiz:

```bash
dig +trace rango.com.br
```

```text
.                       518400  IN  NS  a.root-servers.net.
.                       518400  IN  NS  b.root-servers.net.
;; Received 239 bytes from 192.168.0.1#53(192.168.0.1) in 12 ms

br.                     172800  IN  NS  a.dns.br.
br.                     172800  IN  NS  b.dns.br.
;; Received 701 bytes from 198.41.0.4#53(a.root-servers.net) in 24 ms

rango.com.br.           3600    IN  NS  ns1.provedor-dns.example.
rango.com.br.           3600    IN  NS  ns2.provedor-dns.example.
;; Received 612 bytes from 200.219.148.10#53(a.dns.br) in 31 ms

rango.com.br.           3600    IN  A   203.0.113.45
;; Received 57 bytes from 198.51.100.53#53(ns1.provedor-dns.example) in 45 ms
```

Os quatro blocos são os passos da cadeia: raiz, delegação para `br`, delegação para os servidores do Rangô e a resposta com autoridade. Para perguntar direto ao autoritativo, pulando os caches, use `@` (é assim que você descobre se o problema está na zona ou no cache de alguém):

```bash
dig @ns1.provedor-dns.example rango.com.br A
```

### Dê um nome ao seu notebook

Antes de consultar qualquer resolver, o sistema operacional olha um arquivo local, o `hosts`. Ele funciona como uma zona de DNS particular, que vale só para a sua máquina. Vamos usá-lo para criar dois nomes para o Rangô: `rango.test` para o front e `api.rango.test` para a API. O domínio de topo `.test` é reservado justamente para testes (RFC 6761) e nunca vai existir na internet, então não há risco de colidir com um site real.

No macOS e no Linux, edite `/etc/hosts` com `sudo`. No Windows, abra o Bloco de Notas como administrador e edite `C:\Windows\System32\drivers\etc\hosts`. Acrescente:

```text
127.0.0.1   rango.test
127.0.0.1   api.rango.test
```

O `dig` consulta o DNS diretamente e ignora o arquivo `hosts`, por isso ele não serve para conferir essa mudança. Use o Python, que pergunta ao sistema operacional como qualquer aplicação faria:

```bash
python3 -c "import socket; print(socket.gethostbyname('api.rango.test'))"
```

```text
127.0.0.1
```

### Veja o HTTP em texto puro

Suba o backend como no capítulo 1, ainda sem TLS, e use o `curl -v` para ver a conversa inteira:

```bash
cd backend
uvicorn app.main:app --reload --port 8000
```

```bash
curl -v http://api.rango.test:8000/health
```

```text
* Connected to api.rango.test (127.0.0.1) port 8000
> GET /health HTTP/1.1
> Host: api.rango.test:8000
> User-Agent: curl/8.7.1
> Accept: */*
>
< HTTP/1.1 200 OK
< content-type: application/json
< content-length: 15
<
{"status":"ok"}
```

As linhas com `>` são o que saiu, e as com `<` são o que voltou. O `Host` está lá, com o nome que você digitou. Se alguém capturasse esses pacotes, veria exatamente este texto.

### Primeira tentativa: um certificado que ninguém assinou

Agora tente o HTTPS da forma ingênua, com um certificado **autoassinado**, gerado por você mesmo. Na raiz do projeto, crie uma pasta `certs`:

```bash
mkdir certs && cd certs
openssl req -x509 -newkey rsa:2048 -nodes -days 7 \
  -keyout autoassinado-key.pem -out autoassinado.pem \
  -subj "/CN=api.rango.test" \
  -addext "subjectAltName=DNS:api.rango.test"
cd ..
```

O comando gera uma chave privada e um certificado que diz "esta chave pertence a `api.rango.test`", assinado pela própria chave. Suba o Uvicorn com TLS:

```bash
cd backend
uvicorn app.main:app --reload --port 8000 \
  --ssl-keyfile ../certs/autoassinado-key.pem \
  --ssl-certfile ../certs/autoassinado.pem
```

E teste:

```bash
curl https://api.rango.test:8000/health
```

```text
curl: (60) SSL certificate problem: self-signed certificate
```

No navegador, a mesma URL mostra uma página inteira de alerta, com o código `NET::ERR_CERT_AUTHORITY_INVALID`. A conexão é cifrada, mas nada prova quem está do outro lado: é um documento de identidade que você mesmo carimbou. É esse alerta que o usuário veria se um intermediário tentasse se passar pelo Rangô.

Apague o certificado autoassinado, que não vamos mais usar:

```bash
rm certs/autoassinado.pem certs/autoassinado-key.pem
```

### Sua própria autoridade certificadora com mkcert

Para desenvolvimento, a saída é criar uma CA que só o seu computador conhece e instalá-la no repositório de raízes da sua máquina. O `mkcert`, uma ferramenta de código aberto, faz isso em dois comandos. Instale-o pelo gerenciador de pacotes (`brew install mkcert` no macOS, `choco install mkcert` ou `scoop install mkcert` no Windows; no Linux, veja as instruções do repositório oficial, nas referências). Depois:

```bash
mkcert -install
```

O comando cria uma CA nova e a adiciona ao repositório de raízes do sistema (e do Firefox, se ele estiver instalado). Agora emita um certificado para os dois nomes do Rangô:

```bash
cd certs
mkcert rango.test api.rango.test
cd ..
```

O resultado são dois arquivos, `rango.test+1.pem` (o certificado) e `rango.test+1-key.pem` (a chave privada): um único certificado com os dois nomes no SAN. Antes de seguir, impeça que essa pasta vá para o repositório. Chave privada não entra no git, nem a de desenvolvimento:

```bash
echo "certs/" >> .gitignore
```

### HTTPS no backend e no front

Suba a API com o certificado novo e com o CORS liberando a origem nova do front. Lembre que a origem inclui o esquema: `https://rango.test:5173` e `http://rango.test:5173` são origens diferentes para o navegador.

```bash
cd backend
CORS_ORIGINS="https://rango.test:5173" \
  uvicorn app.main:app --reload --port 8000 \
  --ssl-keyfile ../certs/rango.test+1-key.pem \
  --ssl-certfile ../certs/rango.test+1.pem
```

```bash
curl https://api.rango.test:8000/health
```

```text
{"status":"ok"}
```

Sem erro. O `curl` confiou no certificado porque a CA do `mkcert` está no repositório do sistema. Se a sua versão do `curl` usar outro repositório e ainda reclamar, aponte a CA explicitamente com `--cacert "$(mkcert -CAROOT)/rootCA.pem"`.

No front, configure o Vite para servir HTTPS com o mesmo certificado. Edite `frontend/vite.config.ts`:

```ts
// frontend/vite.config.ts
import fs from "node:fs";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "127.0.0.1",
    allowedHosts: ["rango.test"],
    https: {
      key: fs.readFileSync("../certs/rango.test+1-key.pem"),
      cert: fs.readFileSync("../certs/rango.test+1.pem"),
    },
  },
});
```

O `host: "127.0.0.1"` fixa a escuta no IPv4 para onde o arquivo `hosts` aponta; sem ele, o Node às vezes escuta só no IPv6 `::1`. O `allowedHosts` existe porque, desde o início de 2025, o Vite recusa requisições com um cabeçalho `Host` desconhecido, como proteção contra um ataque chamado *DNS rebinding*. Por padrão, ele aceita só `localhost` e IPs.

Atualize `frontend/.env.local` para apontar para a API pelo nome, com HTTPS:

```bash
# frontend/.env.local
VITE_API_URL=https://api.rango.test:8000
```

Suba o front com `npm run dev` e abra `https://rango.test:5173`. O cadeado aparece, e a lista com a Cantina da Nona e o Sabor do Sertão também. Se você deixasse `VITE_API_URL` em HTTP, o navegador bloquearia as chamadas por *mixed content*: uma página HTTPS não pode buscar dados por HTTP.

O celular da rede de casa deixou de funcionar nessa configuração, porque não tem as entradas do `hosts` nem a CA do `mkcert`. O nome público e o certificado de uma CA reconhecida chegam na Parte II.

### Abra o certificado com openssl

O `openssl s_client` faz o handshake e mostra o que veio do servidor:

```bash
openssl s_client -connect api.rango.test:8000 -servername api.rango.test </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

```text
subject=O=mkcert development certificate, OU=voce@notebook
issuer=O=mkcert development CA, OU=voce@notebook, CN=mkcert voce@notebook
notBefore=Oct 15 13:02:11 2026 GMT
notAfter=Jan 15 13:02:11 2029 GMT
X509v3 Subject Alternative Name:
    DNS:rango.test, DNS:api.rango.test
```

Os valores exatos vão variar com o seu usuário e a data. O `-servername` é o SNI: é ele que diz ao servidor qual nome você quer. O `issuer` é a CA do `mkcert`, e o SAN tem os dois nomes. Repita o comando com um site real, trocando o host e usando a porta 443, e você vai ver no `issuer` o nome de um intermediário de uma CA pública.

## Armadilhas e casos reais

### O TTL longo na véspera da migração

Situação hipotética, mas comum: o registro `A` do Rangô tem TTL de 86400 (um dia). Na sexta-feira à noite, você troca o IP e desliga a máquina antiga. Nas próximas 24 horas, parte dos clientes continua chegando no IP antigo, onde não existe mais nada. O suporte recebe reclamações que você não consegue reproduzir, porque o seu resolver já pegou o valor novo.

> **Dica:** Um ou dois dias antes de uma migração, baixe o TTL do registro para 60 ou 300 segundos e espere o TTL antigo vencer. Faça a troca. Quando tudo estiver estável, suba o TTL de novo. E mantenha a máquina antiga respondendo por um tempo depois da troca.

Existe também o cache negativo: se você consultar `api.rango.com.br` antes de criar o registro, a resposta "esse nome não existe" também fica em cache, por um tempo definido no registro `SOA` da zona.

### Quando o DNS some, tudo some

Em 4 de outubro de 2021, Facebook, Instagram e WhatsApp ficaram fora do ar por cerca de seis horas. Segundo o relato de engenharia da própria empresa, um comando numa manutenção de rotina derrubou o backbone que liga os data centers, e os servidores DNS, projetados para isso, pararam de anunciar suas rotas para a internet. Com isso, os servidores autoritativos de `facebook.com` ficaram inalcançáveis, e os resolvers do mundo inteiro passaram a não conseguir traduzir o nome. As aplicações estavam de pé, mas ninguém conseguia encontrá-las, e a falha ainda dificultou o acesso das equipes às ferramentas internas que usariam para corrigi-la.

### A raiz que venceu e levou aparelhos antigos junto

Certificados raiz também vencem. Em 30 de setembro de 2021, expirou a raiz DST Root CA X3, que tinha assinado de forma cruzada a raiz do Let's Encrypt nos primeiros anos da CA. Sistemas atualizados já confiavam na raiz própria do Let's Encrypt. Clientes antigos (OpenSSL velho em servidores, aparelhos embarcados, celulares desatualizados) começaram a falhar com erro de certificado, sem nenhuma mudança no código.

A lição para o Rangô: o repositório de raízes de quem chama a sua API importa tanto quanto o certificado que você instala. No Python, `requests` e `httpx` usam por padrão o repositório do pacote `certifi`, separado do sistema operacional. Por isso um script Python pode rejeitar o certificado do `mkcert` mesmo com o navegador mostrando o cadeado.

### O certificado que venceu num domingo

Certificado vencido é uma das causas mais comuns de indisponibilidade, quase sempre com a mesma história: alguém emitiu o certificado à mão, ele valia um ano, a pessoa saiu da empresa e o lembrete foi junto.

> **Armadilha:** A renovação automática também falha, por exemplo quando alguém muda um redirecionamento e o desafio por HTTP quebra. Monitore o vencimento do certificado que o servidor está entregando, e não só o do arquivo no disco.

### HSTS: fácil de ligar, difícil de desligar

Depois de redirecionar a porta 80 para a 443, o próximo passo é o cabeçalho `Strict-Transport-Security` (HSTS), que manda o navegador nunca mais acessar o domínio por HTTP. Ele protege bem, mas é difícil de desfazer: com um `max-age` de um ano, se o HTTPS quebrar, os navegadores que já o viram vão se recusar a abrir o site durante esse ano. Comece com um valor curto e aumente aos poucos.

### O arquivo da CA do mkcert

O `mkcert -install` deixa na pasta indicada por `mkcert -CAROOT` o arquivo `rootCA-key.pem`, a chave privada da sua CA local. Com ele, qualquer pessoa emite certificados para qualquer site, inclusive o do seu banco, que o seu navegador vai aceitar. Nunca o copie nem o coloque num repositório.

## Resumo

- O DNS traduz nomes em IPs por uma hierarquia de delegações: raiz, domínio de topo, domínio. Cada nível só sabe quem cuida do nível de baixo.
- O resolver recursivo faz a cadeia de perguntas em nome do cliente. O servidor autoritativo responde com os registros da zona.
- O TTL define quanto tempo cada resposta fica em cache. "Propagação" é só o cache antigo expirando. Baixe o TTL antes de migrações.
- Os registros que importam agora são `A`, `AAAA`, `CNAME`, `MX`, `TXT` e `NS`. `CNAME` não pode ficar no apex.
- HTTP é texto. O cabeçalho `Host` permite vários sites num mesmo IP. HTTP/2 e HTTP/3 mudam o transporte, e não a semântica.
- TLS garante sigilo, integridade e autenticação. A troca de chaves cria o segredo, e o certificado prova quem está do outro lado.
- O certificado liga uma chave pública a nomes (SAN), assinado por uma CA. O navegador valida a cadeia até uma raiz do repositório local, a validade e o nome. O SNI diz qual certificado o servidor deve enviar.
- CAs validam o domínio por desafio HTTP ou DNS. Let's Encrypt e ACM emitem certificados gratuitos. Prazos máximos caem para 47 dias até 2029, e renovação manual deixa de ser viável.
- Uma CDN guarda conteúdo na borda, perto do usuário, e termina o TLS ali. `Cache-Control` controla o cache: arquivos com hash por um ano, `index.html` com `no-cache`.
- O Rangô agora roda localmente em `https://rango.test:5173`, com a API em `https://api.rango.test:8000`, nomes no arquivo `hosts` e certificado do `mkcert`.

## Próxima parada: o servidor que ninguém configurou

Agora você sabe o que precisa existir para a sua sócia digitar `rango.com.br` e ver o cadeado: um registro `A` apontando para um IP público e um certificado válido servido nesse IP. Falta o próprio servidor. E, ao pensar nele, começam a aparecer perguntas que o seu notebook escondia. Quem vai rodar o Uvicorn quando a máquina reiniciar às 4h da manhã? Como servir o front e a API na porta 443, que só o administrador pode abrir, sem rodar a aplicação inteira com privilégios de administrador? Onde fica o certificado, e quem renova?

E tem a pergunta mais traiçoeira. Você instala Python, as dependências e o Postgres no servidor, sobe o Rangô, e a primeira requisição devolve um erro 500 que nunca apareceu no seu notebook: uma biblioteca em outra versão, uma variável de ambiente esquecida. Na sua máquina funciona. No servidor, não. No próximo capítulo, vamos ver o que é um servidor por dentro, o que um proxy reverso faz na frente da aplicação e por que os containers viraram a resposta padrão para esse "na minha máquina funciona".

## Referências

- RFC 1034, *Domain Names: Concepts and Facilities*: https://www.rfc-editor.org/rfc/rfc1034
- RFC 1035, *Domain Names: Implementation and Specification*: https://www.rfc-editor.org/rfc/rfc1035
- RFC 2308, cache negativo de consultas DNS: https://www.rfc-editor.org/rfc/rfc2308
- RFC 6761, nomes de domínio de uso especial (`.test`): https://www.rfc-editor.org/rfc/rfc6761
- Servidores raiz do DNS: https://root-servers.org/
- Registro.br: https://registro.br/
- RFC 9110, *HTTP Semantics*: https://www.rfc-editor.org/rfc/rfc9110
- RFC 9111, *HTTP Caching*: https://www.rfc-editor.org/rfc/rfc9111
- RFC 8446, *The Transport Layer Security (TLS) Protocol Version 1.3*: https://www.rfc-editor.org/rfc/rfc8446
- RFC 8555, protocolo ACME: https://www.rfc-editor.org/rfc/rfc8555
- RFC 6797, HTTP Strict Transport Security: https://www.rfc-editor.org/rfc/rfc6797
- Let's Encrypt, como funciona: https://letsencrypt.org/how-it-works/
- Let's Encrypt, expiração da raiz DST Root CA X3: https://letsencrypt.org/docs/dst-root-ca-x3-expiration-september-2021/
- CA/Browser Forum, Baseline Requirements: https://cabforum.org/working-groups/server/baseline-requirements/
- Facebook Engineering, detalhes da indisponibilidade de 4 de outubro de 2021: https://engineering.fb.com/2021/10/05/networking-traffic/outage-details/
- Cloudflare, análise da mesma indisponibilidade: https://blog.cloudflare.com/october-2021-facebook-outage/
- mkcert (repositório oficial): https://github.com/FiloSottile/mkcert
- Uvicorn, opções de TLS (`--ssl-keyfile`, `--ssl-certfile`): https://www.uvicorn.org/settings/
- Vite, opções do servidor (`server.https`, `server.allowedHosts`): https://vite.dev/config/server-options
- MDN, `Cache-Control`: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Cache-Control
