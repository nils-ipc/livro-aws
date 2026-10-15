# RDS: banco de dados gerenciado

No capítulo anterior, as fotos dos pratos saíram do disco do servidor e foram para o bucket `rango-fotos-pratos-<conta>`, privado e versionado, com o React enviando os arquivos direto para o S3 por presigned URLs. Sobrou o inquilino mais delicado: o PostgreSQL, que no capítulo 10 rodou numa EC2 da subnet privada, e os pedidos, que até hoje moram no Redis.

## Duas e quarenta e sete da manhã

Suponha que você tivesse mantido a `rango-db-01` do capítulo 10 em produção. A cena é hipotética, mas cada peça dela acontece com quem cuida de banco na mão.

Sábado, 2h47. O disco de 10 GiB do banco chega a 100%. Quem encheu foi o WAL, o log de escrita do Postgres, porque uma réplica que você testou na semana anterior ficou registrada como *replication slot* e o servidor guardou cada segmento de log esperando por ela. O Postgres não tem onde escrever e para:

```text
PANIC:  could not write to file "pg_wal/xlogtemp.48213": No space left on device
```

A API começa a responder 500 em todo `POST /pedidos`. Você acorda às 7h com mensagens da Cantina da Nona. Para aumentar o disco, precisa modificar o volume EBS, esperar, entrar pelo Session Manager e expandir o sistema de arquivos. Aí descobre a segunda surpresa: o `scripts/backup.sh` que você agendou no cron rodava como um usuário que perdeu a permissão de escrita no diretório de destino há doze dias. O log do cron registrou o erro, e ninguém leu.

E ainda tem a pendência da semana: um patch de segurança do PostgreSQL 17, que exige parar o banco, atualizar o pacote e torcer para nada quebrar.

Nada disso tem relação com o produto do Rangô. São tarefas de DBA: vigiar disco, garantir e testar backup, aplicar patches, manter uma réplica pronta. Quando um trabalho é idêntico em milhares de empresas, a AWS costuma transformá-lo em serviço.

## O que o RDS assume por você

O **Amazon RDS** (*Relational Database Service*) roda bancos relacionais gerenciados: PostgreSQL, MySQL, MariaDB, Oracle, SQL Server e Db2. Você escolhe a engine, a versão, o tamanho da máquina e o disco. A AWS cuida do sistema operacional, da instalação, dos backups, dos patches, da replicação e da troca automática para a réplica quando a máquina principal falha.

No capítulo 7, a tabela de responsabilidade compartilhada já mostrava o RDS no meio do caminho entre a EC2 e o Lambda. Do seu lado ficam o esquema, as queries, os índices, os usuários do banco, a rede que chega até ele e as decisões de configuração (quantos dias de backup, se tem réplica, quando aplicar atualização).

O que você perde é o acesso ao servidor: nada de SSH ou Session Manager. Você fala com o banco pela porta 5432 e com a AWS pela API. O usuário mestre que você cria recebe a role `rds_superuser`, que tem quase todos os poderes, mas fica abaixo do superusuário do PostgreSQL. Algumas extensões e configurações que exigem acesso ao sistema de arquivos ficam fora do seu alcance.

Uma **DB instance** é um banco rodando numa máquina gerenciada, com classes parecidas com as da EC2: `db.t4g.micro`, `db.m7g.large`, `db.r7g.xlarge`. Depois do prefixo `db.`, as letras são as do capítulo 9: `t` para burstable, `m` para uso geral, `r` para memória, `g` para Graviton.

### Qual versão do PostgreSQL

O RDS segue o calendário da comunidade. Uma versão major fica em *standard support* pelo menos até o fim do suporte da comunidade. Depois disso, ela não para de funcionar: entra em **RDS Extended Support**, que é pago à parte e dura até três anos além do fim do standard support.

O PostgreSQL 18 foi lançado pela comunidade em 13 de novembro de 2025 e chegou ao RDS no dia seguinte. A AWS publica o fim do standard support do 18 no RDS em 28 de fevereiro de 2031, e o fim do Extended Support em 28 de fevereiro de 2034. Para comparar, o PostgreSQL 14 sai do standard support por volta de fevereiro de 2027. Banco novo começa na major mais recente: é a que vai demorar mais para exigir um upgrade. O Rangô vai de PostgreSQL 18.

As versões minor (18.1, 18.2, 18.4) trazem correções e patches de segurança. No RDS, você pode deixar a opção de atualização automática de minor ligada, e a AWS aplica a nova versão na **janela de manutenção**, um intervalo semanal de 30 minutos que você escolhe. A pendência do patch de sábado vira uma configuração. Uma minor também pode perder suporte antes da major, então não vale a pena desligar essa opção e esquecer.

Upgrade de major continua sendo decisão sua, porque pode quebrar compatibilidade. O RDS faz a parte mecânica e oferece os *Blue/Green Deployments*: uma cópia do banco com a versão nova, mantida em sincronia, para a qual você troca depois dos testes, como no blue/green do capítulo 6.

### Disco que cresce sozinho

O armazenamento do RDS é um volume EBS que você nunca vê. O tipo recomendado para começar é o gp3, com mínimo de 20 GiB no PostgreSQL. O recurso que resolve o PANIC das 2h47 se chama **storage autoscaling**: você define um teto (`--max-allocated-storage`), e o RDS aumenta o disco sozinho quando o espaço livre fica abaixo de 10% por pelo menos cinco minutos. Entre um aumento e outro, ele espera seis horas.

O autoscaling nunca diminui o disco e não descobre por que ele está enchendo. Se uma replication slot esquecida estiver segurando WAL, o autoscaling só adia o problema até o teto. Por isso, o alarme no espaço livre (métrica `FreeStorageSpace`, que veremos no capítulo 22) continua necessário.

### Backups automáticos e point-in-time recovery

No capítulo 6, você viu a diferença entre um dump (um retrato do banco) e o backup físico com WAL arquivado, que permite voltar a qualquer instante, como um `git checkout` para um commit específico. O RDS faz o segundo tipo por padrão.

Uma vez por dia, dentro da **janela de backup** que você escolhe, ele tira um snapshot do volume. Além disso, envia os logs de transação para o S3 a cada cinco minutos. Com o snapshot mais os logs, consegue reconstruir o banco em qualquer segundo do período de retenção, que vai de 1 a 35 dias (0 desliga os backups automáticos, e com eles o point-in-time recovery). Por causa desse envio, o `LatestRestorableTime`, o momento mais recente para o qual você pode restaurar, costuma ficar uns cinco minutos atrás do relógio. Lembra do RPO de 5 minutos que definimos para o Rangô no capítulo 6? Ele vem pronto.

O detalhe que mais surpreende quem chega ao RDS: uma restauração **nunca sobrescreve** o banco existente. O *point-in-time recovery* (PITR) cria uma instância nova, com outro nome e outro endereço. Você pode comparar os dois bancos e copiar só o que precisa, mas a aplicação continua apontando para o banco antigo até alguém mudar a configuração. O mão na massa faz isso.

Há também os **snapshots manuais**, que você tira quando quiser (antes de uma migration arriscada, por exemplo). Eles ficam até você apagá-los, mesmo depois que a instância some. Os automáticos, ao contrário, vão embora com a instância, a menos que você peça para mantê-los.

### Multi-AZ: a réplica que fica esperando

Backup resolve o "perdi dados". Não resolve o "a máquina morreu e o banco está fora". Para isso, o capítulo 6 apresentou a replicação com failover. No RDS, isso se chama **Multi-AZ** e tem duas formas.

Na **Multi-AZ DB instance**, o RDS mantém uma segunda instância, a *standby*, em outra AZ. Cada escrita é replicada de forma síncrona: o commit só volta para a aplicação depois que os dois lados gravaram. Se a primária falhar, o RDS promove a standby e aponta o mesmo nome DNS para ela. A aplicação reconecta no mesmo endereço e segue em frente. A AWS não publica um tempo oficial para esse failover; meça o seu, como faremos no mão na massa.

O ponto que confunde: essa standby não atende leitura nem escrita. Você paga por uma segunda máquina que fica parada esperando um problema, como um gerador de hospital.

Na **Multi-AZ DB cluster**, disponível só para MySQL e PostgreSQL, são três instâncias em três AZs: uma escritora e duas standbys que **aceitam leitura**. A AWS informa failover típico abaixo de 35 segundos, sem perda de dados, e latência de commit até duas vezes menor que a da versão com uma standby.

| | Single-AZ | Multi-AZ DB instance | Multi-AZ DB cluster |
|---|---|---|---|
| Instâncias | 1 | 2 (1 standby) | 3 (2 standbys) |
| AZs | 1 | 2 | 3 |
| Standby atende leitura | não há standby | não | sim |
| Engines | todas | todas | MySQL e PostgreSQL |
| Custo de instância | 1× | cerca de 2× | cerca de 3× |

Para o Rangô em produção, a Multi-AZ DB instance é o ponto de partida razoável: protege contra a perda de uma AZ e não exige mudança no código. Mesmo assim, o Rangô começa em Single-AZ, para conter o custo enquanto você aprende, e o mão na massa liga o Multi-AZ só por alguns minutos para ver o failover. A conta volta no capítulo 24, na lista de pendências de confiabilidade.

### Réplicas de leitura

Uma **read replica** é outra coisa. Ela recebe as mudanças da primária de forma assíncrona e tem um endereço próprio, que a aplicação usa para consultas. Serve para tirar carga de leitura da primária: relatórios, a listagem de restaurantes, o painel administrativo. Pode estar em qualquer AZ ou em outra região, e pode ser promovida a banco independente num plano de recuperação de desastre.

Por ser assíncrona, ela atrasa. O atraso aparece na métrica `ReplicaLag`, em segundos. O problema que o capítulo 6 descreveu continua valendo: o usuário que acabou de fazer um pedido e lê "meus pedidos" na réplica pode não ver o pedido novo. Leituras logo depois de uma escrita do mesmo usuário vão para a primária.

Multi-AZ responde "e se a máquina cair?"; réplica responde "e se a primária não der conta das leituras?". Um banco de produção com bastante tráfego costuma ter as duas.

### Parameter groups: o `postgresql.conf` que você não edita

Sem acesso ao servidor, as configurações ficam num **DB parameter group**, um conjunto de parâmetros que você associa a uma ou mais instâncias. Cada versão major tem uma família (`postgres18`), e cada família tem um grupo padrão, que não pode ser editado. Para mudar qualquer coisa, você cria um grupo seu e associa à instância.

Cada parâmetro é dinâmico (vale na hora) ou estático (exige reinício). Trocar o grupo associado a uma instância que já está rodando também exige reinício. Por isso, crie o grupo customizado antes do banco, mesmo sem nada para mudar ainda, como a route table privada explícita do capítulo 10.

Um parâmetro merece atenção desde o início: `rds.force_ssl`. Com ele em 1, o banco recusa conexões sem TLS. No PostgreSQL 15 em diante, ele já vem ligado; no 14 e anteriores, vem desligado. A senha do banco viaja pela rede da VPC, e o TLS do capítulo 2 vale aqui também.

O outro número que você precisa conhecer é o `max_connections`. No RDS, o padrão é calculado pela memória da classe: `LEAST({DBInstanceClassMemory/9531392},5000)`. Numa `db.t4g.micro`, com 1 GiB, isso dá no máximo pouco mais de cem conexões, e menos na prática, porque parte da memória fica reservada. O gargalo do capítulo 4 (`FATAL: sorry, too many clients already`) chega rápido quando cada processo da API abre seu próprio pool.

### E o Aurora?

O **Amazon Aurora** é o banco relacional que a AWS construiu, compatível com PostgreSQL e MySQL. Para a aplicação, ele é um Postgres, com o mesmo driver e o mesmo SQL. A diferença está embaixo. Em vez de cada instância ter seu volume EBS, todas compartilham um volume de cluster distribuído, que guarda seis cópias dos dados em três AZs. As réplicas leem do mesmo armazenamento que a escritora, então o atraso entre elas costuma ficar na casa dos milissegundos, e o failover não precisa copiar dados.

O **Aurora Serverless v2** acrescenta escala automática de capacidade, medida em ACUs (*Aurora Capacity Units*). Com versões recentes (Aurora PostgreSQL 16.3, 15.7, 14.12 ou 13.15 em diante), a capacidade mínima pode ser 0 ACU: depois de um tempo sem conexões (de 300 a 86.400 segundos, padrão 300), a instância pausa e para de cobrar computação. O armazenamento continua sendo cobrado. A primeira conexão depois da pausa espera a retomada, que leva uns 15 segundos, e 30 segundos ou mais se o banco ficou pausado por mais de um dia. Qualquer conexão aberta, mesmo ociosa, impede a pausa, e um pool da API mantém o banco acordado para sempre.

Para o Rangô de hoje, o RDS PostgreSQL é a escolha mais simples e previsível. O Aurora começa a compensar com muitas réplicas de pouco atraso, ou num ambiente de desenvolvimento que pode pausar à noite. O preço dele tem lógica própria, então faça a conta no AWS Pricing Calculator antes de trocar.

## Cache gerenciado: ElastiCache

O banco guarda só uma parte dos dados do Rangô. Os carrinhos, as chaves de idempotência e o stream de eventos vivem num Valkey instalado na mesma EC2 da API desde o capítulo 9. Se a instância some, somem os carrinhos e os eventos ainda não processados. E no capítulo 13, com várias instâncias, cada uma teria o seu Valkey, e o problema da Ana e dos três carrinhos voltaria.

O **Amazon ElastiCache** roda Valkey, Redis OSS e Memcached gerenciados. Para o Rangô, a escolha é o Valkey, o fork open source criado em 2024, que já usamos na EC2. Há dois modelos.

No modelo baseado em nós, você escolhe a classe e o número de réplicas e paga por hora de cada nó. Em contas antigas, a `cache.t3.micro` entra no free tier de 12 meses.

No **ElastiCache Serverless**, você não escolhe máquina. Paga pelo volume de dados guardado e pelas operações, medidas em ECPUs. Para Valkey, em `us-east-1`, a referência em outubro de 2026 era de US$ 0,084 por GB-hora e US$ 0,0023 por milhão de ECPUs, com mínimo medido de 100 MB por cache. Esse mínimo dá um piso de uns US$ 6 por mês, só de armazenamento. A AWS informa que o Serverless com Valkey sai 33% mais barato que com as outras engines e tem um mínimo 90% menor (o do Redis OSS é de 1 GB). Os valores são aproximados; confira a página de preços antes de decidir. O free tier do ElastiCache não cobre o Serverless.

O Serverless sempre exige TLS e sempre funciona em *cluster mode*, que divide os dados em partes (*shards*). Para o cliente, porém, tudo aparece como um único nó virtual, e o cliente Python comum funciona para comandos de uma chave só, que são todos os que o Rangô usa. Comandos que tocam várias chaves em pedaços diferentes falham com erro `CROSSSLOT`.

## Mão na massa: o Rangô ganha um banco de verdade

Pré-requisitos: AWS CLI v2 com o profile `rango-dev`, a `rango-vpc` do capítulo 10 com as subnets e os Security Groups `rango-web` e `rango-db`, e a role `rango-ec2`. Para a parte que roda no servidor, suba de novo a `rango-api-01` na subnet `rango-publica-a`, com o comando do capítulo 10, e repita a seção "Trazendo o código" do capítulo 9. Tudo em `us-east-1`.

Sobre custo: a `db.t4g.micro` Single-AZ entra no free tier de 12 meses das contas criadas antes de 15 de julho de 2025; nas contas novas, consome os créditos do Free plan. Para o preço por hora, use o AWS Pricing Calculator. O ElastiCache Serverless cobra desde o primeiro minuto. No fim, tudo é desligado.

### Recuperar os IDs da VPC

Os IDs do capítulo 10 ficaram em variáveis de um terminal que já foi fechado. As tags `Name` resolvem:

```bash
export AWS_PROFILE=rango-dev
aws sso login --sso-session rango

VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=rango-vpc \
  --query "Vpcs[0].VpcId" --output text)

id_subnet() {
  aws ec2 describe-subnets --filters Name=tag:Name,Values="$1" \
    --query "Subnets[0].SubnetId" --output text
}
id_sg() {
  aws ec2 describe-security-groups \
    --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$1" \
    --query "SecurityGroups[0].GroupId" --output text
}

PRIV_A=$(id_subnet rango-privada-a)
PRIV_B=$(id_subnet rango-privada-b)
SG_WEB=$(id_sg rango-web)
SG_DB=$(id_sg rango-db)
echo "$VPC_ID $PRIV_A $PRIV_B $SG_WEB $SG_DB"
```

Se algum valor sair `None`, o recurso correspondente não existe mais, e você precisa recriá-lo com os comandos do capítulo 10.

### Subnet group e parameter group

O RDS não recebe uma subnet: recebe um **DB subnet group**, uma lista de subnets em pelo menos duas AZs, onde ele pode colocar a primária e, se houver, a standby. É por isso que o capítulo 10 avisou que o RDS exige duas AZs, mesmo num banco Single-AZ.

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name rango-db-subnets \
  --db-subnet-group-description "Subnets privadas do Rango" \
  --subnet-ids "$PRIV_A" "$PRIV_B" \
  --tags Key=Projeto,Value=rango
```

Agora o parameter group, criado antes do banco para evitar o reinício depois. Aproveite para pedir ao Postgres que registre no log toda query que passar de 500 ms:

```bash
aws rds create-db-parameter-group \
  --db-parameter-group-name rango-pg18 \
  --db-parameter-group-family postgres18 \
  --description "Parametros do Postgres do Rango" \
  --tags Key=Projeto,Value=rango

aws rds modify-db-parameter-group \
  --db-parameter-group-name rango-pg18 \
  --parameters "ParameterName=log_min_duration_statement,ParameterValue=500,ApplyMethod=immediate"
```

Confira o TLS obrigatório:

```bash
aws rds describe-db-parameters --db-parameter-group-name rango-pg18 \
  --query "Parameters[?ParameterName=='rds.force_ssl'].ParameterValue" --output text
```

```text
1
```

### Criar o banco

Descubra a versão minor mais recente do PostgreSQL 18 disponível na região:

```bash
VERSAO=$(aws rds describe-db-engine-versions --engine postgres \
  --query "DBEngineVersions[?starts_with(EngineVersion, '18.')].EngineVersion | [-1]" \
  --output text)
echo "$VERSAO"
```

```text
18.4
```

O seu número pode ser maior. Agora o comando principal do capítulo:

```bash
aws rds create-db-instance \
  --db-instance-identifier rango-db \
  --engine postgres \
  --engine-version "$VERSAO" \
  --db-instance-class db.t4g.micro \
  --storage-type gp3 \
  --allocated-storage 20 \
  --max-allocated-storage 100 \
  --storage-encrypted \
  --master-username rango_admin \
  --manage-master-user-password \
  --db-name rango \
  --db-subnet-group-name rango-db-subnets \
  --vpc-security-group-ids "$SG_DB" \
  --no-publicly-accessible \
  --db-parameter-group-name rango-pg18 \
  --backup-retention-period 7 \
  --preferred-backup-window 06:00-06:30 \
  --preferred-maintenance-window sun:07:00-sun:07:30 \
  --auto-minor-version-upgrade \
  --copy-tags-to-snapshot \
  --deletion-protection \
  --tags Key=Projeto,Value=rango \
  --query "DBInstance.DBInstanceStatus" --output text
```

```text
creating
```

Cada opção responde a um pedaço da madrugada do início do capítulo. O par `--allocated-storage 20` e `--max-allocated-storage 100` liga o storage autoscaling: começa com 20 GiB e cresce sozinho até 100. O `--backup-retention-period 7` mantém uma semana de point-in-time recovery. As janelas estão em UTC: 06:00 UTC são 3h em Brasília, a hora com menos pedidos; a manutenção fica no domingo, logo depois, sem sobrepor o backup. O `--auto-minor-version-upgrade` cuida dos patches de segurança.

O `--no-publicly-accessible` impede que o RDS dê um IP público ao banco. O Security Group é o `rango-db`, que já aceita 5432 só de quem está no `rango-web`. O `--deletion-protection` faz o `delete-db-instance` falhar até alguém desligar a proteção de propósito.

E o `--manage-master-user-password` faz o RDS gerar a senha do usuário mestre e guardá-la no AWS Secrets Manager. A senha nunca aparece no seu terminal, no histórico do shell ou neste livro. O segredo tem uma cobrança mensal pequena, e o capítulo 16 explica por que essa senha fica no Secrets Manager enquanto o resto da configuração do Rangô vai para o Parameter Store.

A criação leva uns dez minutos:

```bash
aws rds wait db-instance-available --db-instance-identifier rango-db

aws rds describe-db-instances --db-instance-identifier rango-db \
  --query "DBInstances[0].[Endpoint.Address,AvailabilityZone,MasterUserSecret.SecretArn]" \
  --output text
```

```text
rango-db.c1abcd2efgh3.us-east-1.rds.amazonaws.com	us-east-1a	arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-0f1e2d3c-...
```

O endereço é um nome DNS, e a aplicação sempre se conecta por ele, nunca pelo IP. É esse nome que muda de destino num failover.

### Conectar a partir da API, com TLS

Entre na `rango-api-01`:

```bash
aws ssm start-session --target "$API_ID"
```

Dentro da sessão, instale o cliente e baixe o pacote de certificados das autoridades do RDS. Com ele, o `psql` confere que está falando com o banco de verdade, e não com alguém no meio do caminho, exatamente como o navegador faz com um site no capítulo 2:

```bash
sudo dnf install -y postgresql17
curl -sS -o /tmp/rds-ca.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
sudo install -m 644 /tmp/rds-ca.pem /etc/rango/rds-ca.pem
```

Agora pegue a senha do mestre. No **seu terminal** (a role `rango-ec2` não tem permissão para ler segredos, e assim deve continuar):

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(aws rds describe-db-instances --db-instance-identifier rango-db \
    --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)" \
  --query SecretString --output text
```

O resultado é um JSON com `username` e `password`. Copie a senha só para o prompt do `psql` a seguir e limpe o terminal depois. De volta à sessão da API:

```bash
DB_HOST=rango-db.c1abcd2efgh3.us-east-1.rds.amazonaws.com
psql "host=$DB_HOST dbname=rango user=rango_admin sslmode=verify-full sslrootcert=/etc/rango/rds-ca.pem"
```

```text
Password for user rango_admin:
psql (17.6, server 18.4)
WARNING: psql major version 17, server major version 18.
         Some psql features might not work.
SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384, compression: off)
Type "help" for help.

rango=>
```

O aviso vem do cliente 17 do Amazon Linux 2023 falando com o servidor 18, e não atrapalha aqui. A linha que importa é a do `SSL connection`. Faça o teste negativo: saia com `\q` e tente com `sslmode=disable` no lugar de `sslmode=verify-full`. O banco recusa a conexão com um erro de `pg_hba.conf` citando `no encryption`. É o `rds.force_ssl` trabalhando.

### O usuário da aplicação e a tabela de pedidos

A API usa um usuário próprio, com menos poder, como a role `rango-ec2` tem menos poder que o seu permission set. Conectado como `rango_admin`:

```sql
CREATE ROLE rango LOGIN;
\password rango
GRANT CREATE ON SCHEMA public TO rango;
\q
```

O `\password` funciona como no capítulo 10: pede a senha duas vezes e envia só o hash. O `GRANT CREATE` existe porque, desde o PostgreSQL 15, usuários comuns não podem mais criar tabelas no schema `public` sem permissão explícita.

No repositório, crie `backend/sql/001_pedidos.sql`:

```sql
CREATE TABLE IF NOT EXISTS pedidos (
    id          uuid PRIMARY KEY,
    usuario     text NOT NULL,
    restaurante text NOT NULL,
    total       numeric(10, 2) NOT NULL,
    cobranca    text,
    status      text NOT NULL DEFAULT 'recebido',
    criado_em   timestamptz NOT NULL DEFAULT now()
);
```

Depois de um `git pull` no servidor, aplique como `rango`, para que a tabela pertença ao usuário da aplicação:

```bash
psql "host=$DB_HOST dbname=rango user=rango sslmode=verify-full sslrootcert=/etc/rango/rds-ca.pem" \
  -f /opt/rango/codigo/backend/sql/001_pedidos.sql
```

Num projeto maior, essa pasta vira um Alembic. Para uma tabela, um arquivo numerado basta.

### Os pedidos saem do Redis

Acrescente o driver ao `backend/requirements.txt`:

```text
psycopg[binary,pool]
```

Crie `backend/app/banco.py`:

```python
import os

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

pool = ConnectionPool(
    os.environ["DATABASE_URL"],
    min_size=1,
    max_size=5,
    kwargs={"row_factory": dict_row},
    open=True,
)
```

O `max_size=5` é a conta do capítulo 4 feita ao contrário: dois workers do Uvicorn por instância, cinco conexões cada, dez conexões por servidor. Com o `max_connections` de uma `db.t4g.micro`, sobra espaço para os workers de eventos, para você no `psql` e para algumas instâncias a mais no capítulo 13.

Em `backend/app/main.py`, a linha do `cache.hset` dá lugar a um `INSERT`, e uma rota nova lê o pedido:

```python
from app.banco import pool

# dentro de criar_pedido, no lugar de cache.hset(f"pedido:{pedido['id']}", ...)
    with pool.connection() as conn:
        conn.execute(
            """
            INSERT INTO pedidos (id, usuario, restaurante, total, cobranca)
            VALUES (%s, %s, %s, %s, %s)
            """,
            (pedido["id"], novo.usuario, novo.restaurante, novo.total, pedido["cobranca"]),
        )
    cache.xadd(STREAM_PEDIDOS, {"tipo": "pedido.criado", "dados": json.dumps(pedido)})


@app.get("/pedidos/{pedido_id}")
def ver_pedido(pedido_id: uuid.UUID):
    with pool.connection() as conn:
        pedido = conn.execute(
            "SELECT id, restaurante, total, status, criado_em FROM pedidos WHERE id = %s",
            (pedido_id,),
        ).fetchone()
    if pedido is None:
        raise HTTPException(404, "Pedido não encontrado")
    return pedido
```

O `with pool.connection()` pega uma conexão emprestada, faz commit ao sair do bloco sem erro e devolve a conexão ao pool. A idempotência continua no Valkey, onde o `SET NX` atômico funciona bem. Repare que gravar no Postgres e depois publicar no stream ainda é a escrita dupla do capítulo 5: se a API morrer entre as duas linhas, o pedido existe e o evento não. O transactional outbox resolve isso, e o capítulo 21 volta ao assunto com filas da AWS.

No servidor, edite o arquivo de ambiente com `sudoedit /etc/rango/api.env` (assim a senha não passa pelo histórico) e acrescente:

```bash
DATABASE_URL=postgresql://rango@rango-db.c1abcd2efgh3.us-east-1.rds.amazonaws.com:5432/rango?sslmode=verify-full&sslrootcert=/etc/rango/rds-ca.pem
PGPASSWORD=a-senha-que-voce-definiu-no-password
```

O driver lê o `PGPASSWORD` do ambiente, como o `psql`. O arquivo já é `640`, dono `root:rango`, desde o capítulo 9. A senha fica nesse arquivo até o capítulo 16 tirá-la dali. Instale as dependências e reinicie:

```bash
sudo -u rango /opt/rango/venv/bin/pip install -r /opt/rango/codigo/backend/requirements.txt
sudo systemctl restart rango-api rango-worker@restaurante rango-worker@email
```

Crie três pedidos pelo Nginx local:

```bash
for USUARIO in ana bruno carla; do
  curl -s -X POST http://127.0.0.1/pedidos \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: $(uuidgen)" \
    -d "{\"usuario\": \"$USUARIO\", \"restaurante\": \"cantina-da-nona\", \"total\": 58.90}"
  echo
done
```

```text
{"id":"6f1c2a9e-3b4d-4e8f-9a1b-2c3d4e5f6a7b","status":"recebido"}
{"id":"0a9b8c7d-6e5f-4a3b-8c2d-1e0f9a8b7c6d","status":"recebido"}
{"id":"d4e5f6a7-b8c9-4d0e-9f1a-2b3c4d5e6f70","status":"recebido"}
```

E confira com `curl -s http://127.0.0.1/pedidos/6f1c2a9e-3b4d-4e8f-9a1b-2c3d4e5f6a7b` (troque pelo seu ID). Os pedidos agora estão num banco com backup contínuo.

### O DELETE sem WHERE

Hora de testar o backup do jeito que o capítulo 6 recomendou: restaurando. Anote o horário atual, em UTC:

```bash
ANTES=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$ANTES"
```

```text
2026-10-15T14:32:10Z
```

Agora cometa o erro clássico, conectado como `rango`:

```bash
psql "host=$DB_HOST dbname=rango user=rango sslmode=verify-full sslrootcert=/etc/rango/rds-ca.pem" \
  -c "DELETE FROM pedidos;"
```

```text
DELETE 3
```

Os três pedidos sumiram. No seu terminal (os comandos de `rds` rodam com o profile `rango-dev`, de fora do servidor), espere o `LatestRestorableTime` passar do horário anotado, o que leva até uns cinco minutos:

```bash
aws rds describe-db-instances --db-instance-identifier rango-db \
  --query "DBInstances[0].LatestRestorableTime" --output text
```

Quando passar, restaure para um banco novo, com o horário de antes do `DELETE`. Use o valor de `ANTES` que você anotou:

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier rango-db \
  --target-db-instance-identifier rango-db-resgate \
  --restore-time 2026-10-15T14:32:10Z \
  --db-instance-class db.t4g.micro \
  --db-subnet-group-name rango-db-subnets \
  --vpc-security-group-ids "$SG_DB" \
  --db-parameter-group-name rango-pg18 \
  --no-publicly-accessible \
  --no-multi-az \
  --tags Key=Projeto,Value=rango \
  --query "DBInstance.DBInstanceStatus" --output text

aws rds wait db-instance-available --db-instance-identifier rango-db-resgate
```

Cronometre essa espera: ela é a maior parte do seu RTO num acidente desse tipo, e costuma passar de dez minutos mesmo num banco quase vazio. Sem os parâmetros de rede, o banco restaurado iria para o Security Group padrão da VPC, apareceria como `available`, e a API receberia timeout. Às 3h, isso custa mais meia hora de investigação.

Com o resgate disponível, copie os pedidos de volta. Na sessão da API, pegue o endpoint novo (ele tem o mesmo sufixo, com `rango-db-resgate` no começo):

```bash
RESGATE=rango-db-resgate.c1abcd2efgh3.us-east-1.rds.amazonaws.com
TLS="sslmode=verify-full sslrootcert=/etc/rango/rds-ca.pem"

psql "host=$RESGATE dbname=rango user=rango $TLS" \
  -c "\copy pedidos TO '/tmp/pedidos.csv' CSV"
psql "host=$DB_HOST dbname=rango user=rango $TLS" \
  -c "\copy pedidos FROM '/tmp/pedidos.csv' CSV"
psql "host=$DB_HOST dbname=rango user=rango $TLS" \
  -c "SELECT usuario, total FROM pedidos ORDER BY usuario;"
```

```text
 usuario | total
---------+-------
 ana     | 58.90
 bruno   | 58.90
 carla   | 58.90
(3 rows)
```

O `\copy` roda do lado do cliente, então o arquivo fica na EC2. Num incidente real, é o caminho mais seguro: a produção segue recebendo pedidos, e você recupera só as linhas perdidas. Apontar a API para o banco restaurado perderia tudo o que foi escrito depois do horário escolhido.

Apague o resgate e o CSV:

```bash
rm /tmp/pedidos.csv
```

```bash
aws rds delete-db-instance --db-instance-identifier rango-db-resgate \
  --skip-final-snapshot --delete-automated-backups
```

### Opcional: ver o failover acontecer

Este passo dobra o custo de instância enquanto estiver ligado. Converter para Multi-AZ não derruba o banco, mas leva vários minutos:

```bash
aws rds modify-db-instance --db-instance-identifier rango-db \
  --multi-az --apply-immediately
aws rds wait db-instance-available --db-instance-identifier rango-db
```

Na sessão da API, veja para onde o nome aponta:

```bash
dig +short "$DB_HOST"
```

```text
10.20.10.84
```

Um IP da `rango-privada-a`. Agora force uma falha, no seu terminal:

```bash
aws rds reboot-db-instance --db-instance-identifier rango-db --force-failover
```

Enquanto isso, na API, rode um laço que tenta ler um pedido a cada segundo e mostra o horário de cada resposta:

```bash
while true; do
  printf '%s ' "$(date +%T)"
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 \
    http://127.0.0.1/pedidos/6f1c2a9e-3b4d-4e8f-9a1b-2c3d4e5f6a7b
  sleep 1
done
```

Você vai ver `200`, depois alguns `500` (o pool usando conexões que morreram com a primária antiga), e de novo `200`. O intervalo entre eles é o seu tempo real de indisponibilidade. Interrompa com Ctrl+C e repita o `dig`:

```text
10.20.11.37
```

O mesmo nome agora leva à `rango-privada-b`, sem nenhuma mudança na aplicação. Os `500` no meio pedem um pool que teste conexões antes de usá-las e retentativa com backoff, como no capítulo 5. Volte para Single-AZ:

```bash
aws rds modify-db-instance --db-instance-identifier rango-db \
  --no-multi-az --apply-immediately
```

### O Valkey sai da EC2

Crie um Security Group para o cache, aceitando só a API:

```bash
SG_CACHE=$(aws ec2 create-security-group --vpc-id "$VPC_ID" \
  --group-name rango-cache --description "Valkey do Rango, so a partir da API" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=rango-cache},{Key=Projeto,Value=rango}]' \
  --query GroupId --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_CACHE" \
  --protocol tcp --port 6379 --source-group "$SG_WEB"
```

E o cache serverless, com limites que funcionam como teto de custo:

```bash
aws elasticache create-serverless-cache \
  --serverless-cache-name rango-cache \
  --engine valkey \
  --subnet-ids "$PRIV_A" "$PRIV_B" \
  --security-group-ids "$SG_CACHE" \
  --cache-usage-limits 'DataStorage={Maximum=1,Unit=GB},ECPUPerSecond={Maximum=5000}' \
  --tags Key=Projeto,Value=rango
```

Repita até o status ficar `available`, o que costuma levar poucos minutos:

```bash
aws elasticache describe-serverless-caches --serverless-cache-name rango-cache \
  --query "ServerlessCaches[0].[Status,Endpoint.Address]" --output text
```

```text
available	rango-cache-a1b2c3.serverless.use1.cache.amazonaws.com
```

Na API, teste com o próprio Python do Rangô. Repare no `rediss://`, com dois esses: é o esquema com TLS.

```bash
sudo -u rango /opt/rango/venv/bin/python -c \
  "import redis; print(redis.Redis.from_url('rediss://rango-cache-a1b2c3.serverless.use1.cache.amazonaws.com:6379').ping())"
```

```text
True
```

Troque o `REDIS_URL` em `/etc/rango/api.env` para esse endereço, desligue o Valkey local e reinicie os serviços:

```bash
sudo systemctl disable --now valkey
sudo systemctl restart rango-api rango-worker@restaurante rango-worker@email
```

As units do capítulo 9 têm `Wants=valkey.service`, e o systemd tentaria subir o Valkey local de novo no próximo boot. Tire essa dependência das units (e o `valkey` do `infra/ec2/user-data.sh`) quando for consolidar a mudança.

Repita um `POST /pedidos` com o mesmo `Idempotency-Key` duas vezes e confira que a segunda resposta é igual à primeira: a idempotência agora vive fora do servidor.

### O Compose na mesma versão do RDS

O código da API agora exige um `DATABASE_URL`, e o Compose da sua máquina ainda roda o PostgreSQL 17 do capítulo 6. Com uma major de diferença, algo pode funcionar no RDS e quebrar no notebook. Leve o serviço `db` do `compose.yaml` para o 18:

```yaml
  db:
    image: postgres:18-alpine
    # ... environment e secrets como no capítulo 6
    volumes:
      - dados-db:/var/lib/postgresql
```

A linha do volume também mudou. A partir do 18, a imagem oficial guarda os dados num subdiretório por versão, dentro de `/var/lib/postgresql`, e se recusa a subir quando encontra um volume montado no antigo `/var/lib/postgresql/data`.

O volume `dados-db` guarda arquivos no formato do 17, que o servidor 18 não abre. Ali só há dados de teste, incluindo a `pedidos` do capítulo 6 com `id bigserial`, incompatível com a tabela nova, então o caminho mais curto é apagar o volume. Se quiser guardar algo, faça antes um `pg_dump` com o script de backup do capítulo 6 e restaure no 18 com `pg_restore`; restaurar o dump de uma versão anterior numa mais nova é suportado.

```bash
docker compose down -v
```

No serviço `api` (e no `api-canario`, se ele estiver ligado), troque a imagem e acrescente a conexão. A senha continua no arquivo do capítulo 6 e entra pela variável do shell, sem ser escrita no `compose.yaml`:

```yaml
    image: rango-api:0.7.0
    environment:
      # ... as variáveis do capítulo 11
      DATABASE_URL: "postgresql://rango@db:5432/rango"
      PGPASSWORD: "${DB_PASSWORD:?defina DB_PASSWORD}"
```

Construa a imagem nova, que já traz o `psycopg`, suba o banco, aplique a migração e suba o resto:

```bash
docker build -t rango-api:0.7.0 backend
export DB_PASSWORD="$(cat secrets/db_password.txt)"
docker compose up -d db
docker compose exec -T db psql -U rango -d rango < backend/sql/001_pedidos.sql
docker compose up -d --scale api=3
```

Um `POST /pedidos` em `https://api.rango.test:8443` agora grava no Postgres local, na mesma major do `rango-db`. Quando terminar, `docker compose down`.

### Desmontar

O banco vai ser recriado nos próximos capítulos, a partir de um snapshot. Desligue a proteção contra exclusão e apague a instância, pedindo um snapshot final:

```bash
aws rds modify-db-instance --db-instance-identifier rango-db \
  --no-deletion-protection --apply-immediately

aws rds delete-db-instance --db-instance-identifier rango-db \
  --final-db-snapshot-identifier rango-db-final-cap12

aws elasticache delete-serverless-cache --serverless-cache-name rango-cache

aws ec2 terminate-instances --instance-ids "$API_ID"
```

O snapshot final fica e cobra armazenamento de backup por GB-mês, poucos centavos para um banco desse tamanho. O subnet group, o parameter group e o Security Group `rango-cache` não cobram nada e ficam para o capítulo 13. Confira que não sobrou instância rodando:

```bash
aws rds describe-db-instances --query "DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]" --output text
aws rds describe-db-snapshots --db-snapshot-identifier rango-db-final-cap12 \
  --query "DBSnapshots[0].Status" --output text
```

## Armadilhas e casos reais

> **Armadilha:** Versão esquecida vira cobrança extra. Quando uma major sai do standard support, o RDS inscreve o banco no Extended Support automaticamente e começa a cobrar por vCPU-hora. Para o PostgreSQL 12, a AWS lista, em `us-east-2`, US$ 0,100 por vCPU-hora de março de 2025 a fevereiro de 2027 e US$ 0,200 a partir de março de 2027 (valores de referência, consultados em outubro de 2026). Num `db.r6g.xlarge`, com 4 vCPUs, isso dá cerca de US$ 290 por mês só no primeiro período, além do preço da instância. Coloque o fim do standard support da sua versão no calendário do time.

> **Armadilha:** A `db.t4g.micro` também é burstable. No RDS, as classes T3 e T4g rodam em modo *unlimited*: quando os créditos de CPU acabam, o banco continua rápido e a AWS cobra o excedente, a US$ 0,075 por vCPU-hora em todas as regiões. Um relatório pesado rodando no banco de produção aparece na fatura. Se o uso de CPU fica alto o tempo todo, a família `m` sai mais barata.

> **Armadilha:** Apagar a instância apaga os backups automáticos. O `delete-db-instance` remove os snapshots automáticos e os logs de PITR, a menos que você use `--no-delete-automated-backups`. Só sobrevivem os snapshots manuais e o snapshot final.

> **Armadilha:** "Multi-AZ é minha réplica de leitura." Na Multi-AZ DB instance, a standby não atende nenhuma consulta. Quem quer aliviar leituras precisa de read replica ou de Multi-AZ DB cluster. E nenhuma das duas protege contra um `DELETE` sem `WHERE`: o erro é replicado em milissegundos para todas as cópias. Para isso, só o PITR.

> **Armadilha:** Banco público "só para conectar do notebook". O `--publicly-accessible` mais uma regra de 5432 para `0.0.0.0/0` recria o banco exposto do capítulo 10, agora com o seu endpoint num domínio conhecido da AWS. Para acessar do seu computador, use o Session Manager com *port forwarding* para um host remoto (`AWS-StartPortForwardingSessionToRemoteHost`), passando pela `rango-api-01`.

## Resumo

- O RDS assume sistema operacional, instalação, backups, patches e failover. Esquema, queries, usuários, rede e configurações continuam com você.
- Sem acesso ao servidor, as configurações ficam num DB parameter group customizado, criado antes do banco.
- Depois do standard support (até 28 de fevereiro de 2031 para o PostgreSQL 18), vem o Extended Support, pago e automático. Minors chegam pela janela de manutenção.
- Storage autoscaling aumenta o disco até um teto definido, e nunca diminui.
- Backups automáticos guardam de 1 a 35 dias, com logs enviados a cada cinco minutos. O point-in-time recovery sempre cria uma instância nova.
- Multi-AZ DB instance: uma standby síncrona que não atende consultas. Multi-AZ DB cluster: duas standbys legíveis, failover típico abaixo de 35 segundos. Read replica: assíncrona, para aliviar leituras, com `ReplicaLag`.
- Aurora usa um volume de cluster com seis cópias em três AZs. O Serverless v2 pode pausar com 0 ACU, e a retomada leva uns 15 segundos.
- ElastiCache Serverless com Valkey cobra por GB-hora e ECPU, exige TLS e tem piso de uns US$ 6 por mês.
- O Rangô gravou pedidos no `rango-db` (PostgreSQL 18, `db.t4g.micro`, subnets privadas, TLS obrigatório), recuperou um `DELETE` sem `WHERE` com PITR e levou o Valkey para o `rango-cache`. Tudo foi desligado, com o snapshot final `rango-db-final-cap12` guardado.

## Nenhum dado mora mais na API

Olhe o que sobrou dentro da `rango-api-01`: o código, o Nginx e o Uvicorn. As fotos estão no S3, os pedidos no RDS, os carrinhos, as chaves de idempotência e os eventos no ElastiCache. Se a instância sumir agora, nada se perde. Essa é a aplicação stateless do capítulo 4, e ela finalmente existe na AWS.

E chega a notícia: o programa de culinária vai fazer um especial com a Cantina da Nona, no sábado à noite. Da última vez, um servidor só caiu em cinco minutos. Agora dá para ter dez cópias da API, mas alguém precisa distribuir os pedidos entre elas, tirar da roda a que travar e criar mais cópias quando o tráfego crescer, sem você acordado ao lado do console. No próximo capítulo, o Rangô ganha um Application Load Balancer e um Auto Scaling Group, e voltamos à TV para aguentar o tráfego desta vez.

## Referências

- Amazon RDS, guia do usuário: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Welcome.html
- Calendário de versões do PostgreSQL no RDS (standard e Extended Support): https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-release-calendar.html
- SSL/TLS com PostgreSQL no RDS (`rds.force_ssl`): https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html
- Período de retenção de backup: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.BackupRetention.html
- Recursos do Multi-AZ: https://aws.amazon.com/rds/features/multi-az
- Single-AZ, Multi-AZ instance ou Multi-AZ cluster (AWS Database Blog): https://aws.amazon.com/blogs/database/choose-the-right-amazon-rds-deployment-option-single-az-instance-multi-az-instance-or-multi-az-database-cluster/
- Preços do RDS para PostgreSQL (Extended Support, créditos de CPU): https://aws.amazon.com/rds/postgresql/pricing/
- Aurora Serverless v2, pausa automática: https://docs.aws.eu/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html
- Preços do ElastiCache: https://aws.amazon.com/elasticache/pricing/
- Configuração e limites de Valkey e Redis OSS no ElastiCache (cluster mode no Serverless): https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/RedisConfiguration.html
- Primeiros passos com ElastiCache para Valkey (AWS Database Blog): https://aws.amazon.com/blogs/database/get-started-with-amazon-elasticache-for-valkey/
- Free tier de bancos de dados da AWS: https://aws.amazon.com/free/database/
