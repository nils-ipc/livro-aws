# Servidores, containers e Kubernetes

No capítulo anterior, você viu como o DNS transforma `rango.com.br` num IP e como o TLS prova que o navegador está falando com o servidor certo. O Rangô ganhou nomes locais (`rango.test` e `api.rango.test`) e um certificado do `mkcert`. Faltou o servidor: uma máquina que fique ligada, rode o Uvicorn sozinha e sirva o Rangô na porta 443.

## Sexta-feira, 19h, primeiro deploy

Você decide que chegou a hora. Aluga um servidor Linux num provedor qualquer (a AWS fica para a Parte II), recebe um IP público, `203.0.113.45`, e um usuário com acesso por SSH. Entra na máquina, clona o repositório e repete o que sempre fez no notebook:

```bash
git clone https://github.com/seu-usuario/rango.git
cd rango/backend
python3 -m venv .venv
source .venv/bin/activate
pip install "fastapi[standard]"
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

O Uvicorn sobe sem reclamar. Você abre `http://203.0.113.45:8000/health` no navegador e recebe `{"status": "ok"}`. Ótimo. Abre `/restaurantes` e recebe isto:

```text
Internal Server Error
```

No notebook, essa mesma rota funciona há uma semana. Na semana passada, a sua sócia pediu que a taxa de entrega aparecesse já formatada em reais, e você resolveu do jeito mais rápido, usando o módulo `locale` da biblioteca padrão:

```python
# backend/app/main.py
import locale
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
    {"id": 1, "nome": "Cantina da Nona", "cozinha": "italiana", "taxa_entrega": 6.9},
    {"id": 2, "nome": "Sabor do Sertão", "cozinha": "nordestina", "taxa_entrega": 4.5},
]


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/restaurantes")
def listar_restaurantes():
    locale.setlocale(locale.LC_MONETARY, "pt_BR.UTF-8")
    return [
        {**r, "taxa_entrega_fmt": locale.currency(r["taxa_entrega"], grouping=True)}
        for r in RESTAURANTES
    ]
```

No terminal do servidor, o Uvicorn mostra o motivo:

```text
  File "/home/deploy/rango/backend/app/main.py", line 31, in listar_restaurantes
    locale.setlocale(locale.LC_MONETARY, "pt_BR.UTF-8")
  ...
locale.Error: unsupported locale setting
```

O seu notebook tem o locale `pt_BR.UTF-8` instalado porque o sistema dele está em português. O servidor veio com uma instalação mínima, em inglês, e ninguém instalou esse locale. O código Python é idêntico nas duas máquinas. O que mudou foi tudo ao redor dele.

E há mais. O `pip install` baixou versões mais novas das bibliotecas, porque você nunca fixou versões. A variável `CORS_ORIGINS` não existe no servidor. E, quando você fecha o terminal para ir jantar, o Uvicorn morre junto com a sessão SSH.

"Na minha máquina funciona" tem um sentido bem literal: a aplicação depende de muita coisa que não está no repositório. Versão do Python, bibliotecas do sistema, locale, variáveis de ambiente, até o processo que mantém o programa rodando. Vamos primeiro entender o que existe num servidor e, depois, empacotar o ambiente junto com o código.

## O que é um servidor, afinal

Servidor é um computador cuja função é atender requisições de outros computadores. Fisicamente, lembra o seu notebook. A diferença está no uso: ele fica num data center, ligado o tempo todo, com energia redundante e um link de rede rápido, e ninguém se senta na frente dele.

Ter um servidor já significou comprar uma máquina física e instalá-la num rack. Isso ainda existe (o chamado *bare metal*), mas hoje a maior parte das aplicações roda em **máquinas virtuais**.

### Máquinas virtuais

Uma máquina virtual (VM) é um computador simulado em software, rodando dentro de um computador físico. Um programa chamado **hypervisor** divide os recursos da máquina física entre várias VMs: cada uma recebe uma fatia de CPU, de memória e de disco, e enxerga um hardware virtual como se fosse só dela. Cada VM roda o seu próprio sistema operacional completo, com o seu próprio kernel.

Se você já usou o VirtualBox, já usou uma VM. Os provedores de nuvem fazem o mesmo em escala industrial: um servidor físico com dezenas de núcleos é fatiado em VMs alugadas para clientes diferentes. Quando você "aluga um servidor" de 2 vCPUs e 4 GB, recebe uma dessas fatias. Ela nasce em minutos, pode ser destruída quando não servir mais, e o hypervisor impede que um cliente enxergue a memória do outro. No capítulo 9, você vai criar exatamente uma VM dessas na AWS, chamada instância EC2.

## O mínimo de Linux para rodar uma aplicação

Quase todo servidor web roda Linux. Você não precisa virar administrador de sistemas, mas precisa conhecer algumas peças para entender o que deu errado na sexta-feira à noite.

### Distribuições, pacotes e onde as coisas ficam

O Linux propriamente dito é só o kernel: a parte que conversa com o hardware, gerencia memória, processos e rede. O que você instala é uma **distribuição**, que junta o kernel com ferramentas, bibliotecas e um gerenciador de pacotes. Ubuntu e Debian usam `apt`. Amazon Linux e Red Hat usam `dnf`. O papel do gerenciador de pacotes é parecido com o do `pip`, só que para o sistema inteiro: `sudo apt install nginx` instala o Nginx e tudo de que ele depende.

Isso já explica parte do problema. O Ubuntu 24.04 traz o Python 3.12; o Ubuntu 22.04 traz o 3.10. Locales e bibliotecas em C usadas por pacotes Python também variam de uma instalação para outra.

Os diretórios seguem uma convenção: configuração em `/etc`, logs em `/var/log`, programas instalados à mão em `/opt` ou `/srv`, pastas dos usuários em `/home`.

### Usuários e permissões

No Linux, todo arquivo e todo processo pertencem a um usuário. O usuário `root` pode tudo: apagar qualquer arquivo, abrir qualquer porta, matar qualquer processo. O comando `sudo` executa um comando com os poderes do `root`.

Lembra das portas privilegiadas do capítulo 1, abaixo de 1024? No Linux, só o `root` (ou um processo com uma permissão específica, a `CAP_NET_BIND_SERVICE`) pode escutar nelas. As portas 80 e 443 estão nessa faixa. A saída preguiçosa seria rodar o Uvicorn como `root`. Só que aí qualquer falha na sua aplicação, qualquer dependência comprometida, roda com permissão para fazer qualquer coisa na máquina. A regra é a mesma do código: cada parte com o mínimo de permissão de que precisa. A aplicação roda com um usuário próprio, sem privilégios, numa porta alta como a 8000. Daqui a pouco você vai ver quem fica na porta 443.

### Processos e sinais

Cada programa em execução é um **processo**, identificado por um número, o PID. O comando `ps aux` lista todos eles. Um processo pode receber **sinais**, que são avisos do sistema operacional. Os que importam para você:

| Sinal | Quando chega | O que costuma acontecer |
|-------|--------------|-------------------------|
| `SIGTERM` | Alguém pediu para o processo encerrar (`kill PID`) | O processo termina o que está fazendo e sai. O Uvicorn conclui as requisições em andamento antes de sair. |
| `SIGKILL` | Encerramento forçado (`kill -9 PID`) | O kernel mata o processo na hora, sem chance de limpeza. |
| `SIGHUP` | O terminal que controlava o processo foi fechado | Por padrão, o processo morre. |
| `SIGINT` | Você apertou Ctrl+C | Parecido com o `SIGTERM`. |

O `SIGHUP` explica por que o Uvicorn morreu quando você fechou o SSH: o processo estava preso ao seu terminal. Dá para contornar com `nohup` ou `tmux`, mas, se o processo cair às 3h ou a máquina reiniciar, ninguém sobe o Uvicorn de novo.

### Serviços com systemd

Quem resolve isso é o gerenciador de serviços. Na maioria das distribuições atuais, ele se chama **systemd**: o primeiro processo a subir quando a máquina liga (o PID 1), que inicia, para, reinicia e registra os logs dos outros serviços.

Você descreve o serviço num arquivo de unidade. Para o Rangô, ficaria assim:

```ini
# /etc/systemd/system/rango-api.service
[Unit]
Description=API do Rangô (Uvicorn)
After=network.target

[Service]
User=rango
Group=rango
WorkingDirectory=/srv/rango/backend
EnvironmentFile=/etc/rango/api.env
ExecStart=/srv/rango/backend/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 2
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

O serviço roda com o usuário `rango`, sem privilégios. As variáveis de ambiente vêm de `/etc/rango/api.env`, fora do repositório. O Uvicorn escuta só em `127.0.0.1`, então ninguém de fora acessa a porta 8000. E `Restart=on-failure` sobe o processo de novo se ele cair.

Para ativar:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now rango-api
systemctl status rango-api
journalctl -u rango-api -f
```

O `enable` faz o serviço subir junto com a máquina; o `--now` já o inicia; o `journalctl` mostra os logs. Repare que o arquivo é declarativo: você diz o que quer que esteja rodando, e o systemd mantém assim. Guarde essa ideia, porque ela volta bem maior no fim do capítulo.

## Proxy reverso: quem atende a porta 443

Sobrou uma pergunta da ponte do capítulo 2: se o Uvicorn roda sem privilégios na porta 8000, quem atende na 443, com o certificado?

A resposta padrão é um **proxy reverso**. É um servidor que fica na frente da aplicação, recebe as conexões da internet e repassa cada requisição para o processo certo lá atrás. O mais usado é o **Nginx**. Na mesma máquina, o desenho fica assim:

```text
Internet
   │  HTTPS (porta 443)
   ▼
┌──────────────────────────────┐
│ Nginx                        │
│  - termina o TLS             │
│  - rango.com.br     → arquivos do React (dist/)
│  - api.rango.com.br → 127.0.0.1:8000
└──────────────────────────────┘
   │  HTTP local
   ▼
Uvicorn (usuário rango, porta 8000)
```

Em termos de FastAPI, o proxy reverso lembra um middleware que roda antes da sua aplicação, só que num processo separado. Ele termina o TLS, então o certificado fica com o Nginx e o Uvicorn recebe HTTP simples pela interface local. Roteia pelo cabeçalho `Host` do capítulo 2: `rango.com.br` serve os arquivos estáticos do build do React direto do disco, `api.rango.com.br` vai para o Uvicorn. E protege a aplicação de clientes lentos: um celular com sinal ruim pode levar segundos para enviar a requisição, e o Nginx recebe tudo antes de repassar, sem prender um worker do Uvicorn.

E a porta privilegiada? O processo principal do Nginx começa como `root`, abre as portas 80 e 443 e cria processos de trabalho que rodam como um usuário sem privilégios (`www-data`, no Ubuntu). Quem processa as requisições nunca tem poderes de administrador.

A configuração para o Rangô num servidor de verdade seria algo assim:

```nginx
# /etc/nginx/sites-available/rango
server {
    listen 80;
    server_name rango.com.br api.rango.com.br;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name rango.com.br;
    ssl_certificate     /etc/letsencrypt/live/rango.com.br/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/rango.com.br/privkey.pem;

    root /srv/rango/frontend/dist;
    location / {
        try_files $uri /index.html;
    }
}

server {
    listen 443 ssl;
    server_name api.rango.com.br;
    ssl_certificate     /etc/letsencrypt/live/rango.com.br/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/rango.com.br/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

O primeiro bloco redireciona HTTP para HTTPS. O `try_files` faz rotas desconhecidas caírem no `index.html`, que é o que uma SPA precisa. Os cabeçalhos `X-Forwarded-*` existem porque, para o Uvicorn, toda requisição vem de `127.0.0.1`; sem eles, a aplicação perderia o IP real do cliente e não saberia que a conexão original era HTTPS. O Uvicorn só confia nesses cabeçalhos quando vêm de um endereço autorizado (por padrão, `127.0.0.1`), para que um cliente qualquer não forje o próprio IP.

E o certificado? O Certbot obtém um certificado do Let's Encrypt pelo desafio HTTP do capítulo 2 e agenda a renovação automática. As perguntas da ponte anterior estão respondidas: o systemd sobe o Uvicorn depois de um reboot, o Nginx atende a 443 sem dar privilégios à aplicação, e o Certbot renova o certificado.

Falta a pergunta mais difícil.

## Voltando ao "na minha máquina funciona"

O systemd e o Nginx resolvem como a aplicação roda, e não o que ela encontra quando roda. O erro de locale continua lá. Você poderia instalar o locale no servidor e anotar isso num README. Poderia fixar as bibliotecas com `pip freeze`, o que ajuda. Mas o Python, as bibliotecas do sistema e os locales continuam dependendo de quem configurou cada máquina: o seu Mac, o Windows do colega novo, o servidor do CI, o de produção. Com o tempo, elas se afastam umas das outras.

A saída é entregar o código já dentro do ambiente, em vez de entregar o código e uma lista de instruções. Um pacote com o Python na versão certa, as bibliotecas do sistema, as dependências fixadas e a sua aplicação. Esse pacote é uma **imagem de container**.

## Containers

Um **container** é um processo comum do Linux que roda isolado do resto da máquina. Ele enxerga o próprio sistema de arquivos, a própria árvore de processos, a própria interface de rede e o próprio `localhost`. Do lado de dentro, parece que ele está sozinho num computador. Do lado de fora, é só mais um processo na lista do `ps`.

Esse isolamento vem de dois recursos do kernel do Linux:

- **Namespaces** limitam o que o processo enxerga. Com um namespace de processos, o container acha que o seu programa é o PID 1 e não vê os outros processos da máquina. Com um namespace de rede, ele tem as próprias interfaces e as próprias portas. Com um namespace de montagem, ele vê o próprio sistema de arquivos, e não o da máquina.
- **cgroups** (*control groups*) limitam o quanto o processo consome: no máximo 512 MB de memória, no máximo meio núcleo de CPU, e assim por diante.

### Container e máquina virtual

A diferença para uma VM está no kernel. Cada VM roda um sistema operacional completo, com o seu próprio kernel. Todos os containers de uma máquina compartilham o kernel dela:

```text
     Máquinas virtuais                    Containers
┌─────────┐ ┌─────────┐          ┌─────────┐ ┌─────────┐
│  App A  │ │  App B  │          │  App A  │ │  App B  │
│ libs, py│ │ libs, py│          │ libs, py│ │ libs, py│
│ kernel  │ │ kernel  │          └─────────┘ └─────────┘
└─────────┘ └─────────┘          ┌─────────────────────┐
┌─────────────────────┐          │  runtime (Docker)   │
│     hypervisor      │          │  kernel do Linux    │
│  hardware físico    │          │  hardware (ou VM)   │
└─────────────────────┘          └─────────────────────┘
```

Sem kernel próprio, um container sobe em fração de segundo e ocupa megabytes, enquanto uma VM leva de segundos a minutos e ocupa gigabytes. O preço é um isolamento mais fraco: uma falha grave no kernel afeta todos os containers da máquina. Na nuvem, o normal é usar os dois juntos, com containers dentro de VMs.

E no seu Mac ou no Windows, que não usam o kernel do Linux? O Docker Desktop cria uma VM Linux pequena e roda os containers dentro dela. Você não vê essa VM, mas ela está lá.

### Imagem, container e registry

Três palavras aparecem o tempo todo, e vale separar bem cada uma.

Uma **imagem** é o pacote: um sistema de arquivos com tudo de que a aplicação precisa, mais alguns metadados (qual comando rodar, qual usuário usar, quais variáveis definir). Ela é somente leitura. Um **container** é uma imagem em execução. A relação é a mesma entre classe e instância em Python: a partir de uma imagem, você cria quantos containers quiser, e cada um tem o seu próprio estado.

A imagem é montada em **camadas**. Cada instrução do arquivo de construção gera uma camada com as mudanças em relação à anterior, mais ou menos como cada commit no git guarda uma diferença em relação ao commit pai. Camadas iguais são reaproveitadas entre imagens e entre builds, o que deixa a construção rápida quando só o seu código muda.

Um **registry** é um repositório de imagens, como o PyPI é para pacotes Python. O Docker Hub é o mais conhecido; dele vem a imagem oficial `python`. Você constrói a imagem uma vez, envia com `docker push`, e qualquer servidor baixa a mesma imagem com `docker pull`. Na AWS, o registry se chama Amazon ECR, e ele aparece no capítulo 17.

O formato das imagens é padronizado pela OCI (*Open Container Initiative*), então Docker, Podman e containerd rodam as mesmas imagens.

## Mão na massa: o Rangô num container

Pré-requisitos: Docker instalado (Docker Desktop no macOS e no Windows, ou Docker Engine no Linux) com o plugin Compose, que traz o comando `docker compose`. Confira com `docker version` e `docker compose version`.

### Fixando as dependências

Antes de tudo, congele as versões que funcionam no seu notebook:

```bash
cd backend
source .venv/bin/activate
pip freeze > requirements.txt
```

O `requirements.txt` agora lista cada pacote com a versão exata, incluindo as dependências das dependências. Ele vai para o repositório.

### O Dockerfile

A receita da imagem fica num arquivo chamado `Dockerfile`, na pasta `backend`:

```dockerfile
# backend/Dockerfile
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

RUN useradd --create-home rango
USER rango

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Linha a linha:

1. `FROM python:3.12-slim` parte da imagem oficial do Python 3.12 sobre um Debian enxuto. A versão do Python deixa de depender da máquina.
2. As variáveis de ambiente evitam arquivos `.pyc` dentro da imagem e fazem os logs saírem na hora, sem buffer.
3. `COPY requirements.txt` vem antes de `COPY app` de propósito. As dependências mudam pouco, e o código muda o tempo todo. Com essa ordem, a camada do `pip install` fica em cache e só é refeita quando o `requirements.txt` muda. Um build que levaria um minuto passa a levar poucos segundos.
4. `useradd` e `USER rango` fazem a aplicação rodar sem ser `root` dentro do container, pelo mesmo motivo do systemd.
5. `CMD` define o comando de inicialização. O `--host 0.0.0.0` é obrigatório aqui, e o capítulo 1 explica por quê: o container tem o próprio `localhost`. Se o Uvicorn escutar em `127.0.0.1`, só o próprio container consegue falar com ele.

Crie também um `backend/.dockerignore`, que funciona como um `.gitignore` para o build:

```text
.venv
__pycache__
.env
```

Sem ele, o Docker enviaria a sua `.venv` inteira para o build, e um `.env` com segredos poderia acabar dentro da imagem.

### Construindo e rodando

```bash
docker build -t rango-api:0.1.0 .
docker run --rm -p 127.0.0.1:8000:8000 \
  -e CORS_ORIGINS="https://rango.test:5173" \
  rango-api:0.1.0
```

O `-t` dá nome e versão à imagem. No `docker run`, o `-p 127.0.0.1:8000:8000` liga a porta 8000 do seu notebook à porta 8000 do container, aceitando conexões só da sua máquina (lembra da armadilha do capítulo 1, do Docker furando o firewall? Este é o jeito de evitá-la). O `-e` passa a variável de ambiente, e o `--rm` apaga o container quando ele parar.

Em outro terminal:

```bash
curl http://localhost:8000/health
curl http://localhost:8000/restaurantes
```

O `/health` responde `{"status":"ok"}`. O `/restaurantes` devolve `Internal Server Error`. No terminal do container:

```text
  File "/app/app/main.py", line 31, in listar_restaurantes
    locale.setlocale(locale.LC_MONETARY, "pt_BR.UTF-8")
  ...
locale.Error: unsupported locale setting
```

Este é o momento mais importante do capítulo. O erro que só acontecia no servidor agora acontece no seu notebook. A imagem `python:3.12-slim` não traz o locale `pt_BR`, assim como o servidor de sexta-feira. Só que agora o ambiente é o mesmo em todo lugar, então o bug aparece onde você desenvolve, e não em produção às 19h.

### Corrigindo o bug de verdade

Daria para instalar o locale no Dockerfile. Só que o `setlocale` tem outro problema: ele altera uma configuração global do processo, compartilhada por todas as threads, e o FastAPI roda rotas síncronas em várias threads ao mesmo tempo. Formatar moeda não precisa de nada disso:

```python
# backend/app/main.py (trecho alterado; remova também o "import locale")
def formatar_reais(valor: float) -> str:
    texto = f"{valor:,.2f}"  # 1,234.50
    return "R$ " + texto.replace(",", "_").replace(".", ",").replace("_", ".")


@app.get("/restaurantes")
def listar_restaurantes():
    return [
        {**r, "taxa_entrega_fmt": formatar_reais(r["taxa_entrega"])}
        for r in RESTAURANTES
    ]
```

Reconstrua com uma versão nova e rode de novo:

```bash
docker build -t rango-api:0.1.1 .
docker run --rm -p 127.0.0.1:8000:8000 \
  -e CORS_ORIGINS="https://rango.test:5173" \
  rango-api:0.1.1
```

Repare na saída do build: as camadas até o `pip install` aparecem como `CACHED`. Só a cópia do código foi refeita. E agora:

```bash
curl http://localhost:8000/restaurantes
```

```json
[{"id":1,"nome":"Cantina da Nona","cozinha":"italiana","taxa_entrega":6.9,"taxa_entrega_fmt":"R$ 6,90"},{"id":2,"nome":"Sabor do Sertão","cozinha":"nordestina","taxa_entrega":4.5,"taxa_entrega_fmt":"R$ 4,50"}]
```

### API e proxy reverso juntos com Docker Compose

Rodar um container com um `docker run` comprido é aceitável. Rodar dois, com rede entre eles, pede o **Docker Compose**: um arquivo YAML que descreve vários containers e como eles se ligam. Vamos colocar um Nginx na frente da API, do mesmo jeito que faríamos num servidor, usando o certificado do `mkcert` que você criou no capítulo 2.

Crie `nginx/rango.conf` na raiz do projeto:

```nginx
# nginx/rango.conf
server {
    listen 443 ssl;
    server_name api.rango.test;
    ssl_certificate     /etc/nginx/certs/rango.test+1.pem;
    ssl_certificate_key /etc/nginx/certs/rango.test+1-key.pem;

    location / {
        proxy_pass http://api:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

E `compose.yaml`, também na raiz:

```yaml
# compose.yaml
services:
  api:
    build: ./backend
    image: rango-api:0.1.1
    environment:
      CORS_ORIGINS: "https://rango.test:5173"
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

O serviço `api` não publica nenhuma porta: só o Nginx fala com o Uvicorn. O Compose cria uma rede interna em que cada serviço é encontrado pelo nome, por isso o `proxy_pass` aponta para `http://api:8000`. Os certificados entram como volume somente leitura (`:ro`), fora da imagem. E `restart: unless-stopped` faz o papel do `Restart=on-failure` do systemd.

Se o Uvicorn da API ainda estiver rodando com `--ssl-keyfile` do capítulo anterior, ou o container do teste anterior estiver ativo, pare-os. Depois:

```bash
docker compose up -d
docker compose ps
curl --cacert "$(mkcert -CAROOT)/rootCA.pem" https://api.rango.test:8443/restaurantes
```

O `--cacert` diz ao `curl` para confiar na CA local do `mkcert`, já que nem todo `curl` consulta o mesmo repositório de certificados que o navegador. A resposta é a mesma lista de antes, agora passando pelo Nginx com TLS. Para ver os logs dos dois serviços juntos, use `docker compose logs -f`.

Falta avisar o front. Em `frontend/.env.local`:

```bash
VITE_API_URL=https://api.rango.test:8443
```

Reinicie o `npm run dev` e abra `https://rango.test:5173`. O React busca os restaurantes pelo Nginx, com o cadeado no lugar. O Uvicorn deixou de cuidar do TLS: o certificado agora mora no proxy, como vai morar em produção.

## Quando um servidor vira dez: orquestração

Com o Compose, o Rangô roda igual em qualquer máquina que tenha Docker. Agora pense um pouco mais adiante. O Rangô cresce, e um servidor não basta. Você passa a ter dez servidores e trinta containers da API. Surgem perguntas novas:

- Em qual servidor cada container deve rodar, considerando a CPU e a memória livres de cada um?
- Se um servidor desligar, quem recria os containers dele em outro lugar?
- Como trocar a versão 0.1.1 pela 0.1.2 sem tirar o Rangô do ar?
- Como o Nginx sabe os endereços dos containers da API, se eles mudam a cada recriação?

Responder isso com scripts e SSH é possível, e é um caminho garantido para incidentes. Um **orquestrador** de containers é o sistema que assume essas decisões. Você não diz a ele "rode este container naquele servidor"; você diz "quero três cópias da API na versão 0.1.1, cada uma com 128 MB de memória", e ele trabalha continuamente para que a realidade fique igual ao que você pediu.

Se essa ideia lembrou o React, a comparação é boa. No React, você não manipula o DOM: você declara como a tela deve ficar a partir do estado, e o React calcula as diferenças e aplica as mudanças. Um orquestrador faz isso com infraestrutura. Você declara o **estado desejado**, ele observa o **estado atual** e age para aproximar um do outro. Esse ciclo se chama **reconciliação**, e ele nunca para: se um container morrer às 3h, o estado atual fica com duas cópias, o desejado continua pedindo três, e o orquestrador cria outra.

O orquestrador mais usado no mercado é o **Kubernetes**, abreviado como K8s. Ele nasceu no Google, inspirado no sistema interno que a empresa usava para rodar os próprios serviços, e hoje é mantido pela Cloud Native Computing Foundation.

## Kubernetes em quatro conceitos

O Kubernetes tem dezenas de tipos de objeto. Para entender como ele funciona, quatro bastam por enquanto.

Um **cluster** é o conjunto de máquinas gerenciadas pelo Kubernetes. As máquinas que rodam os seus containers são os **nós** (*nodes*). Um grupo separado de componentes, a **control plane**, guarda o estado desejado, decide onde cada coisa roda e executa os ciclos de reconciliação. Você fala com a control plane pela linha de comando, o `kubectl`, enviando arquivos YAML.

Um **pod** é a menor unidade que o Kubernetes executa. Em geral, um pod contém um container, mas pode conter alguns que precisam ficar juntos e compartilhar rede e disco. Cada pod recebe um IP próprio dentro do cluster. Pods são descartáveis: o Kubernetes os mata e os recria o tempo todo, em outros nós e com outros IPs. Você quase nunca cria um pod diretamente.

Um **deployment** é o que você cria no lugar. Ele declara qual imagem rodar, quantas réplicas manter e como trocar de versão. Quando você muda a imagem de `0.1.1` para `0.1.2`, o deployment faz um *rolling update*: sobe pods novos aos poucos e só derruba os antigos quando os novos estão prontos. O capítulo 6 volta a essa e a outras estratégias de deploy.

Um **service** resolve o problema dos IPs que mudam. Ele dá um nome e um IP estáveis para um grupo de pods, escolhido por rótulos (*labels*), e distribui as requisições entre eles. O Nginx, ou qualquer outro pod, chama `http://rango-api` e o service entrega para um dos pods vivos naquele momento. Funciona como uma interface estável na frente de implementações que vêm e vão.

Existem muitos outros objetos (Ingress para tráfego externo, ConfigMap e Secret para configuração, por exemplo), mas com esses quatro você já consegue ler a maior parte dos arquivos de um projeto real.

### Mão na massa: o Rangô num cluster local

Para experimentar sem gastar nada, use o **kind** (*Kubernetes in Docker*), que cria um cluster inteiro dentro de containers no seu notebook. Pré-requisitos: Docker, `kind` e `kubectl` instalados (as páginas oficiais têm instaladores para cada sistema operacional).

Crie o cluster e carregue nele a imagem que você construiu, já que o cluster não enxerga as imagens locais do seu Docker:

```bash
kind create cluster --name rango
kind load docker-image rango-api:0.1.1 --name rango
```

Agora descreva o estado desejado em `k8s/api.yaml`, na raiz do projeto:

```yaml
# k8s/api.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rango-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: rango-api
  template:
    metadata:
      labels:
        app: rango-api
    spec:
      containers:
        - name: api
          image: rango-api:0.1.1
          ports:
            - containerPort: 8000
          env:
            - name: CORS_ORIGINS
              value: "https://rango.test:5173"
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: rango-api
spec:
  selector:
    app: rango-api
  ports:
    - port: 80
      targetPort: 8000
```

O deployment pede três réplicas. O `readinessProbe` só libera tráfego para um pod depois que `/health` responder, um primeiro *health check* que o capítulo 4 aprofunda. O bloco `resources` reserva um décimo de núcleo (`100m`) e 128 MB por pod e mata o que passar de 256 MB. O service seleciona os pods com o rótulo `app: rango-api` e liga a porta 80 à 8000 deles.

Aplique e observe:

```bash
kubectl apply -f k8s/api.yaml
kubectl get pods
```

```text
NAME                         READY   STATUS    RESTARTS   AGE
rango-api-6b8f7d9c5f-2xkqp   1/1     Running   0          15s
rango-api-6b8f7d9c5f-h7vzn   1/1     Running   0          15s
rango-api-6b8f7d9c5f-tq4lm   1/1     Running   0          15s
```

Agora a parte divertida. Apague um pod, como se o servidor dele tivesse pegado fogo, e liste de novo:

```bash
kubectl delete pod rango-api-6b8f7d9c5f-2xkqp
kubectl get pods
```

Em poucos segundos, aparece um pod com outro nome no lugar do apagado. Você não pediu isso. O deployment continua declarando três réplicas, o estado atual tinha duas, e a reconciliação resolveu a diferença. (Use o nome que apareceu no seu terminal; o sufixo é aleatório.)

Para acessar o service a partir do notebook, abra um túnel temporário:

```bash
kubectl port-forward service/rango-api 8000:80
```

E, em outro terminal, `curl http://localhost:8000/restaurantes` devolve a lista de sempre, atendida por algum dos três pods.

Quando terminar, apague o cluster. Ele consome memória do seu notebook, mas nada fora dele:

```bash
kind delete cluster --name rango
```

### Você precisa de Kubernetes?

Para o Rangô de hoje, não. Uma API, um front e um banco cabem com folga num servidor com Compose, ou nos serviços gerenciados da Parte II. Kubernetes cobra caro em complexidade: control plane, atualizações a cada poucos meses, redes, permissões e muito YAML. Ele compensa com muitos serviços, várias equipes e gente dedicada a operar a plataforma. Mesmo assim, estado desejado, réplicas, health checks e nomes estáveis aparecem em toda plataforma de containers, inclusive nas da AWS. No capítulo 17, o Rangô vai para o Amazon ECS com Fargate, e você vai ver também quando vale escolher o Amazon EKS, a versão gerenciada de Kubernetes da AWS.

## Armadilhas e casos reais

> **Armadilha:** usar a tag `latest`. `latest` é só um nome, sem nenhuma garantia de ser a versão mais nova, e muda de conteúdo a cada push. Dois servidores que baixaram `rango-api:latest` em dias diferentes podem estar rodando códigos diferentes, e o rollback vira adivinhação. Use versões explícitas (`0.1.1`) ou o hash do commit como tag.

> **Armadilha:** segredos dentro da imagem. Se o Dockerfile fizer `COPY .env .` e depois `RUN rm .env`, o arquivo continua na camada anterior, e qualquer pessoa com acesso à imagem consegue extraí-lo. Valores passados com `ENV` ou `ARG` aparecem em `docker history`. Segredos entram em tempo de execução, por variável de ambiente ou por um gerenciador de segredos, assunto do capítulo 16.

> **Na vida real:** em abril de 2021, a Codecov, ferramenta de cobertura de testes usada em pipelines de CI de milhares de empresas, revelou que um erro no processo de criação das suas imagens Docker permitiu que um atacante extraísse uma credencial. Com ela, o atacante alterou o script de upload que os clientes baixavam nos seus pipelines, e o script adulterado passou a enviar as variáveis de ambiente desses pipelines (com tokens e chaves) para um servidor externo. O acesso começou no fim de janeiro e só foi descoberto em abril, quando um cliente notou que o hash do script baixado não batia com o publicado no GitHub.

> **Armadilha:** gravar dados dentro do container. O sistema de arquivos de um container é descartável: quando ele é recriado, tudo o que foi escrito ali some. Uploads e arquivos de banco de dados precisam de um volume ou, melhor, de um serviço externo. As fotos dos pratos do Rangô vão parar no Amazon S3 no capítulo 11.

> **Armadilha:** construir no Mac com Apple Silicon e rodar num servidor Intel. A imagem é construída para a arquitetura da máquina que fez o build (`arm64`), e o servidor (`amd64`) devolve `exec format error` ao tentar rodá-la. Use `docker build --platform linux/amd64` ou construa no CI, na arquitetura do destino.

> **Dica:** prefira a forma de lista no `CMD` (`CMD ["uvicorn", ...]`) à forma de texto (`CMD uvicorn ...`). Na forma de texto, o Docker roda o comando através de `/bin/sh -c`, e o `SIGTERM` enviado pelo `docker stop` pode não chegar ao Uvicorn. Depois de 10 segundos, o Docker desiste e manda `SIGKILL`, cortando requisições no meio.

> **Dica:** a imagem `python:3.12` completa passa de 1 GB; a `python:3.12-slim` fica perto de um décimo disso (valores aproximados). Imagens menores baixam mais rápido e trazem menos programas com falhas conhecidas. Evite o Alpine para Python: com a biblioteca C dele (musl), muitos pacotes compilam do zero.

> **Na vida real:** em fevereiro de 2018, a empresa de segurança RedLock relatou que atacantes encontraram um console administrativo do Kubernetes da Tesla acessível pela internet sem senha. Num dos pods havia credenciais da conta de nuvem da empresa, e os atacantes usaram o cluster para minerar criptomoeda, escondendo o tráfego para dificultar a detecção. Um painel de administração exposto é uma porta aberta para toda a infraestrutura que ele controla.

## Resumo

- Servidor quase sempre é uma VM: um hypervisor divide uma máquina física em várias, cada uma com o próprio kernel.
- No Linux, a aplicação roda com um usuário sem privilégios, numa porta alta. `SIGTERM` pede para encerrar, `SIGKILL` força, `SIGHUP` chega quando o terminal fecha.
- O systemd mantém serviços rodando depois de falhas e reboots, e guarda os logs (`journalctl`).
- O proxy reverso (Nginx) atende as portas 80 e 443, termina o TLS, roteia pelo cabeçalho `Host`, serve arquivos estáticos e repassa a API para o Uvicorn em `127.0.0.1:8000`.
- "Na minha máquina funciona" vem do ambiente ao redor do código. Containers empacotam o ambiente junto com a aplicação.
- Container é um processo isolado por namespaces e limitado por cgroups, compartilhando o kernel da máquina. Imagem é o pacote em camadas; container é a imagem em execução; registry guarda e distribui imagens.
- O Rangô ganhou `requirements.txt`, `backend/Dockerfile`, `backend/.dockerignore`, `compose.yaml` e `nginx/rango.conf`. A API roda como `rango-api:0.1.1` atrás de um Nginx com o certificado do `mkcert` em `https://api.rango.test:8443`.
- Orquestradores trabalham com estado desejado e reconciliação. No Kubernetes, pods rodam containers, deployments mantêm réplicas e trocam versões, e services dão um nome estável a um grupo de pods.
- Kubernetes compensa em sistemas grandes, com equipe para operá-lo. Para o Rangô de hoje, sobra.

## Ponte: o dia em que o Rangô apareceu na TV

O Rangô agora tem um pacote que roda igual em qualquer lugar e um proxy que cuida do TLS. Coloque isso num servidor com 2 vCPUs, e ele aguenta tranquilo as poucas centenas de pedidos por dia da fase atual.

Até a terça-feira em que a sua sócia liga, eufórica: um programa de culinária da TV vai mostrar a Cantina da Nona na quinta, e o apresentador vai dizer o nome do Rangô ao vivo. Você faz as contas. Se uma fração pequena dos espectadores abrir o app nos minutos seguintes, o tráfego multiplica por cinquenta. As três réplicas que você viu no kind rodavam todas no seu notebook. No servidor, o processador vai a 100%, as requisições começam a esperar na fila do Nginx, e o tempo de resposta passa de 80 milissegundos para 12 segundos. Um servidor só não aguenta. Compra-se um maior ou vários pequenos? Como a sua sócia, digitando `rango.com.br`, chega ao servidor que está menos ocupado? E o que acontece com quem estava no meio de um pedido quando o servidor caiu? No próximo capítulo, você vai ver como uma arquitetura escala de verdade.

## Referências

- Docker, documentação oficial: https://docs.docker.com/
- Referência do Dockerfile: https://docs.docker.com/reference/dockerfile/
- Docker Compose: https://docs.docker.com/compose/
- Imagem oficial do Python no Docker Hub: https://hub.docker.com/_/python
- Open Container Initiative: https://opencontainers.org/
- systemd, unidades de serviço: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- Nginx, módulo de proxy: https://nginx.org/en/docs/http/ngx_http_proxy_module.html
- Uvicorn, deploy e proxies: https://www.uvicorn.org/deployment/
- Kubernetes, pods: https://kubernetes.io/docs/concepts/workloads/pods/
- Kubernetes, deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes, services: https://kubernetes.io/docs/concepts/services-networking/service/
- kind: https://kind.sigs.k8s.io/
- Codecov, comunicado sobre o incidente de 2021: https://about.codecov.io/security-update/
- Fortune, sobre o caso da Tesla (fev/2018): https://fortune.com/2018/02/20/tesla-hack-amazon-cloud-cryptocurrency-mining/
