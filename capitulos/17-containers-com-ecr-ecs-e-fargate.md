# Containers com ECR, ECS e Fargate

No capítulo 16, a senha do banco saiu dos arquivos. A configuração foi para o Parameter Store, em `/rango/producao/...`, o segredo do usuário `rango` passou a girar sozinho no Secrets Manager com usuários alternados, e uma chave do KMS protege esse segredo. Cada instância monta o `api.env` no boot, pelos VPC endpoints, e vive no máximo sete dias. No fim, o `cdk destroy` desligou tudo, e ficaram a zona, o certificado, o bucket de fotos, um snapshot do banco e a AMI `rango-api-20261015`, que ainda guarda o código antigo e uma senha que não funciona mais.

## Uma linha, uma hora e quarenta

Terça-feira, 10h. O Bruno, da Sabor do Sertão, avisa que a listagem de pedidos mostra a hora em UTC, três horas adiantada. A correção é uma linha no `banco.py`. Você testa no Compose, com a imagem `rango-api:0.7.0` que roda no seu notebook desde o capítulo 12, e funciona na primeira tentativa.

Agora a parte de levar essa linha para produção. Você sobe uma instância de montagem numa subnet pública, a partir da AMI atual. Cadastra de novo a deploy key no GitHub, porque ela foi removida por segurança no capítulo 13. Roda `git pull` e `pip install`. O `pip` reclama de uma dependência que mudou de versão desde outubro. Você resolve, cria a AMI `rango-api-20261103`, troca o nome no `MachineImage.lookup`, roda `cdk deploy`, dispara o instance refresh e espera as instâncias serem trocadas uma a uma. Apaga a instância de montagem e remove a deploy key de novo. Uma hora e quarenta minutos para uma linha.

Repare numa coisa estranha nesse processo. A imagem Docker que você constrói e testa desde o capítulo 3 nunca chegou a produção. Em produção roda outra coisa: um Amazon Linux com Python instalado por `dnf`, units do systemd e um `venv` em `/opt/rango`. São dois ambientes diferentes, mantidos por dois caminhos diferentes, e o "na minha máquina funciona" do capítulo 3 voltou pela porta dos fundos.

E tem o sistema operacional. Suponha que, na mesma semana, saia um aviso de segurança do Amazon Linux 2023 para o OpenSSL (situação hipotética, mas avisos assim são frequentes). As instâncias só recebem a correção quando alguém refaz a AMI, e ninguém tem isso na agenda.

O que você quer é o que já tem no notebook: uma imagem com o código e as dependências, construída uma vez, com uma tag, e que roda igual em qualquer lugar. Falta onde guardar essa imagem na AWS e quem rode os containers por você.

## Três serviços para uma imagem

O capítulo 3 apresentou as peças: imagem, registry, container e orquestrador. A AWS separou cada uma num serviço.

O **Amazon ECR** (*Elastic Container Registry*) é o registry. Funciona como o Docker Hub, com o mesmo `docker push` e `docker pull`, mas privado, dentro da sua conta, com acesso controlado pelo IAM. Cada imagem mora num repositório, e cada versão é identificada por uma tag e por um *digest*, o hash SHA-256 do conteúdo.

O **Amazon ECS** (*Elastic Container Service*) é o orquestrador. Você declara quantas cópias de qual imagem quer rodar, com quanta CPU e memória, e ele reconcilia: sobe o que falta, substitui o que morreu, registra cada container no load balancer. É a mesma ideia de estado desejado do Kubernetes, com menos peças. O ECS em si não cobra nada. Você paga pela capacidade onde os containers rodam.

E essa capacidade pode vir de dois lugares. No modo EC2, os containers rodam em instâncias suas, que você escolhe, atualiza e escala. No **AWS Fargate**, não há instância à vista. Você diz "0,5 vCPU e 1 GB" e a AWS arranja a máquina, roda o container e cobra pelo tempo de uso. O sistema operacional por baixo, o patch do kernel, o agente do ECS: tudo isso passa a ser problema da AWS, na divisão do modelo de responsabilidade compartilhada do capítulo 7. O aviso de segurança do OpenSSL no Amazon Linux deixa de ser seu. O da imagem `python:3.12-slim` continua sendo, porque a imagem é sua.

Para o Rangô, a escolha é Fargate. O motivo de sair da AMI é parar de cuidar de servidor, e o modo EC2 traria o servidor de volta.

### O vocabulário do ECS

Quatro termos aparecem o tempo todo.

O **cluster** é um agrupamento lógico de serviços e tarefas. Com Fargate, ele não tem máquinas; é um nome e um lugar para pendurar configurações.

A **task definition** é a receita: imagem, CPU, memória, portas, variáveis de ambiente, segredos, comando, destino dos logs e as roles do IAM. Se você conhece o `compose.yaml`, a task definition é a entrada de um serviço dele, só que em JSON e versionada. Cada alteração cria uma revisão nova, como `rango-api:7`, e as antigas continuam lá, o que torna o rollback uma questão de apontar para a revisão anterior. No Kubernetes, o equivalente é a especificação do pod.

A **task** é uma execução da task definition: um ou mais containers rodando juntos, com o mesmo endereço de rede. Ela é para a task definition o que o container é para a imagem.

O **service** mantém um número de tasks rodando o tempo todo, troca as que caem, faz o deploy gradual de uma revisão nova e registra cada task num target group do ALB. Ele junta o papel do Deployment e do Service do Kubernetes, e faz pelas tasks o que o Auto Scaling Group fazia pelas instâncias no capítulo 13.

### Cada task com seu próprio IP

No Fargate, toda task usa o modo de rede `awsvpc`: ela ganha uma interface de rede própria numa subnet da sua VPC, com um IP privado e um Security Group. Para a rede, cada task parece uma instância pequena. O target group passa a ser do tipo `ip`, apontando para esses endereços, em vez do tipo `instance` do capítulo 13.

Isso tem uma consequência que vai aparecer no mão na massa. Tudo o que a task precisa buscar antes de o container nascer, como a imagem no ECR e os segredos, sai por essa interface, na subnet onde a task está. Se a subnet não tiver caminho até esses serviços, a task não sobe.

### As duas roles de uma task

Uma task tem duas roles, e confundir as duas é um dos erros mais comuns do ECS.

A **task execution role** é usada pelo próprio ECS, antes e em volta do seu código. Com ela, o agente baixa a imagem do ECR, busca os segredos no Secrets Manager e no Parameter Store e escreve os logs no CloudWatch. O seu código nunca a vê.

A **task role** é a do seu código. É ela que o `boto3` encontra dentro do container, pela mesma cadeia de credenciais do capítulo 8, quando a API gera uma presigned URL para o bucket de fotos. Ela substitui o instance profile da EC2.

Se a permissão de S3 for parar na execution role, a API recebe `AccessDenied` ao gerar a URL. Se a permissão do segredo for parar na task role, a task nem chega a subir.

### Segredos como campo da task definition

O capítulo 16 terminou com uma promessa: o segredo do banco vira um campo na definição da tarefa. Na task definition, além de `environment`, com valores em texto, existe a lista `secrets`. Cada item diz o nome da variável e de onde o ECS deve buscar o valor:

```json
"secrets": [
  {
    "name": "PGPASSWORD",
    "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789012:secret:SegredoApp-AbCdEf:password::"
  },
  {
    "name": "REDIS_URL",
    "valueFrom": "arn:aws:ssm:us-east-1:123456789012:parameter/rango/producao/redis_url"
  }
]
```

O `valueFrom` do Secrets Manager segue o formato `arn:...:secret:nome:json-key:version-stage:version-id`. O `password` depois do nome escolhe uma chave dentro do JSON do segredo. Os dois campos seguintes ficaram vazios, o que significa a versão `AWSCURRENT`. Os dois-pontos finais são obrigatórios mesmo vazios, e esquecê-los é uma fonte clássica de erro quando se escreve o JSON à mão. O `valueFrom` também aceita o ARN de um parâmetro do Parameter Store, como no segundo item.

Na hora em que a task sobe, o agente usa a execution role, busca cada valor e entrega ao container como variável de ambiente. O segredo não passa pelo user data, não fica em disco e não aparece na task definition. Para pedir uma chave específica do JSON, como `password`, o Fargate precisa da *platform version* 1.4.0 ou mais nova no Linux, que é a versão padrão hoje.

A busca acontece uma única vez, no início da task. Uma rotação depois disso não chega aos containers que já estão rodando. Guarde essa frase, porque ela vai voltar duas vezes neste capítulo.

## Mão na massa: o Rangô em containers

O plano: criar um repositório no ECR numa stack separada, construir e enviar a imagem, trocar o Auto Scaling Group e a AMI por um cluster ECS com Fargate, e colocar os workers em containers também.

### Pré-requisitos

O projeto `rango-infra/` do capítulo 16, o Docker com o `buildx` (que vem no Docker Desktop e nas instalações recentes do Docker Engine) e o profile de desenvolvimento:

```bash
cd rango-infra
source .venv/bin/activate
export AWS_PROFILE=rango-dev
aws sso login
```

No `app.py`, o `snapshot_db` recebe o nome do snapshot final do capítulo 16, que você encontra com o mesmo `describe-db-snapshots`.

### A imagem de produção

O Dockerfile do capítulo 3 serve quase sem mudanças. Falta o certificado da CA do RDS. A `database_url` do Parameter Store aponta para `/etc/rango/rds-ca.pem`, e antes esse arquivo era colocado na instância pelo processo da AMI. Agora ele precisa estar na imagem. Baixe o bundle para a pasta do backend:

```bash
curl -sS -o backend/rds-ca.pem \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
```

E acrescente uma linha ao Dockerfile:

```dockerfile
# backend/Dockerfile
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY rds-ca.pem /etc/rango/rds-ca.pem
COPY app ./app

RUN useradd --create-home rango
USER rango

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

O certificado de uma CA é público; colocá-lo na imagem não expõe nada. A mesma imagem vai servir à API e aos dois workers, que só trocam o `CMD`.

### O repositório, numa stack à parte

O repositório precisa existir e já ter uma imagem antes de o serviço do ECS ser criado. Se ele nascesse na mesma stack, o serviço tentaria subir tasks com uma imagem que ninguém enviou ainda. Além disso, as imagens precisam sobreviver a um `cdk destroy` da produção. Por isso o repositório vai para uma stack própria, `rango_infra/registro_stack.py`:

```python
from aws_cdk import Duration, RemovalPolicy, Stack, aws_ecr as ecr
from constructs import Construct


class RegistroStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        ecr.Repository(
            self,
            "Api",
            repository_name="rango-api",
            image_scan_on_push=True,
            image_tag_mutability=ecr.TagMutability.IMMUTABLE,
            lifecycle_rules=[
                ecr.LifecycleRule(
                    description="Apaga imagens sem tag",
                    tag_status=ecr.TagStatus.UNTAGGED,
                    max_image_age=Duration.days(1),
                ),
                ecr.LifecycleRule(
                    description="Guarda as 30 imagens mais recentes",
                    max_image_count=30,
                ),
            ],
            removal_policy=RemovalPolicy.RETAIN,
        )
```

Três decisões estão nessas linhas.

As tags são imutáveis. Uma vez que `rango-api:3f9c2b1` foi enviada, ninguém consegue enviar outra imagem com a mesma tag. No capítulo 3, a armadilha era a `latest`, que aponta para coisas diferentes ao longo do tempo. Aqui, a tag é o hash do commit, como o pipeline do capítulo 6 já fazia, e o ECR garante que ela sempre signifique a mesma imagem.

O `image_scan_on_push` faz a varredura básica de vulnerabilidades a cada push, comparando os pacotes da imagem com bancos de CVEs conhecidos. É assim que você descobre que a `python:3.12-slim` de três meses atrás tem pacotes do Debian com correção disponível.

As regras de ciclo de vida são o lifecycle do S3, do capítulo 11, aplicado a imagens: as sem tag somem depois de um dia, e o repositório guarda as 30 mais recentes. O armazenamento no ECR custa cerca de US$ 0,10 por GB por mês (us-east-1, outubro de 2026; confirme na página oficial de preços), e um pipeline que envia uma imagem a cada commit enche o repositório rápido.

No `app.py`, as duas stacks dividem o mesmo ambiente, e a produção ganha a versão da imagem como parâmetro:

```python
import os

import aws_cdk as cdk

from rango_infra.rango_infra_stack import RangoInfraStack
from rango_infra.registro_stack import RegistroStack

app = cdk.App()
env = cdk.Environment(account=os.environ["CDK_DEFAULT_ACCOUNT"], region="us-east-1")

RegistroStack(app, "RangoRegistro", env=env)

RangoInfraStack(
    app,
    "RangoProducao",
    ambiente="producao",
    dominio="rango.com.br",
    certificado_arn=app.node.try_get_context("certificado_arn"),
    snapshot_db="rangoproducao-snapshot-banco-f6e5d4c3b2a1",
    versao_api=app.node.try_get_context("versao_api"),
    env=env,
)

app.synth()
```

Troque o nome do snapshot pelo seu e crie só o registro por enquanto:

```bash
cdk deploy RangoRegistro
```

### Build e push

O ECR autentica o Docker com um token temporário, gerado a partir da sua sessão SSO. Nenhuma senha fica guardada:

```bash
CONTA=$(aws sts get-caller-identity --query Account --output text)
REGISTRO="$CONTA.dkr.ecr.us-east-1.amazonaws.com"

aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "$REGISTRO"
```

O token vale 12 horas. Agora o build, com uma escolha de arquitetura:

```bash
VERSAO=$(git rev-parse --short HEAD)

docker buildx build --platform linux/arm64 \
  -t "$REGISTRO/rango-api:$VERSAO" --push backend/
```

O `linux/arm64` é para rodar no Graviton, que no Fargate custa cerca de 20% menos que x86 (us-east-1, outubro de 2026). Num notebook x86, o `buildx` usa emulação e fica mais lento, mas funciona. A task definition vai declarar ARM explicitamente, para não repetir o `exec format error` do capítulo 3.

Depois do push, confira a varredura:

```bash
aws ecr describe-image-scan-findings --repository-name rango-api \
  --image-id imageTag="$VERSAO" \
  --query "imageScanFindings.findingSeverityCounts"
```

```json
{
    "MEDIUM": 6,
    "LOW": 19
}
```

Os números variam com a data do build. Se aparecer `CRITICAL` ou `HIGH`, comece reconstruindo com a base atualizada (`--pull`).

### A produção sem servidor à vista

Em `rango_infra/rango_infra_stack.py`, muita coisa sai. Apague o bloco do user data e o arquivo `user_data/configurar.sh`, o Launch Template, o Auto Scaling Group com o `max_instance_lifetime` e o `add_dependency`, a `role_api`, o ALB com os listeners e o `add_targets`, o registro `ApiA` e a saída `AsgNome`. Nos imports, saem `aws_autoscaling` e o `Path`, e entram estes:

```python
from aws_cdk import (
    # ... os imports do capítulo 16, sem aws_autoscaling ...
    aws_ecr as ecr,
    aws_ecs as ecs,
    aws_ecs_patterns as ecs_patterns,
    aws_logs as logs,
)
```

O construtor ganha o parâmetro `versao_api: str`, ao lado de `snapshot_db`.

Duas mudanças pequenas no que já existia. A primeira: os parâmetros do Parameter Store passam a ser um dicionário, para que cada um vire uma variável do container. Os IDs dos constructs continuam os mesmos:

```python
        parametros = {
            nome: ssm.StringParameter(
                self,
                f"Config_{nome}",
                parameter_name=f"/rango/{ambiente}/{nome}",
                string_value=valor,
            )
            for nome, valor in configuracao.items()
        }
```

A segunda: a busca da zona (`route53.HostedZone.from_lookup`) e o `certificado` sobem para antes do código novo, porque o serviço da API vai usar os dois.

### Os endpoints que faltavam

As tasks vão rodar nas subnets `PRIVATE_ISOLATED`, sem NAT, como as instâncias rodavam. Elas já alcançam o Parameter Store e o Secrets Manager pelos endpoints do capítulo 16, e o S3 pelo gateway endpoint do capítulo 15. Faltam três caminhos:

```python
        endpoints = [endpoint_ssm, endpoint_sm]
        for nome, servico in (
            ("EcrApi", ec2.InterfaceVpcEndpointAwsService.ECR),
            ("EcrDocker", ec2.InterfaceVpcEndpointAwsService.ECR_DOCKER),
            ("Logs", ec2.InterfaceVpcEndpointAwsService.CLOUDWATCH_LOGS),
        ):
            endpoints.append(
                vpc.add_interface_endpoint(nome, service=servico, subnets=privadas)
            )
```

O `ecr.api` atende as chamadas de autenticação e de metadados das imagens. O `ecr.dkr` atende o protocolo do Docker, o manifesto da imagem. E as camadas propriamente ditas, os bytes pesados, o ECR serve a partir do S3, e por isso o gateway endpoint do S3 também entra na conta. O endpoint de logs leva a saída do container ao CloudWatch Logs.

Sem esses três, o deploy fica preso com tasks que nascem e morrem, e o motivo aparece nos eventos do serviço. Esse erro está nas armadilhas, com a mensagem.

### Cluster, logs, role e imagem

```python
        cluster = ecs.Cluster(self, "Cluster", vpc=vpc, cluster_name=f"rango-{ambiente}")

        logs_app = logs.LogGroup(
            self,
            "LogsApp",
            retention=logs.RetentionDays.ONE_MONTH,
            removal_policy=RemovalPolicy.DESTROY,
        )

        role_app = iam.Role(
            self, "RoleApp", assumed_by=iam.ServicePrincipal("ecs-tasks.amazonaws.com")
        )
        role_app.add_to_policy(
            iam.PolicyStatement(
                actions=["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
                resources=[f"arn:aws:s3:::rango-fotos-pratos-{self.account}/fotos/*"],
            )
        )

        repositorio = ecr.Repository.from_repository_name(self, "RepoApi", "rango-api")
        imagem = ecs.ContainerImage.from_ecr_repository(repositorio, tag=versao_api)

        plataforma = ecs.RuntimePlatform(
            cpu_architecture=ecs.CpuArchitecture.ARM64,
            operating_system_family=ecs.OperatingSystemFamily.LINUX,
        )
```

O grupo de logs resolve uma pendência do capítulo 13: os logs viviam no journal de cada instância e morriam com ela. Agora o JSON do `logs.py` vai para o CloudWatch Logs por 30 dias, e o capítulo 22 vai consultá-lo a sério.

A `role_app` é a task role. Ela tem só as três ações no bucket de fotos, as mesmas da `role_api`, e é assumida pelo principal `ecs-tasks.amazonaws.com` em vez do `ec2.amazonaws.com`. Saíram a policy do Session Manager, que não tem uso sem instância, e as permissões de leitura de parâmetros e segredos, que agora são da execution role.

O `from_repository_name` aponta para o repositório da outra stack pelo nome, do mesmo jeito que a zona entra por lookup.

### As variáveis do container

```python
        variaveis = {
            nome.upper(): ecs.Secret.from_ssm_parameter(parametro)
            for nome, parametro in parametros.items()
        }
        variaveis["PGUSER"] = ecs.Secret.from_secrets_manager(segredo_app, field="username")
        variaveis["PGPASSWORD"] = ecs.Secret.from_secrets_manager(
            segredo_app, field="password"
        )
```

Compare com o `configurar.sh` do capítulo 16. Lá, um `awk` transformava `/rango/producao/redis_url` em `REDIS_URL=...` e um trecho de Python extraía usuário e senha do JSON. Aqui, o `nome.upper()` faz o papel do `awk`, e o `field` escolhe a chave do JSON, gerando o `:password::` que você viu no `valueFrom`.

Os parâmetros de configuração não são secretos. Eles passam pela lista `secrets` porque assim o valor continua morando no Parameter Store, por ambiente, e a task definition guarda só o ARN. Isso tem um efeito colateral bom: o CDK dá à execution role permissão de leitura em cada parâmetro e no segredo, inclusive o `kms:Decrypt` na chave do capítulo 16, sem uma linha a mais.

### O serviço da API

O capítulo 15 prometeu os constructs L3, os *patterns*. O `ApplicationLoadBalancedFargateService` monta de uma vez o ALB, os listeners, o target group, a task definition, o serviço e o registro no Route 53:

```python
        api = ecs_patterns.ApplicationLoadBalancedFargateService(
            self,
            "ServicoApi",
            cluster=cluster,
            cpu=512,
            memory_limit_mib=1024,
            desired_count=2,
            min_healthy_percent=100,
            runtime_platform=plataforma,
            task_image_options=ecs_patterns.ApplicationLoadBalancedTaskImageOptions(
                image=imagem,
                container_port=8000,
                secrets=variaveis,
                task_role=role_app,
                log_driver=ecs.LogDrivers.aws_logs(
                    stream_prefix="api", log_group=logs_app
                ),
            ),
            task_subnets=privadas,
            security_groups=[sg_api],
            public_load_balancer=True,
            certificate=certificado,
            ssl_policy=elbv2.SslPolicy.RECOMMENDED_TLS,
            redirect_http=True,
            domain_name=f"api.{dominio}",
            domain_zone=zona,
            circuit_breaker=ecs.DeploymentCircuitBreaker(rollback=True),
        )
        api.target_group.configure_health_check(
            path="/health",
            interval=Duration.seconds(10),
            healthy_threshold_count=2,
            unhealthy_threshold_count=2,
        )
        api.target_group.set_attribute("deregistration_delay.timeout_seconds", "30")

        escala = api.service.auto_scale_task_count(min_capacity=2, max_capacity=6)
        escala.scale_on_request_count(
            "Requisicoes", requests_per_target=600, target_group=api.target_group
        )
        api.node.add_dependency(rotacao, *endpoints)
```

Quase tudo aqui é o capítulo 13 com outro nome. O health check em `/health` com 10 segundos e 2 de 2, o deregistration delay de 30 segundos, o target tracking de 600 requisições por minuto por alvo, o mínimo de 2 e o máximo de 6 (o limite que as conexões do RDS impuseram no capítulo 13). A diferença é o que escala: tasks, que sobem em segundos, em vez de instâncias, que levavam minutos.

O tamanho da task, 0,5 vCPU e 1 GB, segue o raciocínio do GIL do capítulo 4: um processo Uvicorn usa no máximo um núcleo, e a escala vem de mais tasks. O Fargate só aceita algumas combinações; com 0,5 vCPU, a memória vai de 1 a 4 GB.

O `min_healthy_percent=100` diz como o deploy acontece. Com o máximo padrão de 200%, o ECS sobe as tasks novas ao lado das antigas, espera o health check passar e só então drena e para as antigas. Nunca há menos de duas tasks saudáveis.

O `circuit_breaker` com `rollback=True` vigia esse deploy. Se as tasks novas falham repetidamente, o ECS marca o deploy como falho e volta para a revisão anterior da task definition. Como o deploy está dentro do CloudFormation, a stack também reverte.

O `add_dependency` repete a lição do capítulo 16: o serviço só nasce depois que os endpoints e a agenda de rotação existem.

Quando a task para, num deploy ou numa redução de escala, o ECS manda `SIGTERM` ao processo principal e espera 30 segundos por padrão antes do `SIGKILL`. O `CMD` em forma de lista do capítulo 3 garante que o sinal chegue ao Uvicorn, que termina as requisições em andamento.

### Os workers

Os workers do capítulo 5 não recebem tráfego HTTP. Eles leem o stream no Valkey e precisam só de um serviço que os mantenha vivos:

```python
        for grupo in ("restaurante", "email"):
            tarefa = ecs.FargateTaskDefinition(
                self,
                f"TarefaWorker_{grupo}",
                cpu=256,
                memory_limit_mib=512,
                runtime_platform=plataforma,
            )
            tarefa.add_container(
                "worker",
                image=imagem,
                command=["python", "-m", "app.worker", grupo],
                secrets=variaveis,
                logging=ecs.LogDrivers.aws_logs(
                    stream_prefix=f"worker-{grupo}", log_group=logs_app
                ),
            )
            worker = ecs.FargateService(
                self,
                f"Worker_{grupo}",
                cluster=cluster,
                task_definition=tarefa,
                desired_count=1,
                min_healthy_percent=100,
                vpc_subnets=privadas,
                security_groups=[sg_api],
                circuit_breaker=ecs.DeploymentCircuitBreaker(rollback=True),
            )
            worker.node.add_dependency(rotacao, *endpoints)
```

É a template unit `rango-worker@.service` do capítulo 9, com o `%i` virando o `grupo` do laço. A imagem é a mesma da API; o `command` troca o Uvicorn pelo worker. Os workers não recebem a `role_app`, porque não mexem nas fotos. O CDK cria para eles uma task role vazia.

O `sg_api` serve aos três serviços porque é ele que o banco e o cache aceitam desde o capítulo 15. O pattern acrescenta nele a regra que libera a porta 8000 vindo do Security Group do ALB.

Por fim, as saídas:

```python
        CfnOutput(self, "Cluster", value=cluster.cluster_name)
        CfnOutput(self, "ServicoApiNome", value=api.service.service_name)
        CfnOutput(self, "SegredoAppArn", value=segredo_app.secret_arn)
```

### Deploy

```bash
cdk diff RangoProducao -c versao_api="$VERSAO"
cdk deploy RangoProducao -c versao_api="$VERSAO"
```

O deploy leva uns 15 minutos, quase todos do banco restaurando do snapshot. Quando terminar, guarde as saídas com a função `saida` do capítulo 16:

```bash
CLUSTER=$(saida Cluster)
SERVICO=$(saida ServicoApiNome)
```

Lembra da frase sobre os segredos? A situação do capítulo 16 se repete. A stack criou um segredo novo com uma senha gerada pelo CDK, e a primeira rotação acontece em paralelo com a subida das tasks. Uma task que leu o segredo antes da rotação terminar ficou com uma senha que o banco nunca conheceu. O `/health` não toca no banco (o capítulo 4 explicou por quê), então essa task parece saudável e devolve erro 500 em `/pedidos`. Espere a rotação terminar, confira com o `describe-secret` do capítulo 16 e troque todas as tasks:

```bash
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICO" \
  --force-new-deployment > /dev/null
```

Faça o mesmo para os dois workers. O *force new deployment* é o instance refresh do ECS: as tasks são substituídas com as regras do deploy normal, e as novas leem o segredo atual.

Acompanhe o deploy:

```bash
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICO" \
  --query "services[0].deployments[].[status,rolloutState,runningCount]" \
  --output table
```

```text
-----------------------------------------
|           DescribeServices            |
+----------+---------------+------------+
|  PRIMARY |  IN_PROGRESS  |  2         |
|  ACTIVE  |  COMPLETED    |  2         |
+----------+---------------+------------+
```

Por um momento, há quatro tasks: duas novas (`PRIMARY`) e duas antigas (`ACTIVE`). Um minuto depois, sobra só a linha `PRIMARY` com `COMPLETED`.

Suba o front com os dois comandos de sync do capítulo 14 e teste:

```bash
for i in 1 2 3 4; do
  curl -s -o /dev/null -D - https://api.rango.com.br/health | grep -i x-rango-instancia
done
```

```text
x-rango-instancia: ip-10-20-10-87.ec2.internal
x-rango-instancia: ip-10-20-11-142.ec2.internal
x-rango-instancia: ip-10-20-10-87.ec2.internal
x-rango-instancia: ip-10-20-11-142.ec2.internal
```

O cabeçalho do capítulo 4 mostra cada task pelo IP privado dela, uma em cada AZ. E os logs estão num lugar só:

```bash
aws logs tail "$(aws logs describe-log-groups \
  --log-group-name-prefix RangoProducao-LogsApp \
  --query 'logGroups[0].logGroupName' --output text)" --since 5m
```

### A linha do Bruno, de novo

Volte à correção do fuso horário. Agora o caminho é este:

```bash
git commit -am "Listagem de pedidos no fuso de Sao Paulo"
VERSAO=$(git rev-parse --short HEAD)
docker buildx build --platform linux/arm64 \
  -t "$REGISTRO/rango-api:$VERSAO" --push backend/
cdk deploy RangoProducao -c versao_api="$VERSAO"
```

O `cdk diff` mostraria uma única mudança: a tag da imagem nas três task definitions, que ganham revisões novas. O deploy troca as tasks da API e dos workers e termina em poucos minutos. Ninguém entrou em servidor nenhum, e a imagem que roda em produção é a mesma que você testou com `docker run` no notebook.

Para ver o circuit breaker trabalhar, construa uma versão com `--platform linux/amd64`, envie e faça o deploy com essa tag. As tasks novas morrem logo depois de subir, com `exec format error` no log, enquanto as antigas continuam atendendo. Depois de algumas falhas, o ECS marca o deploy como `FAILED`, volta para a revisão anterior, e o CloudFormation reverte a stack. Em nenhum momento o `api.rango.com.br` saiu do ar.

O capítulo 18 vai tirar esses comandos do seu terminal e colocá-los num pipeline.

### A AMI pode ir embora

A AMI `rango-api-20261015` não tem mais função, e ainda guarda o `api.env` com a senha morta. Uma AMI tem um snapshot de EBS por trás, que continua cobrando depois que a AMI some, então apague os dois:

```bash
AMI=$(aws ec2 describe-images --owners self \
  --filters Name=name,Values=rango-api-20261015 \
  --query "Images[0].ImageId" --output text)
SNAP=$(aws ec2 describe-images --image-ids "$AMI" \
  --query "Images[0].BlockDeviceMappings[0].Ebs.SnapshotId" --output text)

aws ec2 deregister-image --image-id "$AMI"
aws ec2 delete-snapshot --snapshot-id "$SNAP"
```

Rode também `cdk context --clear`, para tirar do `cdk.context.json` o lookup da AMI que não existe mais.

### Quanto custa

Com os preços de Fargate em ARM em us-east-1 (outubro de 2026, aproximados; confira a página oficial), a conta fica assim:

| Serviço | Tasks | Tamanho | Por mês (730 h) |
|---|---|---|---|
| API | 2 | 0,5 vCPU, 1 GB | ~US$ 29 |
| Workers | 2 | 0,25 vCPU, 0,5 GB | ~US$ 14 |
| Endpoints novos | 3 × 2 AZs | | ~US$ 44 |

O cálculo da API: 0,5 × US$ 0,032380 por vCPU-hora mais 1 × US$ 0,003560 por GB-hora dá cerca de US$ 0,0198 por hora por task. O Fargate cobra por segundo, com mínimo de um minuto, desde o início do download da imagem até a task terminar.

Duas `t3.micro` custavam perto de US$ 15 por mês e rodavam API e workers juntos. O Fargate cobra mais pelo mesmo processamento; a diferença paga o tempo que você deixou de gastar com AMI e patches.

Os endpoints merecem atenção. Somados aos dois do capítulo 16, são cinco interface endpoints em duas AZs, cerca de US$ 73 por mês, praticamente o preço de dois NAT Gateways sem contar o tráfego. Para o Rangô, a balança ainda pende para os endpoints: nada sai para a internet, e não há cobrança por GB processado no NAT. Mas, se a aplicação precisasse chamar APIs externas, como um gateway de pagamento, o NAT voltaria de qualquer jeito, e aí muitos endpoints deixariam de compensar.

### Desligar

```bash
cdk destroy RangoProducao
```

O banco sai com snapshot final, como nos capítulos anteriores; anote o nome. O cluster, os serviços, o ALB, os endpoints e o grupo de logs saem junto. A stack `RangoRegistro` fica, com o repositório e as imagens; algumas centenas de megabytes custam centavos por mês. A chave do KMS entra em `PendingDeletion` por sete dias, como no capítulo 16.

## E o Kubernetes?

O capítulo 3 apresentou o Kubernetes, e a AWS tem o Amazon EKS (*Elastic Kubernetes Service*). O EKS gerencia o control plane: a API do Kubernetes, o etcd e os controladores rodam em várias AZs por conta da AWS. Você continua com o `kubectl`, os manifests e as ferramentas do mundo Kubernetes, como Helm e os operators.

O control plane custa US$ 0,10 por hora por cluster, cerca de US$ 73 por mês, antes de rodar qualquer pod (us-east-1, outubro de 2026). Cada versão do Kubernetes tem 14 meses de suporte padrão. Depois disso, o cluster entra em suporte estendido por mais 12 meses e passa a custar US$ 0,60 por hora, seis vezes mais. É o mesmo mecanismo do Extended Support do RDS, do capítulo 12: quem não atualiza paga. E atualizar um cluster Kubernetes envolve também os add-ons, os nós e as APIs que foram removidas entre versões.

Os pods podem rodar em instâncias que você gerencia, no próprio Fargate ou no EKS Auto Mode, em que a AWS escolhe e mantém as instâncias em troca de uma taxa extra por instância sobre o preço da EC2.

Quando o EKS vale a pena? Quando a equipe já domina Kubernetes e tem manifests, charts e processos prontos. Quando a empresa precisa da mesma plataforma em mais de uma nuvem ou no próprio data center. Quando a aplicação depende de algo que só existe no mundo Kubernetes, como um operator de banco ou uma malha de serviços específica. E quando são dezenas de serviços e várias equipes, em que o investimento numa plataforma se paga.

Para o Rangô, com uma API, dois workers e uma pessoa cuidando da infraestrutura, o ECS faz o mesmo trabalho sem o custo fixo e sem as atualizações de versão a cada ano.

> **Dica:** Existe um caminho ainda mais curto no ECS. O ECS Express Mode, lançado em novembro de 2025, recebe só a imagem e cria cluster, task definition, ALB, auto scaling e uma URL. Ele não cobra nada além dos recursos criados, que ficam visíveis e editáveis na sua conta, e até 25 serviços Express podem dividir o mesmo ALB. É uma boa porta de entrada para um protótipo. Para o Rangô, que já tem VPC, certificado e regras de rede próprias, o CDK dá o controle que o Express Mode esconde.

## Armadilhas e casos reais

> **Armadilha:** Subnet sem caminho para o ECR. Sem os endpoints `ecr.api` e `ecr.dkr` (ou sem NAT), a task fica em `PROVISIONING` por um tempo e para com um motivo que começa com `ResourceInitializationError: unable to pull secrets or registry auth`. A mensagem fala de segredos e de registry ao mesmo tempo porque as duas buscas acontecem na mesma etapa, pela interface da task. Confira os endpoints, o gateway endpoint do S3 e o Security Group dos endpoints, que precisa aceitar a porta 443 vindo das tasks.

> **Armadilha:** Rotação não chega à task. O ECS lê o segredo uma vez, quando a task sobe. Com usuários alternados, a senha lida continua válida até a rotação seguinte à próxima, ou seja, por pelo menos 30 dias. Uma task da API que viva mais que isso perde o acesso ao banco sem aviso. O `max_instance_lifetime` do capítulo 16 não tem equivalente direto no ECS. Na prática, deploys frequentes resolvem, e o pipeline do capítulo 18 vai garantir que eles aconteçam; até lá, um `--force-new-deployment` por semana cumpre o papel.

> **Armadilha:** Permissão na role errada. `AccessDenied` ao gerar a presigned URL quer dizer que a permissão do S3 está na execution role. Task parada antes de subir, com erro de segredo, quer dizer que a permissão do segredo está na task role, ou falta o `kms:Decrypt`. Antes de mexer em policy, descubra qual das duas roles está envolvida.

> **Armadilha:** Variável de ambiente é visível para tudo dentro do container: ferramentas de debug, bibliotecas que despejam o ambiente em mensagens de erro, um `print(os.environ)` esquecido. Nunca registre o ambiente em log; o CloudWatch Logs guardaria a senha por 30 dias.

> **Armadilha:** Imagem gorda custa dinheiro. O Fargate cobra a partir do início do download da imagem, e uma imagem de 2 GB demora a baixar a cada task nova, inclusive nas que o auto scaling cria no meio de um pico. Mantenha a base `slim`, o `.dockerignore` em dia e as ferramentas de build fora da imagem final. Cada task tem 20 GB de armazenamento temporário sem custo; o que passar disso é cobrado à parte.

> **Dica:** Fargate Spot roda tasks em capacidade ociosa da AWS com desconto de até 70%, só no ECS e só em Linux. A AWS pode interromper a task com dois minutos de aviso. A API precisa estar sempre de pé e fica no Fargate normal, mas os workers são bons candidatos: eles processam de forma idempotente desde o capítulo 5, e uma mensagem interrompida volta a ser processada. O cuidado é o mesmo do capítulo 13: as mensagens pendentes ficam presas ao nome do consumidor que sumiu até alguém reivindicá-las. O capítulo 21 troca esses workers por filas do SQS, e o Fargate Spot volta no capítulo 24, no ambiente de homologação.

> **Na vida real:** Muitas equipes usam o `ecs.ContainerImage.from_asset("../backend")` do CDK, que constrói e envia a imagem dentro do `cdk deploy`. É prático para começar. O repositório próprio, com tags imutáveis, separa o build do deploy: a imagem testada no CI é a que vai para produção, e voltar uma versão é fazer o deploy de uma tag antiga.

## Resumo

- O ECR guarda imagens com acesso pelo IAM. Tags imutáveis com o hash do commit, varredura no push e regras de ciclo de vida evitam a `latest` e o repositório inchado.
- O ECS orquestra: task definition é a receita versionada, task é a execução, service mantém o número de tasks, faz o deploy gradual e registra no ALB. O ECS não cobra; a capacidade, sim.
- O Fargate tira o servidor de cena e cobra por vCPU e memória por segundo. Em ARM, sai cerca de 20% mais barato.
- Execution role é do ECS (imagem, segredos, logs); task role é do seu código.
- Segredos entram pela lista `secrets` da task definition, lidos uma vez quando a task sobe. Rotação exige tasks novas.
- O Rangô roda em três serviços Fargate em subnets isoladas, com cinco interface endpoints, circuit breaker e logs no CloudWatch. A AMI foi apagada.
- O EKS vale a pena com equipe que já domina Kubernetes, muitas aplicações ou necessidade de portabilidade, e custa US$ 0,10 por hora por cluster antes do primeiro pod.

## Sexta-feira, 18h

O deploy encolheu para quatro comandos, mas eles ainda rodam no seu notebook, com a sua sessão SSO e o seu Docker. Na sexta-feira às 18h, o Bruno pede uma correção urgente no cálculo da taxa de entrega antes do movimento do fim de semana. Você está no aniversário da sua sobrinha, e a outra pessoa da equipe não tem o `buildx` configurado nem permissão para rodar `cdk deploy`. Ou pior: tem, e roda a partir de uma branch que não passou pelos testes.

Quem garante que a imagem em produção veio do commit que passou no CI? Quem decide que o deploy pode seguir, e quem aperta o botão de voltar quando a versão nova começa a devolver erro 500? No próximo capítulo, o GitHub Actions assume o build, o push para o ECR e o deploy no ECS, autenticado na AWS por OIDC, sem nenhuma chave de longa duração guardada no GitHub. E o deploy ganha o blue/green nativo do ECS, com tráfego de teste antes da troca e rollback automático por alarme.

## Referências

- Amazon ECR, preços: https://aws.amazon.com/ecr/pricing
- AWS Fargate, preços: https://aws.amazon.com/fargate/pricing/
- Amazon ECS, preços: https://aws.amazon.com/ecs/pricing/
- Amazon EKS, preços: https://aws.amazon.com/eks/pricing/
- Passar segredos do Secrets Manager como variáveis de ambiente no ECS: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html
- CloudFormation, `AWS::ECS::TaskDefinition` Secret: https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-ecs-taskdefinition-secret.html
- Anúncio do ECS Express Mode (novembro de 2025): https://aws.amazon.com/about-aws/whats-new/2025/11/announcing-amazon-ecs-express-mode/
- Anúncio do blue/green nativo do ECS (julho de 2025): https://aws.amazon.com/about-aws/whats-new/2025/07/amazon-ecs-built-in-blue-green-deployments/
- Blue/green nativo no ECS, post do AWS News Blog: https://aws.amazon.com/blogs/aws/accelerate-safe-software-releases-with-new-built-in-blue-green-deployments-in-amazon-ecs
- Lifecycle hooks no blue/green do ECS: https://aws.amazon.com/blogs/containers/extending-deployment-pipelines-with-amazon-ecs-blue-green-deployments-and-lifecycle-hooks
- Documentação do Amazon ECS: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html
- Referência da API do AWS CDK, módulo `aws_ecs_patterns`: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_ecs_patterns.html
