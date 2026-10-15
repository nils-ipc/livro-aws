# Infraestrutura como código com CDK

No capítulo 14, o Rangô ganhou endereço de verdade. O Route 53 hospeda a zona `rango.com.br`, o ACM emitiu um certificado para o apex, o `www` e o `api`, e o React passou a sair de um bucket privado pelas bordas do CloudFront. A API ganhou listener HTTPS no ALB e aguentou o especial de sábado com seis instâncias. No domingo, desligamos o que cobra por hora: o ASG, o ALB, o banco e o cache foram apagados, e ficaram a zona, o certificado, a distribuição, o bucket do front, a versão 2 do Launch Template e o snapshot `rango-db-final-cap14`.

## Homologação para quinta-feira

Segunda-feira, a sócia manda uma mensagem. O Bruno, do Sabor do Sertão, quer testar o cardápio novo antes de ele ir para o ar, e ela prometeu um ambiente de homologação até quinta. "É só copiar o que já existe, né?"

Você abre os capítulos anteriores e começa a contar. A VPC do capítulo 10 tem quatro subnets, duas route tables, um Internet Gateway, um gateway endpoint para o S3 e três Security Groups que dependem uns dos outros. O banco do capítulo 12 precisa de subnet group, parameter group e um snapshot com nome de capítulo. O capítulo 13 trouxe AMI, Launch Template, target group, ALB, ASG e política de escala. O 14 acrescentou listener HTTPS, distribuição, OAC e registros de DNS com aspas escapadas. Passa de cem comandos, e cada um devolve um ID que o próximo precisa receber.

Na terça à noite, a homologação sobe. Na quarta de manhã, o Bruno avisa que a lista de restaurantes dá erro. O log da instância mostra:

```text
redis.exceptions.ConnectionError: Error -2 connecting to rango-cache-x7k2pq.serverless.use1.cache.amazonaws.com:6379. Name or service not known.
```

A versão 2 do Launch Template ainda carrega no user data o endpoint de um cache que foi apagado no capítulo 14. Você corrige. Depois descobre que esqueceu o gateway endpoint do S3, e o upload de fotos trava num timeout. Depois percebe que a porta 443 do grupo do ALB foi aberta na produção e não na homologação. Na quinta, os dois ambientes funcionam, mas ninguém sabe dizer em quantos detalhes eles diferem.

Esse é o problema que o capítulo 6 chamou de *drift* e de servidor floco de neve, agora na escala de uma conta inteira. O estado da infraestrutura mora em três lugares: na AWS, no seu histórico de terminal e na sua memória. Só o primeiro é confiável, e ele não diz como chegou ali.

## A infraestrutura como uma migration

O capítulo 6 apresentou a ideia: descrever a infraestrutura num arquivo versionado, como uma migration descreve o banco. Você declara o estado que quer, e uma ferramenta compara com o que existe e faz a diferença. Na AWS, a ferramenta que faz isso desde 2011 é o **AWS CloudFormation**.

### CloudFormation por dentro

O CloudFormation recebe um *template*, um arquivo JSON ou YAML que lista recursos. Cada recurso tem um tipo, como `AWS::EC2::VPC` ou `AWS::RDS::DBInstance`, e propriedades. Um pedaço de template com um bucket fica assim:

```yaml
Resources:
  FrontBucket:
    Type: AWS::S3::Bucket
    Properties:
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
```

Você entrega o template, e o CloudFormation cria uma *stack*: o conjunto de recursos nascidos daquele template, gerenciados juntos. A stack é a unidade de tudo. Você cria, atualiza e apaga a stack, e os recursos vão junto.

Duas palavras vão aparecer o capítulo inteiro. O **logical ID** é o nome do recurso dentro do template (`FrontBucket`, no exemplo). O **physical ID** é o nome real na AWS, como `rangoproducao-frontbucket-1a2b3c4d5e6f`. O CloudFormation guarda o mapa entre os dois. É por esse mapa que ele sabe que o `FrontBucket` do template de hoje é o mesmo bucket de ontem.

Quando um recurso cita outro (a subnet cita a VPC, o banco cita a subnet), o CloudFormation monta um grafo de dependências. Ele cria em paralelo o que é independente e espera o que depende. Você não escreve a ordem, igual a uma migration que não precisa saber em que ordem o Postgres grava as páginas no disco.

Na atualização, o CloudFormation compara o template novo com o anterior e calcula o que muda. Você pode pedir essa lista antes de aplicar, num *change set*. Para cada recurso, a mudança cai em uma de três categorias: atualizar sem interrupção, atualizar com interrupção (um reboot, por exemplo) ou substituir. Substituir quer dizer criar um recurso novo e apagar o antigo. Para um bucket vazio de front, tanto faz. Para o banco de pedidos, é a diferença entre uma terça tranquila e um postmortem.

### Rollback

Se qualquer recurso falha durante uma operação, o CloudFormation desfaz o que fez e volta ao último estado bom. Isso é o *rollback*, e ele é automático. Uma atualização que falha termina em `UPDATE_ROLLBACK_COMPLETE`, com a stack como estava antes.

Uma criação que falha termina em `ROLLBACK_COMPLETE`. A stack fica lá, vazia, e não aceita atualização. A única saída é apagá-la e tentar de novo.

O caso feio é o `UPDATE_ROLLBACK_FAILED`: o rollback não conseguiu desfazer alguma coisa, quase sempre porque alguém mexeu num recurso por fora. Se uma pessoa apaga pelo console um Security Group que a stack gerencia, e uma atualização depois falha, o rollback tenta restaurar o grupo antigo e não encontra. A saída é corrigir a causa e rodar `aws cloudformation continue-update-rollback`. Em último caso, a opção `--resources-to-skip` pula os recursos travados (só aceita os que estão em `UPDATE_FAILED`), e eles ficam marcados como atualizados, mesmo que a realidade não bata com o template.

### Drift

Isso leva ao drift. O CloudFormation só sabe o que ele mesmo fez. Se alguém abre a porta 22 de um Security Group pelo console, o template continua dizendo que ela está fechada. O CloudFormation tem uma detecção de drift que compara as propriedades declaradas no template com as reais e aponta as diferenças. Ela detecta, mas não corrige: a decisão de voltar ao template ou de atualizar o template fica com você.

A regra que faz tudo isso funcionar é a do capítulo 6: depois que um recurso nasce pelo código, o console vira somente leitura para ele. Daqui em diante, todo exemplo usa CDK, com poucas exceções avisadas no próprio capítulo: uma variável do GitHub no 18, o SLO e o Transaction Search no 22, o Security Hub no 23 e a policy do bucket de fotos, que mora fora da stack, no 24.

CloudFormation não cobra pelos tipos `AWS::*`; você paga só pelos recursos criados. Os limites que importam para o Rangô são 500 recursos por template e 2.000 stacks por região por conta (referência, outubro de 2026; confira os valores da sua conta com `aws cloudformation describe-account-limits`).

## Por que não escrever o YAML direto

Dá para escrever o Rangô inteiro em YAML. Muita gente faz isso, e funciona. O problema aparece no tamanho. A VPC do capítulo 10, com subnets, rotas, associações e gateway, passa de 150 linhas de YAML. O Security Group do banco que aceita conexões do grupo da API vira dois recursos e uma referência cruzada. Quer dois ambientes? Você copia o arquivo ou aprende a linguagem de condições e funções intrínsecas do CloudFormation (`Fn::If`, `Fn::Sub`, `Fn::GetAtt`), que tem tudo de uma linguagem de programação, menos o conforto.

O **AWS CDK** (Cloud Development Kit) resolve isso escrevendo a infraestrutura numa linguagem de verdade, Python no nosso caso, e gerando o template do CloudFormation a partir dela. O CDK não fala com as APIs dos serviços para criar recursos. Ele produz um template e entrega ao CloudFormation, que faz o resto. Stack, rollback, drift e change set continuam valendo exatamente como acabamos de ver.

A relação lembra a do Django ORM com o SQL. Você escreve `class Pedido(models.Model)`, e o `makemigrations` gera o SQL. No CDK, você escreve `s3.Bucket(...)`, e o `cdk synth` gera o template. Dá para olhar o resultado gerado sempre que quiser, e às vezes você vai precisar.

### Constructs em três níveis

Tudo no CDK é um *construct*: um objeto Python que representa um ou mais recursos. Eles vêm em três níveis.

O **L1** é o recurso do CloudFormation traduzido um a um. As classes começam com `Cfn`, como `CfnBucket` ou `CfnServerlessCache`, e as propriedades são as mesmas do template, sem padrão nenhum. É o YAML com sintaxe de Python.

O **L2** é a camada que faz o CDK valer a pena. O `s3.Bucket` já nasce com Block Public Access, o `ec2.Vpc` cria subnets, rotas e gateways de uma vez, e o `rds.DatabaseInstance` gera uma senha e guarda no Secrets Manager se você não informar uma. Os L2 também trazem métodos que geram permissões e regras de rede, como `bucket.grant_read(role)` e `db.connections.allow_default_port_from(api)`.

O **L3**, chamado de *pattern*, junta vários recursos numa arquitetura pronta. O capítulo 17 vai usar um deles para subir um serviço de containers atrás de um ALB em poucas linhas.

Na prática, você usa L2 quase sempre e desce para L1 quando o serviço ainda não tem L2. O cache do Rangô vai ser exatamente esse caso.

### O que o CDK precisa para rodar

O CDK tem duas partes. A biblioteca, `aws-cdk-lib`, é o pacote Python que o seu código importa. A CLI, o comando `cdk`, roda em Node.js, mesmo quando o projeto é Python. Você vai precisar dos dois. O CDK v1 teve o suporte encerrado em junho de 2023; tudo aqui usa o v2, que vem num pacote único.

Antes do primeiro deploy, cada par de conta e região passa por um *bootstrap*. O comando `cdk bootstrap` cria uma stack chamada `CDKToolkit` com um bucket S3 e um repositório ECR, onde o CDK guarda templates e arquivos (os *assets*) antes de entregá-los ao CloudFormation, e algumas roles IAM que o deploy usa. O custo é o armazenamento desses arquivos, alguns centavos por mês.

## Mão na massa: o Rangô inteiro em Python

O plano: um projeto CDK com uma stack, `RangoProducao`, que cria a rede, o banco restaurado do snapshot, o cache, a API com ALB e ASG, o bucket do front, a distribuição e os registros de DNS. A zona e o certificado ficam de fora da stack. Eles vivem mais que qualquer ambiente, e recriar a zona trocaria os servidores de nome que estão no Registro.br.

### Pré-requisitos

Node.js 22 ou 24. O suporte do CDK ao Node 20 termina em 30 de outubro de 2026, daqui a duas semanas na data em que escrevo, e o 18 já saiu em novembro de 2025. Python 3.12, a AWS CLI v2 e os profiles do capítulo 8.

```bash
node --version
npm install -g aws-cdk
cdk --version
```

### Bootstrap com o profile certo

O bootstrap cria roles IAM. O `rango-dev`, com `PowerUserAccess`, não pode criar roles, então este é um dos raros momentos para o `rango-admin`:

```bash
aws sso login --profile rango-admin
cdk bootstrap aws://123456789012/us-east-1 --profile rango-admin
```

```text
 ⏳  Bootstrapping environment aws://123456789012/us-east-1...
 ✅  Environment aws://123456789012/us-east-1 bootstrapped.
```

Troque `123456789012` pelo ID da sua conta (`aws sts get-caller-identity`). Vale saber o que você acabou de criar. Entre as roles da `CDKToolkit` há uma role de execução que o CloudFormation assume para criar os recursos, e ela recebe `AdministratorAccess` por padrão. Na prática, quem pode fazer deploy pelo CDK pode criar qualquer coisa na conta. Voltamos a isso nas armadilhas.

### O projeto

O projeto de infraestrutura mora no mesmo repositório, ao lado de `backend/` e `frontend/`:

```bash
mkdir rango-infra && cd rango-infra
cdk init app --language python
source .venv/bin/activate        # Windows: .venv\Scripts\activate
python -m pip install -r requirements.txt
```

O `cdk init` exige a pasta vazia e gera esta estrutura (o hífen do nome vira sublinhado no pacote Python):

```text
rango-infra/
├── app.py
├── cdk.json
├── requirements.txt
├── requirements-dev.txt
├── rango_infra/
│   ├── __init__.py
│   └── rango_infra_stack.py
└── tests/
```

O `requirements.txt` já vem com a versão do `aws-cdk-lib` fixada com `==`. Deixe assim. O pip não tem lockfile, e um `pip install` de outra pessoa daqui a três meses traria outra versão, com outros padrões. Quando quiser atualizar, edite o número à mão, em vez de usar `pip freeze`, que despejaria no arquivo todas as dependências transitivas.

O `cdk.json` diz à CLI como rodar o app (`python3 app.py`) e guarda o *context*, um dicionário de configuração. Acrescente ali o ARN do certificado do capítulo 14, que não é segredo:

```json
{
  "app": "python3 app.py",
  "context": {
    "certificado_arn": "arn:aws:acm:us-east-1:123456789012:certificate/0a1b2c3d-4e5f-6789-abcd-ef0123456789"
  }
}
```

O arquivo gerado tem mais linhas dentro de `context`, com as *feature flags* do CDK. Mantenha todas e só acrescente a sua chave.

### O app

O `app.py` instancia a stack. É aqui que, no futuro, entra a homologação: outra chamada à mesma classe, com outros parâmetros.

```python
#!/usr/bin/env python3
import os

import aws_cdk as cdk

from rango_infra.rango_infra_stack import RangoInfraStack

app = cdk.App()

RangoInfraStack(
    app,
    "RangoProducao",
    dominio="rango.com.br",
    certificado_arn=app.node.try_get_context("certificado_arn"),
    snapshot_db="rango-db-final-cap14",
    env=cdk.Environment(
        account=os.environ["CDK_DEFAULT_ACCOUNT"],
        region="us-east-1",
    ),
)

cdk.Tags.of(app).add("Projeto", "rango")

app.synth()
```

A CLI preenche `CDK_DEFAULT_ACCOUNT` a partir das suas credenciais. Declarar conta e região deixa a stack amarrada a um lugar, o que permite ao CDK consultar a conta durante a síntese, como veremos na zona e na AMI. O `Tags.of(app)` aplica a tag `Projeto=rango` em todo recurso que aceita tags, de uma vez só, a mesma tag que colocamos à mão desde o capítulo 7.

### A rede

Agora a stack, em `rango_infra/rango_infra_stack.py`. O começo traz os imports e a VPC:

```python
from aws_cdk import (
    CfnOutput,
    Duration,
    RemovalPolicy,
    Stack,
    aws_autoscaling as autoscaling,
    aws_certificatemanager as acm,
    aws_cloudfront as cloudfront,
    aws_cloudfront_origins as origins,
    aws_ec2 as ec2,
    aws_elasticache as elasticache,
    aws_elasticloadbalancingv2 as elbv2,
    aws_iam as iam,
    aws_rds as rds,
    aws_route53 as route53,
    aws_route53_targets as targets,
    aws_s3 as s3,
)
from constructs import Construct


class RangoInfraStack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        dominio: str,
        certificado_arn: str,
        snapshot_db: str,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        vpc = ec2.Vpc(
            self,
            "Rede",
            ip_addresses=ec2.IpAddresses.cidr("10.20.0.0/16"),
            max_azs=2,
            nat_gateways=0,
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="publica", subnet_type=ec2.SubnetType.PUBLIC, cidr_mask=24
                ),
                ec2.SubnetConfiguration(
                    name="privada",
                    subnet_type=ec2.SubnetType.PRIVATE_ISOLATED,
                    cidr_mask=24,
                ),
            ],
        )
        vpc.add_gateway_endpoint(
            "S3",
            service=ec2.GatewayVpcEndpointAwsService.S3,
            subnets=[ec2.SubnetSelection(subnet_type=ec2.SubnetType.PRIVATE_ISOLATED)],
        )
```

Essas linhas fazem o trabalho de uma seção inteira do capítulo 10: duas subnets públicas com rota para um Internet Gateway, duas privadas sem rota para a internet, as route tables, as associações e o gateway endpoint do S3 nas privadas.

Repare no `nat_gateways=0`. Sem ele, o `ec2.Vpc` cria por padrão um NAT Gateway em cada zona de disponibilidade, com subnets privadas do tipo `PRIVATE_WITH_EGRESS`. É o padrão sensato para muitas aplicações e a promessa que ficou no capítulo 10: com duas AZs, seriam dois NAT Gateways cobrando por hora sem que o Rangô precise deles. As instâncias da API não saem para a internet desde o capítulo 13. A AMI já tem tudo instalado, o S3 chega pelo gateway endpoint, e o banco e o cache estão dentro da VPC. Por isso as privadas são `PRIVATE_ISOLATED`.

O CIDR é o mesmo `10.20.0.0/16` da VPC feita à mão, que vai ser apagada no fim do capítulo. Duas VPCs com a mesma faixa podem coexistir enquanto não forem conectadas.

### Permissões e grupos de segurança

```python
        sg_api = ec2.SecurityGroup(
            self, "SgApi", vpc=vpc, description="Instancias da API do Rango"
        )
        sg_cache = ec2.SecurityGroup(
            self, "SgCache", vpc=vpc, description="Valkey serverless do Rango"
        )
        sg_cache.add_ingress_rule(sg_api, ec2.Port.tcp(6379), "API no Valkey")

        role_api = iam.Role(
            self,
            "RoleApi",
            assumed_by=iam.ServicePrincipal("ec2.amazonaws.com"),
            managed_policies=[
                iam.ManagedPolicy.from_aws_managed_policy_name(
                    "AmazonSSMManagedInstanceCore"
                )
            ],
        )
        role_api.add_to_policy(
            iam.PolicyStatement(
                actions=["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
                resources=[f"arn:aws:s3:::rango-fotos-pratos-{self.account}/fotos/*"],
            )
        )
```

As descrições ficam sem acento pelo mesmo motivo do capítulo 9: a API de Security Groups recusa caracteres fora do ASCII nesse campo.

A role repete a `rango-ec2` dos capítulos 8 e 11: Session Manager e as três ações em `fotos/*`, sem `ListBucket`. O bucket de fotos fica fora da stack de propósito. Ele guarda dados que não podem sumir num `cdk destroy`, e a stack só precisa saber o nome dele. O L2 de bucket tem métodos como `grant_read_write`, mas eles concedem ações a mais, inclusive listagem; aqui o `PolicyStatement` explícito reproduz exatamente a policy do capítulo 11.

### Banco e cache

```python
        db = rds.DatabaseInstanceFromSnapshot(
            self,
            "Banco",
            snapshot_identifier=snapshot_db,
            instance_identifier="rango-db",
            engine=rds.DatabaseInstanceEngine.postgres(
                version=rds.PostgresEngineVersion.of("18.4", "18")
            ),
            instance_type=ec2.InstanceType.of(
                ec2.InstanceClass.BURSTABLE4_GRAVITON, ec2.InstanceSize.MICRO
            ),
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(
                subnet_type=ec2.SubnetType.PRIVATE_ISOLATED
            ),
            credentials=rds.SnapshotCredentials.from_generated_secret("rango_admin"),
            parameter_group=rds.ParameterGroup(
                self,
                "ParametrosPg",
                engine=rds.DatabaseInstanceEngine.postgres(
                    version=rds.PostgresEngineVersion.of("18.4", "18")
                ),
                parameters={"log_min_duration_statement": "500"},
            ),
            storage_type=rds.StorageType.GP3,
            max_allocated_storage=100,
            backup_retention=Duration.days(7),
            deletion_protection=False,
            removal_policy=RemovalPolicy.SNAPSHOT,
        )
        db.connections.allow_default_port_from(sg_api, "API no Postgres")

        cache = elasticache.CfnServerlessCache(
            self,
            "Cache",
            serverless_cache_name="rango-cache",
            engine="valkey",
            subnet_ids=vpc.select_subnets(
                subnet_type=ec2.SubnetType.PRIVATE_ISOLATED
            ).subnet_ids,
            security_group_ids=[sg_cache.security_group_id],
            cache_usage_limits=elasticache.CfnServerlessCache.CacheUsageLimitsProperty(
                data_storage=elasticache.CfnServerlessCache.DataStorageProperty(
                    maximum=1, unit="GB"
                ),
                ecpu_per_second=elasticache.CfnServerlessCache.ECPUPerSecondProperty(
                    maximum=5000
                ),
            ),
        )
```

O banco nasce do snapshot do capítulo 14, como nos capítulos 13 e 14, com o usuário `rango`, a senha dele e os pedidos de teste. O `from_generated_secret("rango_admin")` gera uma senha nova para o usuário mestre e a guarda no Secrets Manager. O CDK também cria o subnet group e o parameter group (família `postgres18`, deduzida da versão), que antes eram comandos separados.

A `removal_policy` diz o que acontece com o recurso quando ele sai da stack. Com `SNAPSHOT`, o CloudFormation tira um snapshot final antes de apagar a instância. Declare sempre essa política no banco, em vez de confiar no padrão: é a linha que separa um `cdk destroy` de uma perda de dados.

A linha `db.connections.allow_default_port_from(sg_api, ...)` merece atenção. No capítulo 10, você criou o grupo `rango-db` e uma regra de entrada na porta 5432 com origem no grupo `rango-web`. Aqui, o banco sabe a própria porta, e o método gera a mesma regra. Se a porta mudar um dia, a regra acompanha.

O cache é o L1 do capítulo. O ElastiCache Serverless não tem construct L2 estável na `aws-cdk-lib`, então usamos o `CfnServerlessCache`, que é o recurso `AWS::ElastiCache::ServerlessCache` com nomes de propriedade em snake_case. Compare com o comando do capítulo 12: são os mesmos campos, um a um, e sem nenhuma ajuda. As subnets e o Security Group precisam ser passados como listas de IDs, e nada impede que você esqueça a regra de entrada.

### A API

```python
        user_data = ec2.UserData.for_linux()
        user_data.add_commands(
            "set -euo pipefail",
            "sed -i"
            f" -e 's|^REDIS_URL=.*|REDIS_URL=rediss://{cache.attr_endpoint_address}:6379|'"
            f" -e 's|@rango-db[^:]*:5432|@{db.db_instance_endpoint_address}:5432|'"
            f" -e 's|^CORS_ORIGINS=.*|CORS_ORIGINS=https://{dominio},https://www.{dominio}|'"
            " /etc/rango/api.env",
            "systemctl restart rango-api rango-worker@restaurante rango-worker@email",
        )

        modelo = ec2.LaunchTemplate(
            self,
            "ModeloApi",
            machine_image=ec2.MachineImage.lookup(
                name="rango-api-20261015", owners=["self"]
            ),
            instance_type=ec2.InstanceType("t3.micro"),
            role=role_api,
            security_group=sg_api,
            user_data=user_data,
            require_imdsv2=True,
        )

        asg = autoscaling.AutoScalingGroup(
            self,
            "Api",
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(
                subnet_type=ec2.SubnetType.PRIVATE_ISOLATED
            ),
            launch_template=modelo,
            min_capacity=2,
            max_capacity=6,
            health_checks=autoscaling.HealthChecks.with_additional_checks(
                additional_types=[autoscaling.AdditionalHealthCheckType.ELB],
                grace_period=Duration.seconds(90),
            ),
            default_instance_warmup=Duration.seconds(60),
        )

        certificado = acm.Certificate.from_certificate_arn(
            self, "Certificado", certificado_arn
        )

        alb = elbv2.ApplicationLoadBalancer(
            self, "Alb", vpc=vpc, internet_facing=True
        )
        https = alb.add_listener(
            "Https",
            port=443,
            certificates=[elbv2.ListenerCertificate.from_certificate_manager(certificado)],
            ssl_policy=elbv2.SslPolicy.RECOMMENDED_TLS,
        )
        alb.add_redirect()

        https.add_targets(
            "AlvoApi",
            port=80,
            protocol=elbv2.ApplicationProtocol.HTTP,
            targets=[asg],
            health_check=elbv2.HealthCheck(
                path="/health",
                interval=Duration.seconds(10),
                healthy_threshold_count=2,
                unhealthy_threshold_count=2,
            ),
            deregistration_delay=Duration.seconds(30),
        )
        asg.scale_on_request_count("Requisicoes", target_requests_per_minute=600)
```

Comece pelo user data, porque ele resolve o erro que abriu o capítulo. O endpoint do cache e o do banco entram no script como `cache.attr_endpoint_address` e `db.db_instance_endpoint_address`. No momento em que o Python roda, esses valores ainda não existem: o cache nem foi criado. O CDK coloca no lugar um *token*, uma marca que vira uma referência no template (um `Fn::GetAtt`), e o CloudFormation troca a referência pelo valor real na hora do deploy. Isso cria também uma dependência: o Launch Template só nasce depois do cache e do banco. O endpoint velho preso no user data deixa de ser possível, porque nenhum endpoint fica escrito à mão.

O `sed` do banco troca só o host dentro do `DATABASE_URL` do capítulo 12, preservando usuário, porta e parâmetros de TLS. Com o `instance_identifier` fixo, o endpoint sai igual ao de antes, mas o script não depende disso. A senha do usuário `rango` continua no `api.env` da AMI, um remendo que o capítulo 16 remove.

O `MachineImage.lookup` procura a AMI `rango-api-20261015` na sua conta durante a síntese. Esse tipo de consulta, um *lookup*, é a razão de declarar conta e região no `app.py`. O resultado fica guardado em `cdk.context.json`, e as sínteses seguintes leem dali, sem consultar a AWS de novo. Faça commit desse arquivo: ele garante que todo mundo gera o mesmo template, mesmo que surja uma AMI nova com nome parecido.

O resto é o capítulo 13 em outra forma. O `HealthChecks.with_additional_checks` liga a verificação do ELB com o grace period de 90 segundos. O `add_listener` com certificado e `RECOMMENDED_TLS` é o listener HTTPS do capítulo 14, com a mesma política `ELBSecurityPolicy-TLS13-1-2-2021-06`. O `add_redirect()` cria o listener da porta 80 com o `301`. O `add_targets` cria o target group, registra o ASG nele e, sem você pedir, gera a regra no `sg_api` que aceita a porta 80 vindo do grupo do ALB. E o `scale_on_request_count` monta o target tracking por `ALBRequestCountPerTarget`, com o `ResourceLabel` que você teve de montar à mão no capítulo 13.

### Front e DNS

```python
        front = s3.Bucket(
            self,
            "Front",
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            enforce_ssl=True,
            removal_policy=RemovalPolicy.DESTROY,
            auto_delete_objects=True,
        )

        spa = [
            cloudfront.ErrorResponse(
                http_status=codigo,
                response_http_status=200,
                response_page_path="/index.html",
                ttl=Duration.seconds(0),
            )
            for codigo in (403, 404)
        ]

        distribuicao = cloudfront.Distribution(
            self,
            "Distribuicao",
            default_behavior=cloudfront.BehaviorOptions(
                origin=origins.S3BucketOrigin.with_origin_access_control(front),
                viewer_protocol_policy=cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
                cache_policy=cloudfront.CachePolicy.CACHING_OPTIMIZED,
            ),
            domain_names=[dominio, f"www.{dominio}"],
            certificate=certificado,
            default_root_object="index.html",
            error_responses=spa,
            price_class=cloudfront.PriceClass.PRICE_CLASS_ALL,
            http_version=cloudfront.HttpVersion.HTTP2_AND_3,
        )

        zona = route53.HostedZone.from_lookup(self, "Zona", domain_name=dominio)
        alvo_front = route53.RecordTarget.from_alias(
            targets.CloudFrontTarget(distribuicao)
        )
        for nome, sufixo in ((None, "Apex"), ("www", "Www")):
            route53.ARecord(
                self, f"Front{sufixo}A", zone=zona, record_name=nome, target=alvo_front
            )
            route53.AaaaRecord(
                self, f"Front{sufixo}Aaaa", zone=zona, record_name=nome, target=alvo_front
            )
        route53.ARecord(
            self,
            "ApiA",
            zone=zona,
            record_name="api",
            target=route53.RecordTarget.from_alias(targets.LoadBalancerTarget(alb)),
        )

        CfnOutput(self, "FrontBucket", value=front.bucket_name)
        CfnOutput(self, "DistribuicaoId", value=distribuicao.distribution_id)
        CfnOutput(self, "AlbDns", value=alb.load_balancer_dns_name)
```

O `S3BucketOrigin.with_origin_access_control` cria o OAC e escreve a bucket policy com o `AWS:SourceArn` da distribuição, o JSON que você montou à mão em `infra/s3/rango-front-policy.json`. O mapeamento de `403` e `404` para o `index.html` também está aqui, assim como a `PriceClass_All`, que mantém as bordas da América do Sul.

O bucket do front leva `RemovalPolicy.DESTROY` e `auto_delete_objects=True` porque o conteúdo dele é um build, que se gera de novo em um minuto. O CloudFormation não apaga bucket com objetos, então o CDK acrescenta um *custom resource*, uma pequena função Lambda que esvazia o bucket antes do delete. O nome do bucket fica a cargo do CloudFormation, e ele sai na saída `FrontBucket`.

A zona entra por `from_lookup`. A stack não cria nem apaga a zona; ela só descobre o ID para escrever registros nela. Com o certificado acontece o mesmo, pelo ARN.

### Síntese

Antes de criar qualquer coisa, veja o que o seu Python vira:

```bash
export AWS_PROFILE=rango-dev
aws sso login
cdk synth > /dev/null
ls cdk.out/
grep -c '"Type": "AWS::' cdk.out/RangoProducao.template.json
```

O `cdk synth` executa o `app.py`, faz os lookups e grava o *cloud assembly* em `cdk.out/`, com um template por stack. Algumas dezenas de linhas de Python viram um template com dezenas de recursos e mais de mil linhas de JSON, longe do limite de 500. Procure ali o `AWS::EC2::Route`: são as rotas que você criou com `create-route` no capítulo 10.

### O primeiro deploy, e o erro previsto

```bash
cdk deploy
```

Antes de criar, o CDK mostra as mudanças que ampliam permissões, numa tabela de statements IAM e outra de regras de Security Group, e pergunta `Do you wish to deploy these changes (y/n)?`. Leia de verdade. É ali que aparece o `0.0.0.0/0` na porta 443 do ALB e a policy da role da API. Responda `y`.

Uns quinze minutos depois, o deploy para:

```text
RangoProducao | CREATE_FAILED | AWS::CloudFront::Distribution | Distribuicao...
Resource handler returned message: "Invalid request provided: One or more of the CNAMEs you provided are already associated with a different resource."
...
RangoProducao | ROLLBACK_COMPLETE | AWS::CloudFormation::Stack | RangoProducao
```

É o `CNAMEAlreadyExists` que o capítulo 14 avisou. A distribuição criada pelo console, `E1ABCDEF2GHIJK`, ainda segura `rango.com.br` e `www.rango.com.br`, e um nome alternativo só pode estar em uma distribuição. Repare no que o CloudFormation fez: ao primeiro erro, ele cancelou o que estava em andamento e apagou tudo o que tinha criado, inclusive o banco restaurado. Nenhum recurso pela metade ficou para trás.

A stack ficou em `ROLLBACK_COMPLETE`, e nesse estado ela não aceita atualização. Apague a casca vazia:

```bash
aws cloudformation delete-stack --stack-name RangoProducao
aws cloudformation wait stack-delete-complete --stack-name RangoProducao
```

Agora libere os nomes. Para apagar uma distribuição, o CloudFront exige que ela esteja desabilitada, e toda alteração precisa do `ETag` da versão atual:

```bash
DIST_VELHA=E1ABCDEF2GHIJK

ETAG=$(aws cloudfront get-distribution-config --id "$DIST_VELHA" \
  --query ETag --output text)
aws cloudfront get-distribution-config --id "$DIST_VELHA" \
  --query DistributionConfig > /tmp/dist.json
jq '.Enabled = false' /tmp/dist.json > /tmp/dist-off.json

aws cloudfront update-distribution --id "$DIST_VELHA" \
  --if-match "$ETAG" --distribution-config file:///tmp/dist-off.json
aws cloudfront wait distribution-deployed --id "$DIST_VELHA"

ETAG=$(aws cloudfront get-distribution --id "$DIST_VELHA" \
  --query ETag --output text)
aws cloudfront delete-distribution --id "$DIST_VELHA" --if-match "$ETAG"
```

Os registros alias de `rango.com.br` e `www` também precisam sair, porque a stack vai criá-los, e o Route 53 recusa criar um registro que já existe. Em vez de escrever cada um com aspas escapadas, filtre pelo zone ID do CloudFront e transforme a lista em exclusões:

```bash
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name rango.com.br \
  --query "HostedZones[0].Id" --output text)
ZONE_ID=${ZONE_ID##*/}

aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?AliasTarget.HostedZoneId=='Z2FDTNDATAQYW2']" \
  | jq '{Changes: map({Action: "DELETE", ResourceRecordSet: .})}' \
  > /tmp/apagar-alias.json

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/apagar-alias.json
```

A partir daqui, `https://rango.com.br` fica fora do ar até o próximo deploy terminar. Para o Rangô de estudos, uns vinte minutos sem site são aceitáveis. Numa produção com clientes, você evitaria a janela trazendo a distribuição existente para dentro da stack com `cdk import`, que usa o *resource import* do CloudFormation para adotar um recurso sem recriá-lo.

Tente de novo:

```bash
cdk deploy
```

```text
 ✅  RangoProducao

Outputs:
RangoProducao.AlbDns = Rango-AlbXX-1A2B3C4D5E6F-123456789.us-east-1.elb.amazonaws.com
RangoProducao.DistribuicaoId = E2KLMNOP3QRSTU
RangoProducao.FrontBucket = rangoproducao-front1a2b3c4d-5e6f7g8h9i0j
```

O tempo fica entre quinze e vinte e cinco minutos, quase todo esperando o banco e a distribuição. Falta o conteúdo do front, que fica fora da stack: ele muda a cada commit, e o capítulo 18 vai colocá-lo no pipeline. Por enquanto, os mesmos comandos do capítulo 14, com o bucket novo:

```bash
FRONT=$(aws cloudformation describe-stacks --stack-name RangoProducao \
  --query "Stacks[0].Outputs[?OutputKey=='FrontBucket'].OutputValue" --output text)

cd ../frontend
npm ci
npm run build
aws s3 sync dist/ "s3://$FRONT/" \
  --exclude index.html \
  --cache-control "public, max-age=31536000, immutable"
aws s3 cp dist/index.html "s3://$FRONT/index.html" \
  --cache-control "no-cache"
cd ../rango-infra
```

E o teste de ponta a ponta:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://rango.com.br/
curl -s https://api.rango.com.br/health
curl -sI https://api.rango.com.br/restaurantes | grep -i x-rango-instancia
```

```text
200
{"status":"ok"}
x-rango-instancia: ip-10-20-2-87.ec2.internal
```

O `10.20.2.x` mostra a instância numa subnet privada nova: o CDK distribui as faixas em sequência, com as públicas em `10.20.0.0/24` e `10.20.1.0/24` e as privadas logo depois. Abra o site no navegador e a lista de restaurantes aparece, servida pelo cache que a instância encontrou sem que ninguém escrevesse o endpoint dele.

### Mudar com segurança

Agora a parte do dia a dia. Toda alteração passa por `cdk diff`, o equivalente a olhar o SQL de uma migration antes de rodar. Suponha que alguém, organizando o código, renomeie o construct do banco de `"Banco"` para `"BancoDeDados"`:

```bash
cdk diff
```

```text
Stack RangoProducao
Resources
[-] AWS::RDS::DBInstance Banco6A9B6A33 destroy
[+] AWS::RDS::DBInstance BancoDeDados4C1D2E3F
```

O CDK monta o logical ID a partir do caminho do construct, e um id novo no Python é um recurso novo no template. Para o CloudFormation, o banco antigo saiu e um novo entrou: ele apagaria a instância e criaria outra a partir do snapshot do capítulo 14, perdendo todos os pedidos feitos desde então. Nesse caso, o `instance_identifier` fixo acabaria travando o deploy, porque o nome `rango-db` ainda estaria em uso pela instância antiga, mas não conte com essa sorte em outros recursos. Desfaça a troca de nome. Quando precisar mesmo reorganizar o código, o comando `cdk refactor` move recursos para logical IDs novos preservando o que já está implantado.

A leitura do diff é simples: `[~]` muda, `[+]` cria, `[-]` apaga. Procure `destroy` e `replace` em tudo que guarda dados.

### Drift na prática

Suponha que, numa sexta à noite, alguém abra a porta 22 do grupo do ALB pelo console "só para testar uma coisa". Detecte:

```bash
DRIFT_ID=$(aws cloudformation detect-stack-drift --stack-name RangoProducao \
  --query StackDriftDetectionId --output text)
aws cloudformation describe-stack-drift-detection-status \
  --stack-drift-detection-id "$DRIFT_ID" --query DetectionStatus

aws cloudformation describe-stack-resource-drifts --stack-name RangoProducao \
  --stack-resource-drift-status-filters MODIFIED \
  --query "StackResourceDrifts[].[LogicalResourceId,PropertyDifferences[0].DifferenceType,PropertyDifferences[0].PropertyPath]" \
  --output text
```

```text
AlbSecurityGroup86A59E99	ADD	/SecurityGroupIngress/2
```

A CLI do CDK também tem um `cdk drift`, que faz a mesma pergunta a partir do projeto. Agora o detalhe que surpreende: rodar `cdk deploy` em seguida não fecha a porta. O template não mudou, então o CloudFormation conclui que não há nada a fazer. A correção é revogar a regra à mão, ou levá-la para o código se ela tivesse motivo para existir, e reforçar a regra de que o console é somente leitura para o que nasceu na stack.

### O fim do trabalho manual

Com a stack no ar, sobram recursos dos capítulos anteriores que nenhum código descreve. Esta é a última demolição à mão do livro:

```bash
aws ec2 delete-launch-template --launch-template-name rango-api

FRONT_VELHO=rango-front-123456789012
aws s3 rm "s3://$FRONT_VELHO" --recursive
aws s3api list-object-versions --bucket "$FRONT_VELHO" --query "Versions[0]"
aws s3 rb "s3://$FRONT_VELHO"

OAC_ID=$(aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='rango-front-oac'].Id" --output text)
ETAG=$(aws cloudfront get-origin-access-control --id "$OAC_ID" \
  --query ETag --output text)
aws cloudfront delete-origin-access-control --id "$OAC_ID" --if-match "$ETAG"

aws rds delete-db-subnet-group --db-subnet-group-name rango-db-subnets
aws rds delete-db-parameter-group --db-parameter-group-name rango-pg18
aws rds delete-db-snapshot --db-snapshot-identifier rango-db-final-cap14
```

O `list-object-versions` confere que o bucket do front não tinha versionamento; se aparecer alguma versão, o `rb` vai falhar e as versões precisam ser apagadas antes. O snapshot do capítulo 14 pode sair porque o banco atual nasceu dele e já tem os próprios backups.

A role `rango-ec2` e o instance profile dela também ficaram sem uso. Como a remoção mexe em IAM, use o `rango-admin`:

```bash
aws iam remove-role-from-instance-profile --instance-profile-name rango-ec2 \
  --role-name rango-ec2 --profile rango-admin
aws iam delete-instance-profile --instance-profile-name rango-ec2 --profile rango-admin
aws iam delete-role-policy --role-name rango-ec2 --policy-name RangoFotos --profile rango-admin
aws iam detach-role-policy --role-name rango-ec2 \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore --profile rango-admin
aws iam delete-role --role-name rango-ec2 --profile rango-admin
```

Por último, a `rango-vpc`. Pelo console da VPC, selecione `rango-vpc` e use *Delete VPC*: o console lista e apaga junto as subnets, as route tables, o Internet Gateway, o gateway endpoint e os Security Groups `rango-web`, `rango-alb`, `rango-db`, `rango-cache` e `rango-endpoints`. Confira a lista antes de confirmar: a VPC certa é a que não tem a tag `aws:cloudformation:stack-name`.

### Desligar sem deixar sobra

O que cobra por hora agora está numa stack só. Antes de destruir, garanta que o banco tem backup:

```bash
cdk destroy
```

O CDK pede confirmação e apaga tudo na ordem inversa das dependências. O banco sai com um snapshot final, por causa da `RemovalPolicy.SNAPSHOT`, com nome gerado pelo CloudFormation. Para achar o mais recente:

```bash
aws rds describe-db-snapshots --db-instance-identifier rango-db \
  --query "reverse(sort_by(DBSnapshots, &SnapshotCreateTime))[0].[DBSnapshotIdentifier,Status]" \
  --output text
```

Ficam a zona, o certificado, o bucket de fotos, a AMI, o snapshot e a stack `CDKToolkit`. O site sai do ar junto com a distribuição. No próximo capítulo, o caminho de volta é um `cdk deploy` com o nome desse snapshot no `snapshot_db`, e o front volta com os dois comandos de sync.

Para a homologação do Bruno, o caminho agora é outra chamada a `RangoInfraStack` no `app.py`, com outro nome de stack, outro snapshot e outro identificador de banco. O domínio exige um pouco mais: `homolog.rango.com.br` precisa de um certificado que cubra o nome, e a stack pode pedir esse certificado ao ACM com validação na própria zona. Os detalhes de configuração por ambiente ficam para o capítulo 16.

## Armadilhas e casos reais

> **Armadilha:** Trocar o snapshot de um banco que já existe. A propriedade `snapshot_identifier` só vale na criação. Se você muda o valor numa stack já implantada, o CloudFormation entende que precisa de um banco novo e substitui a instância, jogando fora tudo o que foi gravado depois da restauração. Depois do primeiro deploy, não mexa nesse parâmetro da stack que está no ar; use outro nome de stack para restaurar um backup diferente.

> **Armadilha:** Renomear o que tem nome fixo. Com `instance_identifier="rango-db"`, qualquer mudança que exija substituição falha com `CloudFormation cannot update a stack when a custom-named resource requires replacing`. O CloudFormation cria o novo antes de apagar o velho, e dois recursos não podem ter o mesmo nome. Nomes físicos fixos facilitam a vida de quem lê o console e atrapalham a de quem atualiza a stack; use só onde algo de fora depende do nome.

> **Armadilha:** Quem faz deploy é administrador. A role de execução que o bootstrap cria tem `AdministratorAccess`. O `rango-dev` não pode criar roles IAM, mas o `cdk deploy` dele criou uma, porque quem cria é o CloudFormation, com a role de execução. Restrinja com `cdk bootstrap --cloudformation-execution-policies` apontando para policies menores, quando o time crescer. O capítulo 23 volta a isso com várias contas.

> **Armadilha:** Bootstrap na região esquecida. O bootstrap vale por conta e por região. Ao criar uma stack em `sa-east-1` pela primeira vez, o deploy falha pedindo bootstrap. Evite o atalho `cdk bootstrap --express`, que usa um modo do CloudFormation sem rollback automático.

> **Armadilha:** Erro de tipo só em tempo de execução. O Python não confere tipos antes da síntese, e o CDK roda sobre uma camada chamada JSII, que traduz as chamadas para a biblioteca original em TypeScript. Passar uma string onde se espera uma lista, ou misturar um `CfnXxx` onde se espera um L2, só estoura no `cdk synth`, com um traceback que mistura Python e JavaScript. Rode `mypy` ou `pyright` no CI para pegar isso antes.

> **Armadilha:** Mexer no recurso, não no código. Alguém aumenta o `max_capacity` do ASG pelo console num pico. No próximo deploy que tocar no ASG, o valor do template volta. A mudança de emergência precisa ir para o código logo depois, ou ela some sem aviso.

> **Na vida real:** Uma stack em `UPDATE_ROLLBACK_FAILED` costuma ter a mesma história: alguém mexeu pelo console num recurso que a stack gerenciava. Recrie o que sumiu e rode `continue-update-rollback`. O `--resources-to-skip` deixa a stack acreditando num estado que não existe, e a conta chega no deploy seguinte.

## Resumo

- O CloudFormation cria stacks a partir de templates. Logical ID é o nome no template, physical ID é o nome na AWS. Ele monta o grafo de dependências, faz rollback automático e detecta drift, sem corrigir.
- Uma criação que falha termina em `ROLLBACK_COMPLETE` e precisa ser apagada. Uma atualização que não consegue voltar termina em `UPDATE_ROLLBACK_FAILED`, resolvido com `continue-update-rollback`.
- O CDK gera templates do CloudFormation a partir de Python. L1 (`Cfn*`) é o recurso cru, L2 traz padrões seguros e métodos de permissão e rede, L3 monta arquiteturas inteiras.
- A CLI do CDK roda em Node.js (use 22 ou 24). Cada conta e região precisa de `cdk bootstrap`, que cria a stack `CDKToolkit` com uma role de execução administradora por padrão.
- Tokens viram referências no template, e é por isso que o user data recebe o endpoint do cache e do banco sem ninguém digitar.
- `cdk synth` gera, `cdk diff` mostra, `cdk deploy` aplica, `cdk destroy` apaga. Renomear um construct troca o logical ID e pode substituir o recurso.
- `removal_policy` decide o destino dos dados: `SNAPSHOT` no banco, `DESTROY` com `auto_delete_objects` só no que se regenera.
- O Rangô inteiro, da VPC sem NAT Gateway aos registros de DNS, está em `rango-infra/`, na stack `RangoProducao`.

## O que ainda está escrito num arquivo

A infraestrutura agora cabe num `git diff`. Só que, no meio dela, a AMI `rango-api-20261015` ainda leva o `/etc/rango/api.env` com o `PGPASSWORD` do usuário `rango` em texto puro. Quem tiver permissão para lançar uma instância dessa AMI lê a senha. A senha mestre que o CDK gerou foi parar no Secrets Manager, mas a do usuário da aplicação continua num arquivo, e a versão de desenvolvimento dela ainda está no `.env` de alguém, num commit antigo e numa conversa do Slack de março.

No próximo capítulo, os segredos saem dos arquivos. O Parameter Store e o Secrets Manager guardam configuração e senhas, a instância busca o que precisa a cada boot com a própria role, a senha do banco passa a girar sozinha, e o KMS entra para explicar quem guarda as chaves que cifram tudo isso.

## Referências

- AWS CDK v2, guia do desenvolvedor: https://docs.aws.amazon.com/cdk/v2/guide/home.html
- Trabalhar com o CDK em Python (Python 3.9+, ambiente virtual, imports, versões fixadas): https://docs.aws.amazon.com/cdk/v2/guide/work-with-cdk-python.html
- Versões de Node.js suportadas pelo CDK: https://docs.aws.amazon.com/cdk/v2/guide/node-versions.html
- Referência dos comandos da CLI do CDK (`synth`, `diff`, `deploy`, `destroy`, `drift`, `import`, `refactor`): https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd.html
- `cdk bootstrap` (stack `CDKToolkit`, role de execução, `--cloudformation-execution-policies`, fim do CDK v1): https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd-bootstrap.html
- `HealthChecks` do Auto Scaling na API Python do CDK: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_autoscaling/HealthChecks.html
- `aws_rds` na API Python do CDK: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_rds/README.html
- `ec2.Vpc` na API Python do CDK: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_ec2/Vpc.html
- Cotas do CloudFormation: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/cloudformation-limits.html
- Preços do CloudFormation: https://aws.amazon.com/cloudformation/pricing
- `continue-update-rollback` na AWS CLI: https://docs.aws.amazon.com/cli/latest/reference/cloudformation/continue-update-rollback.html
- Detecção de drift no CloudFormation: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-drift.html
- Importar recursos existentes para uma stack: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/resource-import.html
