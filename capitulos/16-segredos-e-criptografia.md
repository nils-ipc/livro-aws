# Segredos e criptografia

No capítulo anterior, o Rangô inteiro virou código. A stack `RangoProducao` cria a VPC sem NAT Gateway, o banco a partir de um snapshot, o cache, o Auto Scaling Group atrás do ALB, o front no CloudFront e os registros no Route 53. O user data recebe os endpoints do banco e do cache por tokens, sem ninguém digitar nada. Só que a senha do usuário `rango` continua num arquivo dentro da AMI, e o capítulo terminou com a stack destruída e um snapshot esperando o próximo `cdk deploy`.

## Onde mora a senha do banco

Faça um exercício rápido. Liste todos os lugares onde a senha do usuário `rango` está escrita hoje.

O primeiro você conhece: o `/etc/rango/api.env` da AMI `rango-api-20261015`, na linha `PGPASSWORD=`. Quem pode lançar uma instância dessa AMI lê o arquivo, e cada cópia da AMI leva a senha junto.

O segundo está no Slack. Em março, o Bruno precisava rodar uma consulta para conferir os pedidos de um restaurante, e alguém colou a senha na conversa "só desta vez". A mensagem está lá, indexada pela busca do Slack, visível para quem entrar no canal depois.

O terceiro está no git. Rode isto na raiz do repositório:

```bash
git log -S 'PGPASSWORD' --oneline --all
```

```text
8c41e2a ajusta conexao com o banco
3f09b7d remove .env do repositorio
a12d6c0 testes locais contra o RDS
```

O `-S` procura commits que adicionaram ou removeram aquele texto. O commit `a12d6c0` trouxe um `backend/.env` com a senha de produção para testar contra o RDS, e o `3f09b7d` apagou o arquivo. Apagar num commit novo deixa a senha intacta no histórico: basta um `git show a12d6c0:backend/.env` para ler. E cada pessoa que clonou o repositório nesse intervalo tem uma cópia.

Nenhum desses lugares tem controle de acesso pensado para uma senha de produção, e nenhum registra quem leu. Trocar a senha exigiria mexer na AMI e caçar cada cópia. Na prática, ela nunca vai ser trocada, e dá acesso de leitura e escrita a todos os pedidos do Rangô.

> **Na vida real:** Em outubro de 2022, a Toyota informou que uma empresa contratada tinha publicado, em dezembro de 2017, parte do código do T-Connect num repositório público do GitHub. Nesse código estava uma chave de acesso ao servidor de dados, escrita direto no código-fonte. A chave ficou exposta até 15 de setembro de 2022, quase cinco anos, e dava acesso a dados de cerca de 296 mil clientes (e-mails e números de controle). A Toyota trocou as chaves dois dias depois. Disse não ter evidência de acesso de terceiros, sem poder descartar a hipótese. Repare na ordem dos fatos: a chave só mudou quando alguém a encontrou.

O capítulo 6 já deu a regra: segredo fica fora do código e da imagem, separado por ambiente, e gira de tempos em tempos. No Compose, isso virou um arquivo em `secrets/` fora do git. Na AWS, a pergunta é onde o segredo fica e como a instância, que nasce sozinha às três da manhã numa subnet privada, chega até ele.

## Configuração, segredo e chave

Antes dos serviços, vale separar três coisas que costumam morar juntas no mesmo `.env`.

**Configuração** é o que muda entre ambientes e pode ser lido sem estrago: o endereço do cache, o nome do bucket de fotos, as origens do CORS. Se vazar, ninguém ganha acesso a nada.

**Segredo** é o que dá acesso a alguma coisa: a senha do banco, a chave da API de pagamento, o token de um webhook. Se vazar, alguém entra.

**Chave criptográfica** é o que transforma dados legíveis em ilegíveis e vice-versa. Ela protege os segredos e os dados guardados em disco.

A AWS tem um serviço para cada uma. O AWS Systems Manager Parameter Store guarda configuração (e segredos simples). O AWS Secrets Manager guarda segredos e sabe trocá-los sozinho. O AWS Key Management Service (KMS) guarda as chaves que cifram os outros dois, e quase tudo o mais na conta.

### Parameter Store

O Parameter Store é um dicionário de chave e valor dentro do Systems Manager, o mesmo serviço do Session Manager do capítulo 9. Você já usou um parâmetro dele sem perceber: o `resolve:ssm:` que buscava o ID da AMI mais recente do Amazon Linux 2023 apontava para um parâmetro público mantido pela AWS.

Os nomes seguem uma hierarquia com barras, como caminhos de arquivo:

```text
/rango/producao/cors_origins
/rango/producao/redis_url
/rango/homologacao/cors_origins
/rango/homologacao/redis_url
```

A hierarquia serve para duas coisas. Uma chamada `GetParametersByPath` com `/rango/producao/` devolve todos os parâmetros daquele ambiente de uma vez, como um `os.environ` remoto filtrado por prefixo. E uma policy IAM pode liberar só `/rango/producao/*` para a role de produção, sem que ela enxergue a homologação.

Cada parâmetro tem um tipo. `String` é texto puro. `StringList` é uma lista separada por vírgulas. `SecureString` é texto cifrado com uma chave do KMS: o valor é guardado cifrado, e quem lê precisa de permissão no parâmetro e na chave.

Existem dois *tiers*, escolhidos por parâmetro. No standard, que é o padrão, você tem até 10.000 parâmetros por conta e região, valores de até 4 KB e nenhum custo de armazenamento. No advanced, o limite sobe para 100.000 parâmetros e 8 KB por valor, e aparecem recursos como políticas de expiração e compartilhamento com outras contas, com cobrança por parâmetro por mês e por chamada de API. Dá para promover um parâmetro de standard para advanced, mas nunca o caminho inverso; para voltar, só apagando e criando de novo. O Rangô cabe com folga no standard. A taxa de requisições é outra configuração, por conta e região, chamada *higher throughput*; quando ligada, cobra cada parâmetro lido, em qualquer tier.

### Secrets Manager

O Secrets Manager guarda segredos de forma parecida, com três diferenças que importam.

A primeira é a rotação automática. Você associa ao segredo uma função AWS Lambda e uma agenda, e o Secrets Manager chama essa função para gerar uma senha nova, aplicá-la no banco, testá-la e só então marcá-la como a atual. É um gerenciador de senhas com um cron.

A segunda são as versões com rótulos, os *staging labels*. Cada troca cria uma versão nova do segredo, e os rótulos dizem o papel de cada uma: `AWSCURRENT` é a que a aplicação deve usar, `AWSPENDING` é a que está sendo criada durante uma rotação, e `AWSPREVIOUS` é a anterior, guardada para emergências. Quem lê o segredo sem pedir versão recebe a `AWSCURRENT`.

A terceira é o preço. Cada segredo custa cerca de US$ 0,40 por mês, mais US$ 0,05 a cada 10.000 chamadas de API (valores de referência da página oficial em outubro de 2026; a página não indica região, então confirme na calculadora de preços). A rotação não tem taxa própria: criar versões novas é grátis, e as chamadas que a função de rotação faz entram como chamadas comuns. Somam-se só as invocações da Lambda, que numa rotação mensal ficam em frações de centavo.

Você já tem um segredo lá. No capítulo 12, a senha mestre do `rango_admin` foi para o Secrets Manager, e no capítulo 15 o CDK passou a gerá-la com `from_generated_secret`. O que falta é o usuário da aplicação.

### Rotação sem derrubar ninguém

Trocar a senha de um banco em uso tem um problema de tempo. A aplicação abriu conexões com a senha antiga e guardou essa senha para abrir as próximas. No instante em que a senha muda no banco, toda conexão nova falha até a aplicação descobrir a senha nova. É o mesmo problema de trocar a fechadura da casa com a família inteira na rua.

O Secrets Manager oferece duas estratégias para bancos.

Na **rotação de usuário único**, a função troca a senha do próprio `rango`. É simples, e existe uma janela, de segundos, em que o banco já aceita só a senha nova e parte da aplicação ainda usa a antiga.

Na **rotação de usuários alternados** (*multi-user*), existem dois usuários com as mesmas permissões, e a função alterna entre eles. No PostgreSQL, a primeira rotação cria o `rango_clone` com senha nova e roda `GRANT rango TO rango_clone`, o que faz o clone herdar tudo o que o `rango` pode fazer. A `AWSCURRENT` passa a apontar para o clone. Na rotação seguinte, quem ganha senha nova é o `rango`, e a `AWSCURRENT` volta para ele. Enquanto isso, a senha anterior continua valendo: quem leu o segredo antes da rotação segue conectando até a rotação seguinte. Para trocar a senha mestre e criar o clone, a função usa o segredo do `rango_admin`.

O Rangô vai usar a rotação de usuários alternados, a cada 30 dias. A agenda aceita expressões `rate()` em horas ou dias, com mínimo de 4 horas, ou `cron()` para escolher uma janela fina. Os horários são sempre em UTC.

### Qual dos dois

| | Parameter Store (standard) | Secrets Manager |
|---|---|---|
| Preço | Sem custo de armazenamento | ~US$ 0,40/segredo/mês + chamadas |
| Tamanho máximo | 4 KB | 64 KB |
| Valor cifrado | Só no tipo `SecureString` | Sempre |
| Rotação automática | Não | Sim, com Lambda |
| Versões | Histórico de versões | Versões com `AWSCURRENT`/`AWSPREVIOUS` |
| Criado pelo CloudFormation | `String` e `StringList`, sem `SecureString` | Sim, com valor gerado |

O padrão do Rangô é o Parameter Store, que é mais simples e não cobra por parâmetro no tier standard. Configuração vai para lá como `String`. Um segredo de terceiro que você nunca consegue girar sozinho, como a chave de um parceiro que só muda por e-mail, fica num `SecureString`, criado pela CLI. O Secrets Manager é a exceção, reservada para o segredo que precisa de rotação automática gerenciada, como a senha do banco: o Parameter Store não tem rotação nativa, e refazer a alternância de usuários com uma Lambda e um agendamento próprios custaria bem mais que os US$ 0,40 por mês do segredo.

## KMS: quem guarda a chave

O Secrets Manager guarda o segredo cifrado. Cifrado com qual chave? E onde fica essa chave?

Se a chave ficasse num arquivo ao lado dos dados, a criptografia serviria só de enfeite. Quem rouba o disco rouba a chave junto. O KMS existe para que a chave nunca fique ao lado de nada. As chaves do KMS vivem em módulos de hardware de segurança (HSMs) operados pela AWS e nunca saem de lá em texto puro. Você nunca recebe a chave. Você manda os dados, e o KMS devolve o resultado.

Pense no gerente do banco que guarda a chave do cofre: ele confere seu documento (o IAM), abre o cofre e anota o pedido no livro de registro (o AWS CloudTrail, do capítulo 23).

### Envelope encryption

Mandar cada byte para o KMS cifrar não funciona para um arquivo de 2 GB. A operação `Encrypt` aceita no máximo 4 KB, e cada chamada atravessa a rede. A solução tem nome: *envelope encryption*.

O fluxo para cifrar é este:

1. A aplicação pede ao KMS uma *data key* com `GenerateDataKey`.
2. O KMS devolve duas cópias da mesma data key: uma em texto puro e outra cifrada com a chave do KMS.
3. A aplicação cifra os dados localmente, com a cópia em texto puro e um algoritmo como AES-256-GCM, rápido e sem limite de tamanho.
4. A aplicação joga fora a cópia em texto puro e guarda a cópia cifrada ao lado dos dados.

Para decifrar, a aplicação manda a data key cifrada ao KMS com `Decrypt`, recebe a data key em texto puro e decifra os dados localmente.

É como fechar uma caixa com um cadeado comum e guardar a chave do cadeado num envelope lacrado que só o gerente do banco abre. A caixa pode ficar em qualquer lugar. Sem o gerente, ninguém abre o envelope.

Quase todo serviço da AWS que diz "cifrado com KMS" funciona assim por baixo. O volume EBS cifrado do capítulo 9, o RDS, o Secrets Manager e o S3 com SSE-KMS geram data keys e guardam a versão cifrada junto dos dados. O KMS só entra em cena para abrir a data key, e o trabalho pesado acontece na máquina.

### Chaves da AWS e chaves suas

No KMS existem dois tipos de chave que você vai encontrar.

As **chaves gerenciadas pela AWS** têm nomes como `aws/secretsmanager`, `aws/ssm`, `aws/rds` e `aws/ebs`. Cada serviço cria a sua na primeira vez que precisa. Elas não cobram armazenamento, giram sozinhas uma vez por ano, e você não consegue mudar a policy delas nem desligar a rotação. Qualquer um na conta que tenha permissão no serviço consegue usá-las por meio dele.

As **chaves gerenciadas pelo cliente** (*customer managed keys*) são criadas por você. Custam US$ 1 por mês cada uma, proporcional por hora, e as requisições custam cerca de US$ 0,03 a cada 10.000, com 20.000 requisições grátis por mês (referência de outubro de 2026). Em troca, você controla a *key policy*, que é uma policy baseada em recurso como a bucket policy do capítulo 11: ela decide quem pode cifrar, decifrar ou administrar a chave, independente das permissões no serviço que usa a chave.

Essa independência é o motivo para pagar o dólar. Com uma chave sua, ler um segredo exige duas permissões: `secretsmanager:GetSecretValue` no segredo e `kms:Decrypt` na chave. Alguém que ganhe acesso amplo ao Secrets Manager por engano continua sem conseguir abrir o que foi cifrado com ela. É uma segunda tranca, controlada num lugar diferente.

A rotação automática de uma chave sua vem desligada e você liga com uma chamada. O período padrão é de 365 dias e pode ser configurado. Rotacionar uma chave do KMS cria material criptográfico novo, mas mantém o antigo guardado: dados cifrados há três anos continuam decifráveis, sem você recifrar nada. O ID e o ARN da chave não mudam. A cobrança sobe US$ 1 por mês na primeira rotação e mais US$ 1 na segunda, e depois para de subir. Fora da agenda, a rotação sob demanda permite até 25 rotações por chave. A rotação automática só existe para chaves simétricas de criptografia, as deste livro.

Apagar uma chave tem um freio. O `ScheduleKeyDeletion` coloca a chave em `PendingDeletion` por 7 a 30 dias (padrão de 30), período em que ela fica desabilitada e não cobra armazenamento. Até o prazo acabar, um `CancelKeyDeletion` desfaz tudo. Depois, todo dado cifrado com aquela chave vira ruído para sempre.

## Mão na massa: o Rangô sem senha em arquivo

O plano tem cinco partes. Uma chave do KMS para os segredos do Rangô. Um segredo novo para o usuário `rango`, com rotação de usuários alternados. A configuração não secreta no Parameter Store, separada por ambiente. Os VPC endpoints para que as instâncias, nas subnets isoladas, alcancem os dois serviços. E um user data que monta o `api.env` a cada instância nova, a partir do que está na AWS.

A senha que vazou não vai ser copiada para lugar nenhum. Ela vai morrer na segunda rotação.

### Pré-requisitos

O projeto `rango-infra/` do capítulo 15, com o ambiente virtual ativo, e o profile de desenvolvimento:

```bash
cd rango-infra
source .venv/bin/activate
export AWS_PROFILE=rango-dev
aws sso login
```

No `app.py`, o `snapshot_db` recebe o nome do snapshot final que o `describe-db-snapshots` mostrou no fim do capítulo 15, e a stack ganha um parâmetro novo, o ambiente:

```python
RangoInfraStack(
    app,
    "RangoProducao",
    ambiente="producao",
    dominio="rango.com.br",
    certificado_arn=app.node.try_get_context("certificado_arn"),
    snapshot_db="rangoproducao-snapshot-banco-a1b2c3d4e5f6",
    env=cdk.Environment(
        account=os.environ["CDK_DEFAULT_ACCOUNT"],
        region="us-east-1",
    ),
)
```

Troque o nome do snapshot pelo seu. Em `rango_infra/rango_infra_stack.py`, acrescente os imports e o parâmetro:

```python
from pathlib import Path

from aws_cdk import (
    # ... os imports do capítulo 15 ...
    aws_kms as kms,
    aws_ssm as ssm,
)
```

```python
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        ambiente: str,
        dominio: str,
        certificado_arn: str,
        snapshot_db: str,
        **kwargs,
    ) -> None:
```

### A chave e o caminho até as APIs

Logo depois da criação do cache, entram a chave e os endpoints:

```python
        chave = kms.Key(
            self,
            "ChaveSegredos",
            alias=f"alias/rango-{ambiente}-segredos",
            description="Segredos do Rango",
            enable_key_rotation=True,
            pending_window=Duration.days(7),
            removal_policy=RemovalPolicy.DESTROY,
        )

        privadas = ec2.SubnetSelection(subnet_type=ec2.SubnetType.PRIVATE_ISOLATED)
        endpoint_ssm = vpc.add_interface_endpoint(
            "Ssm", service=ec2.InterfaceVpcEndpointAwsService.SSM, subnets=privadas
        )
        endpoint_sm = vpc.add_interface_endpoint(
            "SecretsManager",
            service=ec2.InterfaceVpcEndpointAwsService.SECRETS_MANAGER,
            subnets=privadas,
        )
```

A chave tem rotação anual ligada. O `removal_policy=RemovalPolicy.DESTROY` com `pending_window` de 7 dias faz o `cdk destroy` agendar a exclusão com a janela mínima, em vez de deixar a chave cobrando para sempre. Numa chave que protege dados que precisam sobreviver à stack, o certo é o padrão do CDK, que mantém a chave. Aqui ela protege só o segredo, que é apagado junto.

Os endpoints resolvem um problema que você descobriria do jeito difícil. As instâncias da API estão em subnets `PRIVATE_ISOLATED`, sem rota para a internet, e as APIs do Parameter Store e do Secrets Manager são endereços públicos. Sem os endpoints, o primeiro comando do user data ficaria preso tentando conectar em `ssm.us-east-1.amazonaws.com` até estourar o tempo. Os *interface endpoints* do capítulo 10 colocam uma interface de rede desses serviços dentro das suas subnets, e o DNS privado da VPC faz o nome público apontar para ela. O código da instância não muda nada.

O preço é o do capítulo 10: cerca de US$ 0,01 por hora por endpoint por AZ, mais o tráfego. Dois serviços em duas AZs dão perto de US$ 29 por mês (us-east-1, outubro de 2026), ainda menos que dois NAT Gateways. O L2 cria para cada endpoint um Security Group que aceita a porta 443 vindo da VPC.

### O segredo e a rotação

```python
        segredo_app = rds.DatabaseSecret(
            self,
            "SegredoApp",
            username="rango",
            master_secret=db.secret,
            encryption_key=chave,
        ).attach(db)

        rotacao = db.add_rotation_multi_user(
            "RotacaoApp",
            secret=segredo_app,
            automatically_after=Duration.days(30),
            endpoint=endpoint_sm,
            vpc_subnets=privadas,
        )
```

O `DatabaseSecret` gera uma senha aleatória para o usuário `rango` e guarda um JSON com `username` e `password`, cifrado com a chave nova. O `master_secret` acrescenta o campo `masterarn`, que diz à função de rotação onde está a senha do `rango_admin`. O `.attach(db)` completa o JSON com `host`, `port` e `engine`, os campos que a função usa para encontrar o banco. Por padrão, o CDK exclui da senha gerada caracteres que costumam quebrar URLs e shells, como aspas, `@`, `/` e `$`.

O `add_rotation_multi_user` monta o resto: uma função Lambda de rotação, publicada pela AWS no Serverless Application Repository, dentro das subnets privadas; um Security Group para ela, com a regra de entrada na porta 5432 do banco; as permissões de leitura e escrita no segredo e de leitura no segredo mestre; e a agenda de 30 dias. O `rotate_immediately_on_update`, que não aparece porque o padrão já é `True`, faz a primeira rotação acontecer assim que a agenda é criada.

Repare que a senha gerada nesse momento é inútil: o `rango` do snapshot continua com a senha antiga. A primeira rotação cria o `rango_clone` e passa a `AWSCURRENT` para ele. A senha vazada só muda na segunda rotação, quando chega a vez do `rango`. Vamos forçar essa segunda logo depois do deploy.

### A configuração por ambiente

```python
        configuracao = {
            "aws_region": self.region,
            "cors_origins": f"https://{dominio},https://www.{dominio}",
            "database_url": (
                f"postgresql://{db.db_instance_endpoint_address}:5432/rango"
                "?sslmode=verify-full&sslrootcert=/etc/rango/rds-ca.pem"
            ),
            "fotos_bucket": f"rango-fotos-pratos-{self.account}",
            "redis_url": f"rediss://{cache.attr_endpoint_address}:6379",
        }
        parametros = [
            ssm.StringParameter(
                self,
                f"Config_{nome}",
                parameter_name=f"/rango/{ambiente}/{nome}",
                string_value=valor,
            )
            for nome, valor in configuracao.items()
        ]
```

Cada entrada do dicionário vira um parâmetro `String` no tier standard. Os endpoints do banco e do cache continuam chegando por tokens, como no capítulo 15, e agora vão para o Parameter Store em vez de entrar num `sed`.

Um detalhe no `database_url`: ele perdeu o `rango@`. Com a rotação de usuários alternados, o nome do usuário muda a cada mês, entre `rango` e `rango_clone`. Se o usuário estivesse fixo na URL, ela ganharia da variável de ambiente, porque a libpq dá preferência ao que vem na string de conexão. Sem ele, o driver usa o `PGUSER`, que o boot vai preencher a partir do segredo, como já faz com o `PGPASSWORD`.

Aqui também se cumpre o que ficou pendente no capítulo 15 sobre a homologação do Bruno. Uma segunda chamada a `RangoInfraStack` no `app.py`, com `ambiente="homologacao"`, cria `/rango/homologacao/*`, uma chave `alias/rango-homologacao-segredos` e um segredo próprio. As duas stacks compartilham o código e nada mais.

### O boot que busca a configuração

O user data do capítulo 15 trocava trechos de um `api.env` que vinha pronto na AMI. Agora ele escreve o arquivo inteiro do zero. Para não espremer um script de shell dentro de strings Python, ele mora num arquivo próprio, `rango-infra/user_data/configurar.sh`:

```bash
# Definidas antes deste trecho pela stack: AMBIENTE, REGIAO, SEGREDO_DB_ARN
set -euo pipefail

CONFIG=$(mktemp)

aws ssm get-parameters-by-path --region "$REGIAO" \
  --path "/rango/$AMBIENTE/" \
  --query "Parameters[].[Name,Value]" --output text \
  | awk -F '\t' '{ n = $1; sub(".*/", "", n); print toupper(n) "=" $2 }' > "$CONFIG"

aws secretsmanager get-secret-value --region "$REGIAO" \
  --secret-id "$SEGREDO_DB_ARN" --query SecretString --output text \
  | python3 -c 'import json, sys; s = json.load(sys.stdin); print("PGUSER=" + s["username"]); print("PGPASSWORD=" + s["password"])' \
  >> "$CONFIG"

install -m 640 -o root -g rango "$CONFIG" /etc/rango/api.env
rm -f "$CONFIG"

systemctl restart rango-api rango-worker@restaurante rango-worker@email
```

O `get-parameters-by-path` traz todos os parâmetros do ambiente, e o `awk` transforma `/rango/producao/redis_url` em `REDIS_URL=...`. O segundo comando lê o segredo e extrai usuário e senha com o Python do sistema, que o Amazon Linux 2023 já traz. O `mktemp` cria o arquivo temporário com permissão só para o root, e o `install` grava o `api.env` final com o mesmo dono e permissão do capítulo 9, `root:rango` e `640`. O arquivo antigo da AMI, com a senha vazada, é sobrescrito.

O user data roda no primeiro boot de cada instância, como vimos no capítulo 9. Num Auto Scaling Group, cada instância nova passa por ele, e as instâncias que já estão rodando não mudam. Guarde isso, porque vai importar na rotação.

Na stack, o bloco de user data fica assim:

```python
        user_data = ec2.UserData.for_linux()
        user_data.add_commands(
            f"AMBIENTE={ambiente}",
            f"REGIAO={self.region}",
            f"SEGREDO_DB_ARN={segredo_app.secret_arn}",
            (Path(__file__).parent.parent / "user_data" / "configurar.sh").read_text(),
        )
```

Nenhum valor secreto passa pelo user data. Ele leva só o ARN do segredo, e isso importa, porque o user data fica legível pelo serviço de metadados para qualquer processo da instância e para quem tiver `ec2:DescribeInstanceAttribute` na conta.

### Permissões e ordem

A role da API precisa ler os parâmetros do seu ambiente e o seu segredo:

```python
        role_api.add_to_policy(
            iam.PolicyStatement(
                actions=["ssm:GetParametersByPath"],
                resources=[
                    f"arn:aws:ssm:{self.region}:{self.account}:parameter/rango/{ambiente}",
                    f"arn:aws:ssm:{self.region}:{self.account}:parameter/rango/{ambiente}/*",
                ],
            )
        )
        segredo_app.grant_read(role_api)
```

O `grant_read` gera duas coisas. Na role, `secretsmanager:GetSecretValue` e `DescribeSecret` só nesse segredo. E, como o segredo usa uma chave sua, `kms:Decrypt` na chave, condicionado a chamadas que venham pelo Secrets Manager. A role consegue decifrar o segredo e nada mais com aquela chave.

No `AutoScalingGroup`, duas mudanças. A primeira é um parâmetro novo:

```python
            max_instance_lifetime=Duration.days(7),
```

Ele faz o ASG trocar toda instância que completar sete dias, de forma gradual. O motivo é a rotação. Uma instância lê o segredo no boot e guarda a senha no `api.env`. Com usuários alternados, essa senha continua válida até a rotação seguinte à próxima, ou seja, por pelo menos 30 dias. Uma instância que vive no máximo sete dias nunca chega a ver a sua senha expirar.

A segunda mudança é a ordem de criação, logo depois do ASG:

```python
        asg.node.add_dependency(endpoint_ssm, endpoint_sm, rotacao, *parametros)
```

No capítulo 15, os tokens criavam as dependências sozinhos: o Launch Template usava o endpoint do banco, logo vinha depois do banco. Aqui, o user data busca os parâmetros pelo caminho, em tempo de execução, e não referencia nenhum deles no template. Para o CloudFormation, nada impede que as instâncias subam antes dos parâmetros existirem ou antes dos endpoints ficarem prontos. O `add_dependency` deixa essa ordem explícita.

Por fim, duas saídas para os comandos seguintes:

```python
        CfnOutput(self, "AsgNome", value=asg.auto_scaling_group_name)
        CfnOutput(self, "SegredoAppArn", value=segredo_app.secret_arn)
```

### Deploy e a segunda rotação

```bash
cdk diff
cdk deploy
```

O `cdk diff` mostra a tabela de mudanças de IAM e pede confirmação no deploy, como no capítulo 15. Aparece também uma stack aninhada, criada pelo Serverless Application Repository com a função de rotação. O deploy leva o tempo de restaurar o banco do snapshot, uns 15 minutos.

Quando terminar, guarde as saídas:

```bash
saida() {
  aws cloudformation describe-stacks --stack-name RangoProducao \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
SEGREDO=$(saida SegredoAppArn)
ASG=$(saida AsgNome)
```

Confira o estado da rotação:

```bash
aws secretsmanager describe-secret --secret-id "$SEGREDO" \
  --query "[RotationEnabled, LastRotatedDate, NextRotationDate]" --output text
```

```text
True    2026-10-16T14:22:08.512000-03:00    2026-11-15T20:59:59-03:00
```

A primeira rotação já aconteceu. Agora force a segunda, a que troca a senha do `rango`:

```bash
aws secretsmanager rotate-secret --secret-id "$SEGREDO"
```

Espere meio minuto e veja quem é quem, sem nunca imprimir a senha no terminal:

```bash
for estagio in AWSCURRENT AWSPREVIOUS; do
  printf '%s ' "$estagio"
  aws secretsmanager get-secret-value --secret-id "$SEGREDO" \
    --version-stage "$estagio" --query SecretString --output text \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["username"])'
done
```

```text
AWSCURRENT rango
AWSPREVIOUS rango_clone
```

O `rango` voltou a ser o usuário atual, agora com uma senha que ninguém viu. A senha do Slack, do commit `a12d6c0` e da AMI parou de funcionar neste momento. O `rango_clone` continua válido, com a senha da primeira rotação.

Falta uma coisa. As duas instâncias que subiram durante o deploy leram o segredo uma vez, no boot, e não dá para saber se foi antes ou depois da primeira rotação terminar, porque o CloudFormation dispara a rotação e segue em frente. Uma instância que leu a versão gerada pelo CDK, antes da rotação, está com uma senha que o banco nunca conheceu. A forma limpa de garantir que todo mundo tem credencial válida é trocar todas as instâncias:

```bash
aws autoscaling start-instance-refresh --auto-scaling-group-name "$ASG" \
  --preferences '{"MinHealthyPercentage": 50}'
```

O *instance refresh* substitui as instâncias aos poucos, mantendo pelo menos metade saudável. Use o mesmo comando depois de qualquer mudança de Launch Template, porque o ASG não troca sozinho as instâncias que estão rodando.

Suba o front com os dois comandos de sync do capítulo 14 e teste a API de fora:

```bash
curl -s https://api.rango.com.br/pedidos/6f1c2a9e-3b4d-4e8f-9a1b-2c3d4e5f6a7b
```

O pedido do snapshot volta como antes. O código do Rangô ficou igual; mudou de onde vêm as variáveis que ele lê.

Dentro de cada instância, o `api.env` ainda tem a senha em texto, só que ela nasce no boot, vem de um lugar com controle de acesso e deixa de valer sozinha.

### A faxina dos outros lugares

Apague a mensagem do Slack e o `.env` do notebook; o `.env` local aponta só para o Postgres do Compose, com a senha de `secrets/db_password.txt` do capítulo 6. Reescrever o histórico do git com o `git filter-repo` limpa o repositório daqui para frente, e as cópias que já existem continuam com o commit. Quem resolveu o vazamento foi a troca da senha.

O *push protection* do GitHub bloqueia pushes com credenciais de formato conhecido, como chaves de acesso da AWS. Senhas aleatórias de banco ele não reconhece, por isso a senha precisa nascer longe do repositório, como agora.

### Envelope encryption com as próprias mãos

Para ver o envelope funcionando, um script curto em `scripts/envelope.py`, usando a chave nova. Ele precisa do `boto3` e do pacote `cryptography` instalados no ambiente:

```python
import os

import boto3
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

kms = boto3.client("kms", region_name="us-east-1")


def cifrar(texto: bytes) -> dict:
    chave = kms.generate_data_key(
        KeyId="alias/rango-producao-segredos", KeySpec="AES_256"
    )
    nonce = os.urandom(12)
    dados = AESGCM(chave["Plaintext"]).encrypt(nonce, texto, None)
    return {"chave_cifrada": chave["CiphertextBlob"], "nonce": nonce, "dados": dados}


def decifrar(pacote: dict) -> bytes:
    chave = kms.decrypt(CiphertextBlob=pacote["chave_cifrada"])["Plaintext"]
    return AESGCM(chave).decrypt(pacote["nonce"], pacote["dados"], None)


pacote = cifrar(b"Interfone quebrado, ligar ao chegar")
print(len(pacote["dados"]), "bytes cifrados")
print(decifrar(pacote).decode())
```

```bash
python scripts/envelope.py
```

```text
51 bytes cifrados
Interfone quebrado, ligar ao chegar
```

O pacote guarda só a versão cifrada da data key (`CiphertextBlob`); o `Plaintext` é usado e descartado. Os 51 bytes são os 35 do texto mais os 16 da etiqueta de autenticação do GCM, que detecta qualquer alteração nos dados. No `decifrar`, o `kms.decrypt` nem recebe o ID da chave: o `CiphertextBlob` já carrega a informação de qual chave o KMS deve usar.

Esse script é didático, e é o tipo de código em que um detalhe errado (um nonce repetido) quebra a segurança sem nenhum erro aparente. Para cifrar dados de verdade na aplicação, use o AWS Encryption SDK, que implementa o envelope, guarda os metadados num formato padrão e reaproveita data keys com segurança. E, antes de levar qualquer código de criptografia para produção, peça a revisão de alguém com experiência em segurança.

### Desligar

```bash
cdk destroy
```

O banco sai com snapshot final, como no capítulo 15; anote o nome com o mesmo `describe-db-snapshots`. A chave do KMS entra em `PendingDeletion` por sete dias, sem cobrar. Os endpoints, os parâmetros, os segredos e a função de rotação saem com a stack. Ficam a zona, o certificado, o bucket de fotos, a AMI, o snapshot e a stack `CDKToolkit`.

Se mudar de ideia sobre a chave dentro da janela, rode `aws kms cancel-key-deletion --key-id <id>` e depois `aws kms enable-key`, porque a chave volta desabilitada.

## Armadilhas e casos reais

> **Armadilha:** O template guarda o que você escreve. Uma senha escrita no código do CDK, com `SecretValue.unsafe_plain_text` ou num `CfnOutput`, vai parar no template sintetizado, no bucket de assets do bootstrap e no console do CloudFormation, legível para quem tiver `cloudformation:GetTemplate`. O nome do método avisa. Deixe o valor ser gerado pelo serviço, como no `DatabaseSecret`.

> **Armadilha:** O CloudFormation cria parâmetros `String` e `StringList`, mas nunca `SecureString`. Quem procura `SecureString` no `ssm.StringParameter` não acha. Para segredo em código de infraestrutura, use o Secrets Manager. Um `SecureString` avulso sai da CLI com `aws ssm put-parameter --type SecureString`, digitado por alguém, fora do repositório.

> **Armadilha:** Tabela com dono errado. O `rango_clone` herda as permissões do `rango` por `GRANT`, mas o que ele cria fica sendo dele. Se uma migration rodar enquanto a `AWSCURRENT` for o clone, a tabela nova pertence ao `rango_clone`, e o `rango` não consegue alterá-la no mês seguinte. Rode as migrations com o `rango_admin` e dê as permissões ao `rango`, ou comece a migration com `SET ROLE rango`.

> **Armadilha:** Duas rotações seguidas derrubam quem ficou para trás. A rotação de usuários alternados protege quem leu a versão atual ou a anterior. Quem leu a versão de antes disso perde o acesso. Ao forçar rotações manuais em sequência, como fizemos, faça um instance refresh em seguida.

> **Armadilha:** Apagar uma chave é apagar os dados. Tudo o que foi cifrado com uma chave do KMS depende dela para sempre. Antes de agendar a exclusão de uma chave antiga, desabilite-a com `aws kms disable-key` por algumas semanas e veja se algo quebra. Desabilitar se desfaz em um segundo; a exclusão, depois da janela, nunca.

> **Armadilha:** `PowerUserAccess` lê todos os segredos. O permission set dos devs, do capítulo 8, inclui `secretsmanager:*` e `kms:*`, e a key policy padrão do CDK confia na conta, o que deixa o IAM decidir. Na prática, qualquer dev lê a senha de produção. A saída é uma conta separada para produção, assunto do capítulo 23.

> **Na vida real:** O caso da Toyota mostra o vazamento que ninguém nota por anos. Uma credencial que gira sozinha a cada 30 dias limita o estrago desse tipo de vazamento sem depender de alguém descobri-lo.

## Resumo

- Configuração vai para o Parameter Store (caminhos como `/rango/producao/...`, tier standard sem custo), segredo que gira vai para o Secrets Manager, e as chaves ficam no KMS.
- O Secrets Manager versiona com `AWSCURRENT`, `AWSPENDING` e `AWSPREVIOUS` e gira senhas com uma Lambda. A rotação de usuários alternados mantém a senha anterior válida até a rotação seguinte.
- O KMS nunca entrega a chave. Envelope encryption cifra os dados localmente com data keys, cifradas por uma chave do KMS.
- Uma chave sua custa US$ 1 por mês e traz a key policy, uma segunda tranca independente do serviço.
- O Rangô monta o `api.env` no boot, por VPC endpoints, e cada instância vive no máximo sete dias. A senha vazada morreu na segunda rotação.

## Uma imagem que envelhece

O segredo saiu dos arquivos, mas olhe de novo para a AMI `rango-api-20261015`. Ela ainda carrega o `api.env` antigo, com uma senha morta, e o código do Rangô do dia em que foi criada. Para mudar uma linha do `banco.py`, o caminho é subir uma instância de montagem numa subnet pública, cadastrar de novo a deploy key, rodar `git pull` e `pip install`, criar uma AMI nova, trocar o nome no `MachineImage.lookup` e disparar um instance refresh. E o Amazon Linux 2023 recebe atualizações de segurança com frequência, que só chegam às instâncias quando alguém refaz a imagem.

No próximo capítulo, o Rangô troca a AMI por uma imagem de container. O Amazon ECR guarda as imagens, o Amazon ECS roda os containers e o AWS Fargate tira de cena o servidor que você precisava manter. E o segredo do banco vira um campo na definição da tarefa, injetado pelo próprio ECS quando o container sobe.

## Referências

- Parameter Store, tiers standard e advanced: https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-advanced-parameters.html
- Preços do Systems Manager (Parameter Store, higher throughput, interações de API): https://aws.amazon.com/systems-manager/pricing/
- Preços do Secrets Manager: https://aws.amazon.com/secrets-manager/pricing/
- Regras de agenda da rotação (`rate()`, `cron()`, `Duration`): https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-secretsmanager-rotationschedule-rotationrules.html
- `RotationScheduleOptions` na API Python do CDK (`rotate_immediately_on_update`): https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_secretsmanager/RotationScheduleOptions.html
- `aws_rds` na API Python do CDK (`DatabaseSecret`, `add_rotation_multi_user`): https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_rds/README.html
- Rotação de usuários alternados para o RDS (AWS Database Blog): https://aws.amazon.com/blogs/database/multi-user-secrets-rotation-for-amazon-rds/
- Código das funções de rotação publicadas pela AWS: https://github.com/aws-samples/aws-secrets-manager-rotation-lambdas
- Conceitos do KMS: https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html
- Rotação de chaves do KMS: https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html
- `enable-key-rotation` na AWS CLI (período de rotação): https://docs.aws.amazon.com/cli/latest/reference/kms/enable-key-rotation.html
- Rotação sob demanda no KMS: https://docs.aws.amazon.com/kms/latest/developerguide/rotating-keys-on-demand.html
- `schedule_key_deletion` no boto3 (janela de 7 a 30 dias): https://docs.aws.amazon.com/boto3/latest/reference/services/kms/client/schedule_key_deletion.html
- Preços do KMS: https://aws.amazon.com/kms/pricing/
- AWS Encryption SDK: https://docs.aws.amazon.com/encryption-sdk/latest/developer-guide/introduction.html
- Caso Toyota T-Connect (GitGuardian): https://blog.gitguardian.com/toyota-accidently-exposed-a-secret-key-publicly-on-github-for-five-years/
