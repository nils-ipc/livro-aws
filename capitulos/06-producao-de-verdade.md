# Produção de verdade

No capítulo anterior, a confirmação do pedido deixou de esperar o restaurante e o e-mail. A API grava o pedido, publica `pedido.criado` num stream do Redis e responde em 2,5 segundos, enquanto workers idempotentes fazem o resto, com retentativas, backoff e uma DLQ para as mensagens que não têm conserto. O sistema ficou mais rápido e mais tolerante a falhas de terceiros. Só que toda essa engenharia parte de uma premissa silenciosa: o banco de dados continua lá amanhã.

## Sábado, 3h40

Voltemos à madrugada em que o disco do Postgres falhou. Você está de pijama, com o terminal aberto, e encontrou o tal arquivo `.sql` de três semanas atrás. Decide restaurar. O primeiro `psql -f` para no meio com um erro de função inexistente, porque o dump foi gerado por uma versão do Postgres diferente da que roda hoje. Você ajusta, tenta de novo, e às 6h15 o banco está de pé.

Com um buraco de três semanas.

Todos os pedidos feitos depois daquele backup sumiram. O repasse para a Cantina da Nona e para o Sabor do Sertão vai ter que ser reconstruído a partir do extrato do gateway de pagamento, linha por linha. Às 7h, o primeiro cliente reclama no Instagram que o histórico de pedidos dele está vazio. Você descobre a queda pelo Instagram, porque nada no Rangô avisou ninguém.

Na segunda-feira, a sócia pergunta o que precisa mudar. A lista é longa: backups automáticos e testados, uma cópia do banco pronta para assumir, um jeito de recriar o servidor sem depender da memória de ninguém, deploys que não sejam um ato de fé e alguma forma de enxergar o sistema. Este capítulo percorre essa lista, e cada item vira um serviço concreto na Parte II.

## Backup só conta depois do primeiro restore

O script do desenvolvedor que saiu em março tinha três defeitos, e eles são os mais comuns do mundo. Rodava numa máquina que não era servidor, gravava a cópia num lugar só e nunca foi testado. Qualquer um dos três basta para você perder dados.

Comece pelos tipos de backup de um banco relacional, porque eles se comportam de forma bem diferente.

O **backup lógico** é um retrato do conteúdo num arquivo que o próprio banco sabe reler. No Postgres, é o `pg_dump`. Ele é portável e permite restaurar só uma tabela, mas captura um instante: tudo o que aconteceu depois está perdido. Num banco grande, gerar e restaurar o dump demora horas.

O **backup físico** copia os arquivos de dados como estão no disco. O que muda o jogo é combiná-lo com o **WAL** (*write-ahead log*): antes de alterar qualquer dado, o Postgres escreve num log sequencial o que vai fazer. Com uma cópia física de domingo e todos os arquivos de WAL desde então, dá para reproduzir o histórico até qualquer segundo. Isso se chama **point-in-time recovery** (PITR), e é como ter o `git log` inteiro do banco: você faz *checkout* em "sábado, 3h11", um minuto antes do disco falhar. Ou um minuto antes de alguém rodar um `DELETE` sem `WHERE`, o desastre mais frequente na prática.

Depois vem o lugar onde a cópia mora. A regra clássica é a **3-2-1**: três cópias, em dois tipos de mídia, uma delas fora do local. Na nuvem, "fora do local" vira outra região ou outra conta, para que o mesmo erro (ou o mesmo invasor) não apague banco e backup de uma vez.

Por último, o teste. Restaurar precisa ser um procedimento automático e frequente, que confere o resultado: a tabela existe, a contagem bate, o pedido mais recente tem a data esperada. Descobrir que o backup está quebrado numa terça à tarde é bem melhor que num sábado às 3h40.

## RPO e RTO: quanto perder e quanto esperar

Duas perguntas da ponte do capítulo anterior têm nome técnico.

**RPO** (*Recovery Point Objective*) é a quantidade máxima de dados que você aceita perder, medida em tempo. Se o RPO é de cinco minutos, depois de um desastre você pode voltar a um estado de no máximo cinco minutos atrás. O RPO do Rangô naquela madrugada era, sem que ninguém tivesse escolhido, de três semanas.

**RTO** (*Recovery Time Objective*) é quanto tempo o sistema pode ficar fora do ar até voltar a funcionar. Naquela noite, foram cerca de três horas entre a falha e o banco de pé, sem contar o trabalho de reconstruir os repasses.

Os dois números são decisões de negócio, e cada minuto a menos custa dinheiro. Um RPO de 24 horas sai com um `pg_dump` noturno; um de cinco minutos exige arquivamento contínuo de WAL; um próximo de zero exige uma réplica que confirma cada escrita. Com o RTO, o mesmo: restaurar um dump de 200 GB leva horas, promover uma réplica já ligada leva segundos.

Para o Rangô, a conversa com a sócia termina assim: perder até cinco minutos de pedidos é tolerável, porque o gateway de pagamento guarda as cobranças; ficar mais de uma hora fora numa sexta à noite, não.

## Réplicas: primária, leitura e failover

Backup resolve o "quanto perder". Para encurtar o "quanto esperar", você precisa de outra cópia do banco já ligada.

Na **replicação**, um servidor é a **primária**: recebe todas as escritas. Os outros são **réplicas**: recebem o fluxo de WAL da primária e aplicam as mesmas mudanças, na mesma ordem. É parecido com um `git pull` contínuo, feito a cada poucos milissegundos.

A replicação pode ser **síncrona** ou **assíncrona**, e isso mexe direto no RPO. Na síncrona, a primária só confirma o `COMMIT` depois que a réplica recebeu a mudança: nada confirmado se perde, mas cada escrita fica mais lenta e, se a réplica travar, as escritas travam junto. Na assíncrona, a primária confirma na hora e envia logo depois, então as últimas transações podem não ter chegado à réplica no momento da falha. Esse atraso é o *replication lag*, normalmente de milissegundos, que pode virar minutos sob carga.

Uma réplica tem duas utilidades. A primeira é servir leituras, como o histórico de pedidos e os relatórios dos restaurantes, aliviando a primária. A pegadinha é o lag: o cliente confirma um pedido, a página seguinte lê da réplica, e o pedido ainda não está lá. É a consistência eventual do capítulo 5 dentro do banco. Leia da primária o que o usuário acabou de escrever.

A segunda é o **failover**: quando a primária morre, uma réplica é promovida e a aplicação passa a escrever nela. Automatizado, isso leva segundos, mas traz um risco novo, o **split brain**. Se a primária só perdeu a rede por 30 segundos e o sistema promoveu a réplica, você pode ter dois servidores aceitando escritas, cada um com uma versão dos pedidos. Bons sistemas de failover isolam a primária antiga antes de a nova assumir.

> **Armadilha:** réplica protege contra falha de hardware, mas copia os erros com a mesma fidelidade. Um `DROP TABLE pedidos` na primária chega à réplica em milissegundos. Por isso réplica e backup resolvem problemas diferentes, e você precisa dos dois.

No capítulo 12, o Amazon RDS vai fazer quase tudo isso por você: backups automáticos com PITR, uma réplica síncrona em outra zona para failover e réplicas de leitura assíncronas. Saber o que acontece por baixo é o que permite escolher a configuração certa.

## Alta disponibilidade e recuperação de desastres

Os dois termos andam juntos e confundem.

**Alta disponibilidade** (HA, de *high availability*) é continuar funcionando quando um componente falha, de preferência sem ninguém perceber. Várias instâncias da API atrás de um balanceador, como no capítulo 4, e uma réplica pronta para failover lidam com falhas pequenas e frequentes: um processo que morre, um disco que falha.

**Recuperação de desastres** (DR, de *disaster recovery*) é o plano para algo grande: um data center inteiro fora do ar, um ataque de *ransomware*, um erro humano que apaga produção. DR mede-se em RPO e RTO e envolve backups em outro local, procedimentos escritos e ensaios.

Disponibilidade costuma ser expressa em "noves". Usando um mês de 730 horas, a tabela fica assim:

| Disponibilidade | Indisponibilidade permitida por mês |
|-----------------|-------------------------------------|
| 99% | cerca de 7,3 horas |
| 99,9% | cerca de 43,8 minutos |
| 99,99% | cerca de 4,4 minutos |
| 99,999% | cerca de 26 segundos |

Cada nove a mais custa bem mais que o anterior. E existe uma conta que surpreende: disponibilidades de componentes em série se multiplicam. Se a API tem 99,9% e o banco também, o Rangô como um todo tem no máximo 99,8%, porque precisa dos dois ao mesmo tempo. Some o Redis, o gateway de pagamento e o DNS, e o número cai mais um pouco. Redundância melhora essa conta; cada dependência nova piora.

As estratégias de DR formam uma escada de custo. Na base, **backup e restauração**: você recria tudo a partir dos backups, com RTO de horas. Acima, o *pilot light* (banco replicado em outro local, servidores desligados e prontos) e o *warm standby* (uma cópia reduzida rodando o tempo todo). No topo, dois ambientes ativos ao mesmo tempo, com RTO próximo de zero e uma conta proporcional. Para o Rangô de hoje, backup e restauração bem feito já seria uma enorme melhora, desde que recriar o servidor não dependa de lembrar 40 comandos digitados há um ano.

## Segredos fora do código

Antes de colocar as mãos no banco, um detalhe que atrapalha quase todo projeto: onde fica a senha dele.

No Rangô, até agora, configuração entrou por variáveis de ambiente, e isso continua certo. O problema é de onde essas variáveis vêm. Um `.env` commitado por engano fica no histórico do git mesmo depois de apagado, e qualquer clone antigo do repositório carrega a senha. Uma senha colada no Slack fica no histórico do Slack. Uma senha escrita no `compose.yaml` vai para o repositório junto com ele.

A **gestão de segredos** se apoia em poucas regras. O segredo mora num lugar próprio, com controle de quem lê, e a aplicação o recebe em tempo de execução, nunca no código nem na imagem Docker. Cada ambiente tem os próprios segredos. E a **rotação** precisa ser possível sem deploy, porque um dia você vai trocar uma senha às pressas.

Na AWS, esse lugar próprio será o AWS Systems Manager Parameter Store ou o AWS Secrets Manager, assunto do capítulo 16. Localmente, o Docker Compose tem um mecanismo de *secrets* que monta o conteúdo de um arquivo dentro do container, em `/run/secrets/`, sem passar por variável de ambiente. Vamos usá-lo agora.

## Mão na massa: backup, desastre e restore testado

O Rangô ainda guarda os pedidos no Redis, e a mudança definitiva para o Postgres acontece no capítulo 12, com o RDS. Para treinar backup e restauração, vamos subir um Postgres no Compose com uma tabela de pedidos preenchida com dados de teste.

Pré-requisitos: Docker com Compose v2, `openssl` e o projeto do capítulo 5. Os comandos rodam na raiz do projeto, num terminal bash (no Windows, use o WSL ou o Git Bash).

Primeiro, a senha, gerada aleatoriamente e mantida fora do git:

```bash
mkdir -p secrets backups scripts
openssl rand -base64 24 | tr -d '\n' > secrets/db_password.txt
printf 'secrets/\nbackups/\n' >> .gitignore
```

Agora acrescente ao `compose.yaml` o serviço `db`, o volume e o segredo. As chaves `volumes` e `secrets` de nível superior ficam fora de `services`:

```yaml
# compose.yaml (trechos novos)
services:
  db:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: rango
      POSTGRES_DB: rango
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_password
    volumes:
      - dados-db:/var/lib/postgresql/data
    restart: unless-stopped

volumes:
  dados-db:

secrets:
  db_password:
    file: ./secrets/db_password.txt
```

A imagem oficial do Postgres aceita a variante `_FILE` de várias variáveis e lê a senha do arquivo montado. Assim, `docker inspect` não mostra a senha nas variáveis do container. Não há `ports`: o banco só é alcançável pela rede interna do Compose, a mesma lição do capítulo 1 sobre bancos expostos.

Suba o banco e crie 5 mil pedidos de teste. O `psql` roda dentro do container, por socket local, então não pede senha:

```bash
docker compose up -d db
docker compose exec -T db psql -U rango -d rango <<'SQL'
CREATE TABLE pedidos (
    id bigserial PRIMARY KEY,
    restaurante text NOT NULL,
    total numeric(10, 2) NOT NULL,
    criado_em timestamptz NOT NULL DEFAULT now()
);
INSERT INTO pedidos (restaurante, total)
SELECT (ARRAY['Cantina da Nona', 'Sabor do Sertão'])[1 + i % 2],
       round((20 + random() * 80)::numeric, 2)
FROM generate_series(1, 5000) AS i;
SQL
```

O script de backup usa o formato *custom* do `pg_dump` (`--format=custom`), que é compactado e permite restaurar tabelas isoladas com o `pg_restore`. Repare que o `pg_dump` roda dentro do container do banco. Isso garante que a versão da ferramenta é a mesma do servidor, e o caso da GitLab, mais adiante, mostra por que isso importa.

```bash
#!/usr/bin/env bash
# scripts/backup.sh
set -euo pipefail

arquivo="backups/rango-$(date -u +%Y%m%dT%H%M%SZ).dump"
docker compose exec -T db pg_dump -U rango -d rango --format=custom > "$arquivo"
echo "backup gravado em $arquivo ($(du -h "$arquivo" | cut -f1))"
```

O script de teste é a parte que faltava ao Rangô. Ele cria um Postgres descartável, restaura o backup nele, compara com a origem e apaga tudo no fim, dê certo ou não:

```bash
#!/usr/bin/env bash
# scripts/testar-restore.sh
set -euo pipefail

arquivo="${1:?uso: scripts/testar-restore.sh backups/ARQUIVO.dump}"
teste="rango-restore-teste"

docker run -d --name "$teste" \
  -e POSTGRES_USER=rango -e POSTGRES_DB=rango \
  -e POSTGRES_PASSWORD="$(openssl rand -hex 16)" \
  postgres:17-alpine > /dev/null
trap 'docker rm -f "$teste" > /dev/null' EXIT

# -h 127.0.0.1: durante a inicialização, a imagem sobe um servidor
# temporário só no socket; o TCP só responde quando o banco final está pronto
until docker exec "$teste" pg_isready -h 127.0.0.1 -U rango -d rango > /dev/null 2>&1; do
  sleep 1
done

docker exec -i "$teste" pg_restore -U rango -d rango --no-owner < "$arquivo"

consulta="SELECT count(*) FROM pedidos"
restaurado=$(docker exec "$teste" psql -U rango -d rango -tAc "$consulta")
echo "pedidos no backup restaurado: $restaurado"

if [ "$restaurado" -lt 1 ]; then
  echo "FALHA: backup restaurado sem pedidos" >&2
  exit 1
fi
echo "OK: restore testado com sucesso"
```

Rode os dois:

```bash
chmod +x scripts/*.sh
scripts/backup.sh
scripts/testar-restore.sh backups/rango-*.dump
```

```text
backup gravado em backups/rango-20261016T021500Z.dump (128K)
pedidos no backup restaurado: 5000
OK: restore testado com sucesso
```

Agora vamos sentir o RPO. Depois do backup, chegam mais 37 pedidos. Em seguida, acontece o desastre:

```bash
docker compose exec -T db psql -U rango -d rango -c \
  "INSERT INTO pedidos (restaurante, total) SELECT 'Cantina da Nona', 42.90 FROM generate_series(1, 37)"
docker compose exec -T db psql -U rango -d rango -c "DROP TABLE pedidos"
```

Restaure o backup no banco principal e conte:

```bash
docker compose exec -T db pg_restore -U rango -d rango --no-owner < backups/rango-*.dump
docker compose exec -T db psql -U rango -d rango -tAc "SELECT count(*) FROM pedidos"
```

```text
5000
```

Os 37 pedidos feitos depois do backup se foram. Com um `pg_dump` por hora, seu RPO é de até uma hora. Encurtar isso para minutos é o papel do arquivamento contínuo de WAL, que o RDS oferece pronto no capítulo 12.

Falta o backup rodar sozinho, ir para outro lugar e ter o restore testado periodicamente, com alerta se falhar. Na Parte II, o destino será o Amazon S3; localmente, um `cron` no servidor bastaria, desde que o servidor não seja o notebook de ninguém.

> **Dica:** um teste de restore bom mede também o tempo. Se restaurar levou 40 minutos no teste, seu RTO real nunca vai ser menor que 40 minutos, por mais que o documento de arquitetura diga outra coisa.

Quando terminar, `docker compose down` para os containers. O volume `dados-db` continua existindo; para apagá-lo também, use `docker compose down -v`.

## Infraestrutura como código

Voltemos ao RTO. Para recriar o servidor do Rangô do zero, alguém precisaria instalar o Docker, criar o usuário `rango`, configurar o Nginx, instalar os certificados, ajustar o firewall e lembrar de um parâmetro do kernel que foi mudado num dia de pânico. Se isso está na cabeça de uma pessoa, o RTO depende das férias dela.

**Infraestrutura como código** (IaC) significa descrever servidores, redes, bancos, balanceadores e permissões em arquivos de texto versionados no git, e deixar uma ferramenta criar e atualizar tudo a partir deles. A melhor analogia para quem vem de Django ou Alembic é a *migration*: em vez de alterar o banco à mão no console, você escreve a mudança num arquivo, revisa num pull request e aplica de forma repetível. IaC faz isso com a infraestrutura inteira.

Você já usa uma forma disso. O `compose.yaml` do Rangô descreve containers, redes, volumes e segredos de forma declarativa: você diz o estado desejado e o Compose descobre o que precisa criar, recriar ou manter. A diferença para a produção é a escala do que se descreve.

As ferramentas se dividem em duas famílias. As **declarativas** descrevem o estado final ("quero dois servidores e um banco com estas configurações"), e a ferramenta calcula a diferença entre o que existe e o que foi pedido, a mesma ideia de reconciliação que você viu no Kubernetes. Terraform, AWS CloudFormation e AWS CDK estão nessa família. As **imperativas** descrevem passos ("instale isto, depois copie aquilo"), como scripts de shell; elas funcionam bem na primeira execução e mal na segunda.

Recriar o ambiente depois de um desastre vira um comando, e criar uma homologação idêntica à produção também. Toda mudança passa por revisão, então "quem abriu a porta 5432 para a internet?" tem resposta no `git blame`.

O inimigo da IaC é o **drift**: alguém muda algo direto no console, "só dessa vez", e o código deixa de descrever a realidade. A regra que funciona é tratar o console como somente leitura em produção.

No capítulo 15, o Rangô inteiro será descrito com o AWS CDK em Python, e a partir dali todo exemplo do livro usa código em vez de cliques.

## CI/CD: a esteira entre o commit e a produção

O deploy do Rangô ainda é uma pessoa rodando comandos. Em geral na sexta, às 18h, porque é quando a funcionalidade ficou pronta.

**Integração contínua** (CI, de *continuous integration*) é a prática de, a cada push ou pull request, um servidor rodar automaticamente os testes, o *linter* e o build, para descobrir em minutos que uma mudança quebrou algo. **Entrega contínua** e **deploy contínuo** (ambos chamados de CD) estendem a esteira: na entrega, toda versão aprovada está pronta para produção e alguém aperta o botão; no deploy contínuo, ela vai sozinha.

O conjunto se chama *pipeline*, uma sequência de etapas em que cada uma só começa se a anterior passou: testes, build da imagem com tag única (o hash do commit, nunca `latest`), envio ao registry, homologação e produção. O ganho mais subestimado é a previsibilidade. Um deploy que roda igual todas as vezes deixa de depender de quem está de plantão, e dez deploys pequenos por dia ficam mais seguros que um gigante por mês, porque uma mudança pequena é fácil de achar e de reverter.

### Mão na massa: o primeiro pipeline do Rangô

Vamos usar o GitHub Actions, que roda de graça para repositórios públicos e tem uma cota mensal de minutos para privados. Primeiro, um teste. Crie `backend/requirements-dev.txt`:

```text
pytest
httpx
```

O `httpx` é exigido pelo `TestClient` do FastAPI. Agora o teste em `backend/tests/test_saude.py`:

```python
# backend/tests/test_saude.py
from fastapi.testclient import TestClient

from app.main import app

cliente = TestClient(app)


def test_health_responde_ok():
    resposta = cliente.get("/health")
    assert resposta.status_code == 200
    assert resposta.json() == {"status": "ok"}


def test_restaurantes_tem_taxa_formatada():
    resposta = cliente.get("/restaurantes")
    assert resposta.status_code == 200
    assert all("taxa_entrega_fmt" in r for r in resposta.json())
```

O segundo teste precisa do Redis, porque `/restaurantes` usa cache. O pipeline vai subir um Redis como *service container*. Crie `.github/workflows/ci.yaml` na raiz do repositório:

```yaml
# .github/workflows/ci.yaml
name: ci

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  testes:
    runs-on: ubuntu-24.04
    services:
      redis:
        image: redis:7.4-alpine
        ports:
          - 6379:6379
    env:
      REDIS_URL: redis://localhost:6379/0
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-python@v6
        with:
          python-version: "3.12"
      - run: pip install -r requirements.txt -r requirements-dev.txt
      - run: python -m pytest -q

  imagem:
    needs: testes
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v5
      - run: docker build -t rango-api:${{ github.sha }} backend
```

O bloco `permissions` limita o token do pipeline a ler o código, menor privilégio desde o primeiro arquivo. O job `imagem` só roda se `testes` passar, por causa do `needs`, e a tag é o hash do commit, rastreável até a linha que gerou o build. O `python -m pytest` coloca o diretório atual no caminho de importação, para que `from app.main import app` funcione. Se alguém quebrar o `/health`, o pull request fica vermelho antes de qualquer revisão humana.

O pipeline ainda para no build, porque falta o lugar para onde mandar a imagem. No capítulo 18, ele ganha o envio ao Amazon ECR e o deploy no Amazon ECS, autenticando na AWS por OIDC, sem chave de longa duração guardada no GitHub.

## Estratégias de deploy: como trocar o motor com o carro andando

Com o pipeline pronto, a pergunta muda: como colocar a versão nova no ar sem derrubar a antiga de uma vez? Há três estratégias principais.

No **rolling update**, as instâncias são trocadas aos poucos: uma sai, a versão nova entra, passa no health check, e só então a próxima é trocada. É o que o Deployment do Kubernetes fazia no capítulo 3. Não exige capacidade extra, mas por alguns minutos as duas versões atendem juntas, e voltar atrás é outro rolling update no sentido inverso.

No **blue/green**, você mantém dois ambientes completos. O azul atende produção; o verde recebe a versão nova e é testado sem tráfego real. Depois, o balanceador passa a apontar para o verde de uma vez, e o rollback é apontar de volta, em segundos. O custo é o dobro da capacidade durante a troca.

No **canary**, a versão nova recebe uma fração pequena do tráfego real, digamos 5%, enquanto você observa erros e latência. Se os números ficarem bons, a fração sobe até 100%; se piorarem, só 5% dos usuários sentiram por alguns minutos. O nome vem dos canários que mineiros levavam às minas de carvão. Essa estratégia depende de métricas confiáveis para decidir.

Complementam essas estratégias os *feature flags*: o código vai para produção desligado e uma configuração liga a funcionalidade para alguns usuários, separando o deploy do lançamento.

> **Armadilha:** a estratégia de deploy cuida da aplicação; o banco continua sendo um só. Se a versão nova renomeia a coluna `total` para `valor_total`, a versão antiga, que ainda atende durante o rolling ou o canary, começa a falhar. A saída é o padrão *expand/contract*: primeiro uma migration que adiciona a coluna nova e mantém a antiga, depois o código que usa a nova, e só num deploy posterior a migration que remove a antiga. Toda migration precisa ser compatível com a versão anterior do código.

### Mão na massa: um canário com o Nginx

O Nginx do Rangô já balanceia entre as instâncias da API. Com pesos no `upstream`, ele faz um canário simples. Gere a imagem nova, que vai incluir os logs estruturados da próxima seção:

```bash
docker build -t rango-api:0.5.0 backend
```

No `compose.yaml`, acrescente um serviço `api-canario` igual ao `api`, mas com a imagem nova e um nome de host fixo. Lembre que o middleware do capítulo 4 usa o nome do host no cabeçalho `X-Rango-Instancia`:

```yaml
# compose.yaml (trecho novo)
  api-canario:
    image: rango-api:0.5.0
    hostname: canario
    environment:
      CORS_ORIGINS: "https://rango.test:5173"
      REDIS_URL: "redis://redis:6379/0"
    depends_on:
      - redis
    restart: unless-stopped
```

Em `nginx/rango.conf`, adicione o canário ao `upstream` e dê peso às instâncias estáveis:

```nginx
upstream rango_api {
    server api:8000 weight=3 max_fails=2 fail_timeout=10s;
    server api-canario:8000 weight=1 max_fails=2 fail_timeout=10s;
}
```

Atenção à conta. O nome `api` resolve para três IPs, porque a API roda com `--scale api=3`, e cada IP herda o peso 3. São 9 partes para a versão estável e 1 para o canário, ou seja, 10% do tráfego. Suba tudo e faça 100 requisições:

```bash
docker compose up -d --scale api=3
docker compose restart proxy
for i in $(seq 100); do
  curl -sk -o /dev/null -D - https://api.rango.test:8443/health | grep -i '^x-rango-instancia'
done | cut -d' ' -f2 | tr -d '\r' | sort | uniq -c
```

```text
     30 3f9c1a7e2b4d
     30 8a21d4c6e0f3
     30 c7e5b2a91d08
     10 canario
```

Os IDs vão ser outros na sua máquina. Para promover o canário, troque a imagem do serviço `api` para `rango-api:0.5.0` e remova o `api-canario`. Para o rollback, tire a linha do canário do `upstream` e reinicie o proxy.

## Observabilidade: saber antes do cliente

Na madrugada do disco, o Rangô ficou fora do ar e a primeira notícia veio do Instagram. Observabilidade é a capacidade de responder, olhando o que o sistema emite, a perguntas que você não previu: o que quebrou, desde quando, para quem, e por quê.

Ela se apoia em três tipos de sinal.

Os **logs** são registros de eventos individuais: "`POST /pedidos` retornou 500 em 2.380 ms". Com seis instâncias da API e dois workers, um `print` solto em cada container fica inútil. Os logs precisam ser **estruturados** (JSON com campos fixos), centralizados e pesquisáveis.

As **métricas** são números agregados no tempo: requisições por segundo, percentual de erros, latência, tamanho da fila. São baratas e ótimas para alertas, mas não contam a história de uma requisição. O livro *Site Reliability Engineering*, do Google, sugere começar por quatro sinais de ouro: latência, tráfego, erros e saturação. Para latência, use percentis: uma média de 300 ms pode esconder que 1% das requisições, o *p99*, leva 9 segundos.

Os **traces** acompanham uma requisição por todos os componentes. Um pedido do Rangô atravessa Nginx, API, gateway de pagamento, stream do Redis e workers, e o trace mostra a duração de cada trecho. Para isso, um identificador viaja junto, num cabeçalho HTTP ou num campo do evento. O padrão de mercado para os três sinais é o OpenTelemetry, que o capítulo 22 usa com a AWS.

Os sinais só servem se alguém olhar na hora certa, e por isso existem os **alertas**. Alerte sobre sintomas que o usuário sente (erros acima de 2% por cinco minutos, p99 acima de 3 segundos, mensagem mais antiga da fila parada há dez minutos), em vez de causas internas que podem ser inofensivas (CPU em 85%). Uma mensagem na DLQ do capítulo 5 também precisa disparar alerta. E todo alerta precisa exigir uma ação, senão a equipe aprende a ignorá-los.

### Mão na massa: logs estruturados e um ID por requisição

Vamos fazer cada requisição da API gerar uma linha de log em JSON, com um identificador que também volta para o cliente. Crie `backend/app/logs.py`:

```python
# backend/app/logs.py
import json
import logging
import sys
from datetime import datetime, timezone


class FormatoJson(logging.Formatter):
    def format(self, registro: logging.LogRecord) -> str:
        dados = {
            "ts": datetime.fromtimestamp(registro.created, timezone.utc).isoformat(),
            "nivel": registro.levelname,
            "msg": registro.getMessage(),
            **getattr(registro, "campos", {}),
        }
        return json.dumps(dados, ensure_ascii=False)


def configurar() -> None:
    saida = logging.StreamHandler(sys.stdout)
    saida.setFormatter(FormatoJson())
    logging.basicConfig(level=logging.INFO, handlers=[saida], force=True)
```

Em `backend/app/main.py`, configure os logs e acrescente o middleware. Os imports de `time` e `uuid` vão para o topo, junto dos outros; `INSTANCIA` já existe desde o capítulo 4:

```python
# backend/app/main.py (trechos novos)
import logging
import time
import uuid

from app import logs

logs.configurar()
log = logging.getLogger("rango.api")


@app.middleware("http")
async def registrar_requisicao(request, call_next):
    request_id = request.headers.get("X-Request-ID") or str(uuid.uuid4())
    inicio = time.perf_counter()
    resposta = await call_next(request)
    resposta.headers["X-Request-ID"] = request_id
    log.info(
        "requisicao",
        extra={
            "campos": {
                "request_id": request_id,
                "metodo": request.method,
                "rota": request.url.path,
                "status": resposta.status_code,
                "duracao_ms": round((time.perf_counter() - inicio) * 1000, 1),
                "instancia": INSTANCIA,
            }
        },
    )
    return resposta
```

Se a requisição já trouxer um `X-Request-ID`, ele é reaproveitado; senão, a API cria um. O ID volta na resposta, e com ele você acha a linha exata do log.

Reconstrua a imagem `rango-api:0.5.0`, suba o Compose (ele recria o canário com a imagem nova) e mande 20 requisições para `/restaurantes`. Com 10% do tráfego, umas duas devem cair no canário:

```bash
docker build -t rango-api:0.5.0 backend
docker compose up -d --scale api=3
for i in $(seq 20); do curl -sk https://api.rango.test:8443/restaurantes > /dev/null; done
docker compose logs api api-canario --no-log-prefix | jq -cR 'fromjson? | select(.msg == "requisicao")'
```

A saída será parecida com esta. A primeira linha pegou o cache expirado e pagou os 300 ms simulados do banco; a segunda veio do Redis:

```text
{"ts":"2026-10-16T14:02:11.482+00:00","nivel":"INFO","msg":"requisicao","request_id":"5d0f8c2e-9b1a-4f7e-a3c4-1e2d3f4a5b6c","metodo":"GET","rota":"/restaurantes","status":200,"duracao_ms":304.7,"instancia":"canario"}
{"ts":"2026-10-16T14:02:11.913+00:00","nivel":"INFO","msg":"requisicao","request_id":"a17e6b90-2c4d-4e8f-9a0b-c1d2e3f40516","metodo":"GET","rota":"/restaurantes","status":200,"duracao_ms":1.9,"instancia":"canario"}
```

Só o canário aparece porque as instâncias estáveis ainda rodam a 0.4.0. O `fromjson?` do `jq` descarta as linhas que não são JSON, como as mensagens do Uvicorn.

Agora a pergunta "quais requisições passaram de 1 segundo?" vira um filtro, em vez de uma leitura de olhos apertados:

```bash
docker compose logs api api-canario --no-log-prefix \
  | jq -cR 'fromjson? | select(.duracao_ms > 1000) | {rota, status, duracao_ms, request_id}'
```

Um limite: se a rota lançar uma exceção não tratada, `call_next` propaga o erro e a linha fica sem registro. Em produção, capture a exceção, registre com `status` 500 e relance. No capítulo 22, essas linhas vão para o Amazon CloudWatch Logs, consultadas com o Logs Insights.

Para desligar tudo, `docker compose down`.

## Incidentes e postmortems

Mesmo com tudo isso, algo vai quebrar. O que muda é como a equipe reage.

Durante um **incidente**, ajuda ter papéis claros, mesmo numa equipe de três pessoas: alguém coordena, alguém mexe nos sistemas, alguém comunica clientes e restaurantes. A prioridade é estancar o problema. Se o deploy de 20 minutos atrás coincide com o aumento de erros, faça o rollback primeiro e investigue com o sistema estável. Anote horários e ações num canal único, porque a memória de madrugada falha.

Depois vem o **postmortem**: linha do tempo, impacto, causas e ações de correção com responsável e prazo. Ele precisa ser ***blameless***, sem culpados. A pergunta certa é "o que no sistema permitiu que uma pessoa apagasse produção com um comando?", e a errada é "quem apagou?". Se a conclusão for "a pessoa errou", a mesma falha volta com outra pessoa. O postmortem do sábado do Rangô, aliás, é este capítulo.

## Armadilhas e casos reais

> **Na vida real:** em 31 de janeiro de 2017, um engenheiro da GitLab, cansado após horas lidando com um problema de replicação, rodou um comando para apagar o diretório de dados do banco no servidor errado: a primária, em vez da réplica. Cerca de 300 GB de dados de produção sumiram em segundos. Ao procurar os backups, a equipe descobriu que o `pg_dump` agendado falhava havia tempo sem ninguém saber: ele usava os binários do PostgreSQL 9.2 contra um servidor 9.6, e os e-mails de alerta sobre a falha eram rejeitados pelo servidor de e-mail. A recuperação veio de um snapshot de disco feito cerca de seis horas antes, por acaso, para popular o ambiente de homologação. Foram perdidas cerca de seis horas de dados, afetando milhares de projetos, comentários e contas de usuários. A GitLab transmitiu a restauração ao vivo e publicou um postmortem detalhado, que virou leitura obrigatória sobre backups.

> **Na vida real:** em 1º de agosto de 2012, a Knight Capital, grande operadora do mercado de ações americano, fez o deploy manual de um código novo em oito servidores, e um deles ficou sem a versão nova. O código novo reaproveitava uma flag que, no servidor desatualizado, ativou uma funcionalidade antiga, desativada havia anos. Em cerca de 45 minutos, o sistema enviou milhões de ordens. Segundo a SEC, o regulador americano, o prejuízo passou de 460 milhões de dólares. Um deploy automatizado e idêntico em todos os servidores teria evitado o problema.

> **Na vida real:** em 19 de julho de 2024, a CrowdStrike distribuiu uma atualização de configuração do seu agente de segurança para Windows a todos os clientes ao mesmo tempo. Um defeito no arquivo derrubou cerca de 8,5 milhões de computadores, segundo a Microsoft, parando companhias aéreas, hospitais e bancos. Entre as correções anunciadas pela empresa estava a distribuição gradual das atualizações, começando por um grupo pequeno: um canário.

Algumas armadilhas são menos famosas e muito mais frequentes:

- **Backup sem monitoramento.** O cron parou de rodar porque o disco encheu, e o último backup tem dois meses. Alerte quando o backup *não* acontecer, além de quando ele falhar.
- **Backup na mesma conta e com as mesmas credenciais.** Um invasor que apaga o banco apaga o backup no mesmo minuto. Cópias em outra conta, com exclusão bloqueada, resolvem isso; o capítulo 23 volta ao assunto com o AWS Backup.
- **Failover nunca ensaiado.** O dia do desastre é o pior dia para descobrir que a aplicação guarda o IP da primária num arquivo de configuração.
- **Alerta demais.** Uma equipe que recebe 200 alertas por semana deixa de ler todos, inclusive o que importava.

## Resumo

- Backup lógico (`pg_dump`) é um retrato; físico com WAL permite point-in-time recovery. Regra 3-2-1 e restore testado.
- RPO: quanto dado perder. RTO: quanto tempo fora. Decisões de negócio.
- Réplicas servem para leitura e failover (cuidado com lag e split brain) e copiam os erros, então não substituem backup.
- HA cuida de falhas pequenas; DR, das grandes. Disponibilidades em série se multiplicam.
- Segredos ficam fora do código e da imagem.
- IaC é a migration da infraestrutura; drift é o inimigo.
- CI testa e constrói a cada mudança; CD leva a versão até produção.
- Rolling, blue/green e canary controlam o risco do deploy; migrations seguem expand/contract.
- Observabilidade: logs estruturados, métricas, traces e alertas sobre sintomas.
- Postmortems são blameless.

## Ponte: hora de alugar a infraestrutura

Olhe a lista de tarefas que este capítulo deixou: um Postgres com réplica em outro prédio, arquivamento contínuo de WAL e failover sem split brain; backups em outra região; servidores recriados a partir de código; logs e métricas centralizados, com alertas que acordam a pessoa certa; um cofre para segredos; um destino para o pipeline. Montar tudo isso em servidores próprios exigiria uma equipe de infraestrutura maior que o Rangô inteiro. E você ainda nem tem o computador com IP público ligado o tempo todo que o capítulo 1 prometeu.

A Parte I mostrou o que precisa existir. A Parte II responde onde e como. No próximo capítulo, você vai abrir uma conta na AWS e, antes de criar qualquer servidor, vai configurar a única coisa que impede uma fatura de quatro dígitos no fim do mês: um alarme de cobrança.

## Referências

- PostgreSQL, backup e restauração: https://www.postgresql.org/docs/current/backup.html
- PostgreSQL, arquivamento contínuo e point-in-time recovery: https://www.postgresql.org/docs/current/continuous-archiving.html
- PostgreSQL, `pg_dump`: https://www.postgresql.org/docs/current/app-pgdump.html
- PostgreSQL, alta disponibilidade e replicação: https://www.postgresql.org/docs/current/high-availability.html
- Imagem oficial do Postgres no Docker Hub (variáveis `_FILE`): https://hub.docker.com/_/postgres
- Docker, segredos no Compose: https://docs.docker.com/compose/how-tos/use-secrets/
- AWS, opções de recuperação de desastres na nuvem: https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-options-in-the-cloud.html
- GitHub Actions, documentação: https://docs.github.com/en/actions
- FastAPI, testes com `TestClient`: https://fastapi.tiangolo.com/tutorial/testing/
- Nginx, módulo `upstream` (pesos e `max_fails`): https://nginx.org/en/docs/http/ngx_http_upstream_module.html
- Martin Fowler, Blue Green Deployment: https://martinfowler.com/bliki/BlueGreenDeployment.html
- Martin Fowler, Canary Release: https://martinfowler.com/bliki/CanaryRelease.html
- Google, *Site Reliability Engineering*, monitoramento de sistemas distribuídos (sinais de ouro): https://sre.google/sre-book/monitoring-distributed-systems/
- Google, *Site Reliability Engineering*, cultura de postmortem: https://sre.google/sre-book/postmortem-culture/
- OpenTelemetry, documentação: https://opentelemetry.io/docs/
- GitLab, postmortem da queda do banco de 31 de janeiro de 2017: https://about.gitlab.com/blog/2017/02/10/postmortem-of-database-outage-of-january-31/
- SEC, ordem administrativa sobre a Knight Capital (2013): https://www.sec.gov/litigation/admin/2013/34-70694.pdf
- Microsoft, sobre a queda causada pela atualização da CrowdStrike: https://blogs.microsoft.com/blog/2024/07/20/helping-our-customers-through-the-crowdstrike-outage/
