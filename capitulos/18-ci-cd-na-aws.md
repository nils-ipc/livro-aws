# CI/CD na AWS

No capítulo 17, o Rangô trocou as instâncias por três serviços no Fargate. A imagem mora no ECR, com tags imutáveis que carregam o hash do commit, e o serviço da API tem circuit breaker com rollback. O deploy ficou curto: login no ECR, `buildx`, push e `cdk deploy RangoProducao -c versao_api=...`. Ao fim, a stack `RangoProducao` foi destruída e a `RangoRegistro`, com o repositório e as imagens, ficou.

## Sexta-feira, 18h07

O Bruno manda mensagem: a taxa de entrega da Sabor do Sertão aparece como R$ 6,90 no app, mas o combinado é R$ 4,50. O erro entrou no último commit, numa linha copiada da Cantina da Nona. Sábado é o dia de maior movimento, e cada pedido com a taxa errada é um cliente que desiste no checkout ou um reembolso para fazer na segunda.

A correção é uma linha. O deploy, quatro comandos. Só que os quatro comandos dependem de coisas que estão no seu notebook: a sessão SSO do profile `rango-dev`, o Docker com o `buildx` configurado para ARM, o Node com a CLI do CDK e o `cdk.context.json` atualizado. Você está no aniversário da sua sobrinha, a uma hora de casa.

A outra pessoa da equipe tem acesso ao repositório, mas não tem o `buildx`. Se ela conseguir configurar tudo, qual commit vai usar? O da `main`, que passou nos testes, ou o da branch dela, com a correção e mais duas mudanças pela metade? O ECR não sabe a diferença: a tag é o que a pessoa digitou.

E se a versão nova devolver erro 500 em `/restaurantes`? O `/health` não toca no banco, então o circuit breaker não percebe nada. Alguém precisa notar, descobrir a tag anterior e rodar o `cdk deploy` de novo.

O CI do capítulo 6 testa e constrói a imagem, mas joga o resultado fora junto com o runner.

## O pipeline completo

A solução é a entrega contínua do capítulo 6, levada até o fim. Um *pipeline* recebe cada commit na `main`, roda os testes, constrói a imagem uma única vez, envia para o ECR e faz o deploy dessa imagem exata. Se você quiser um ponto de controle humano, ele vira um botão de aprovação, e não um terminal aberto.

O Rangô já usa o GitHub, e o GitHub Actions já roda os testes. A AWS tem um serviço próprio de pipelines, o AWS CodePipeline, e vamos falar dele no fim do capítulo. Para um projeto que mora no GitHub, porém, o Actions resolve com menos peças. O ponto difícil é outro: como o runner do GitHub, uma máquina que não é sua e que só existe durante o job, prova para a AWS que pode fazer deploy?

### O jeito errado de autenticar

Muitos tutoriais antigos criam um usuário IAM, geram uma access key e guardam o par `AKIA...` nos *secrets* do repositório. O próprio README da action de deploy do ECS ainda mostra os parâmetros `aws-access-key-id` e `aws-secret-access-key`.

Funciona, e é o problema do capítulo 8. A chave não expira e vale para quem a tiver. Uma action de terceiros comprometida ou um `run: env` esquecido num passo de debug a vazam, e você só descobre pela fatura.

### OIDC, ou o crachá emitido na hora

O GitHub resolve isso com OIDC (*OpenID Connect*). A cada job, o GitHub pode emitir um token assinado, um JWT, que diz quem está rodando: qual repositório, qual branch, qual environment, qual evento disparou o workflow. É o mesmo tipo de token que o "Entrar com Google" entrega ao seu backend para provar a identidade de um usuário.

A AWS, por sua vez, sabe confiar em quem emite esses tokens. Você cadastra o GitHub como provedor de identidade no IAM e cria uma role cuja trust policy diz: aceito tokens emitidos por `token.actions.githubusercontent.com`, desde que tragam estas informações. O runner apresenta o token ao STS com a chamada `AssumeRoleWithWebIdentity` e recebe credenciais temporárias, as `ASIA...` do capítulo 8, que valem uma hora.

O fluxo inteiro fica assim:

```text
 Runner do GitHub                 GitHub OIDC                  AWS STS
       |                               |                           |
       |-- pede token (id-token) ----->|                           |
       |<-- JWT assinado --------------|                           |
       |     sub: repo:SEU-USUARIO/rango:environment:producao      |
       |     aud: sts.amazonaws.com                                |
       |                                                           |
       |-- AssumeRoleWithWebIdentity(role, JWT) ------------------>|
       |                     confere assinatura, aud e sub         |
       |<-- credenciais temporárias (ASIA..., 1 h) ----------------|
```

Nenhum segredo fica guardado no GitHub. Não há nada para vazar além de um token que expira em minutos e de credenciais que expiram em uma hora.

A parte que exige atenção está na trust policy. Ela precisa conferir dois campos do token. O `aud`, a audiência, tem de ser `sts.amazonaws.com`. O `sub`, o assunto, diz de onde o job veio, e o formato depende do contexto:

| Contexto do job | Valor do `sub` |
|---|---|
| push na branch `main` | `repo:SEU-USUARIO/rango:ref:refs/heads/main` |
| job com `environment: producao` | `repo:SEU-USUARIO/rango:environment:producao` |
| pull request | `repo:SEU-USUARIO/rango:pull_request` |

Se a trust policy não conferir o `sub`, qualquer repositório do GitHub, de qualquer pessoa, consegue assumir a sua role, porque o token dele é assinado pela mesma chave do GitHub que o seu.

> **Armadilha:** O GitHub passou a usar um formato novo de `sub` com IDs numéricos imutáveis, como `repo:octo-org@123456/octo-repo@456789:ref:refs/heads/main`, para repositórios criados a partir de 15 de julho de 2026 ou que fizeram opt-in. Se o seu repositório está nesse grupo, a condição com o formato antigo nunca casa, e o job falha com `Not authorized to perform sts:AssumeRoleWithWebIdentity`. Confira o formato que vale para o seu repositório na documentação do GitHub antes de escrever a condição.

## Mão na massa

O plano é este:

1. Uma stack nova, `RangoPipeline`, com o provedor OIDC e duas roles.
2. Ajustes na `RangoProducao`: permissões do front para a role do pipeline e o blue/green nativo do ECS na API.
3. Um environment `producao` no GitHub, com aprovação e restrito à `main`.
4. O workflow, que passa a fazer build, push e deploy.

Pré-requisitos: o repositório `rango-infra/` do capítulo 17, a stack `RangoRegistro` no ar, o snapshot do fim do capítulo 17 com o nome anotado no `app.py`, a CLI do GitHub (`gh`) autenticada e o profile `rango-dev`.

### Duas roles, dois crachás

Por que duas? O pipeline faz duas coisas com riscos diferentes. Enviar uma imagem ao ECR acontece a cada push na `main` e só mexe no repositório de imagens. Fazer deploy muda a produção e deve passar pela aprovação. Cada uma ganha a sua role, e cada role aceita um `sub` diferente.

Crie `rango_infra/pipeline_stack.py`:

```python
from aws_cdk import Stack, aws_ecr as ecr, aws_iam as iam
from constructs import Construct

GITHUB = "token.actions.githubusercontent.com"


class PipelineStack(Stack):
    def __init__(
        self, scope: Construct, construct_id: str, *, repositorio_github: str, **kwargs
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        provedor = iam.OpenIdConnectProvider(
            self,
            "GitHub",
            url=f"https://{GITHUB}",
            client_ids=["sts.amazonaws.com"],
        )

        def confia_em(sub: str) -> iam.IPrincipal:
            return iam.OpenIdConnectPrincipal(
                provedor,
                conditions={
                    "StringEquals": {
                        f"{GITHUB}:aud": "sts.amazonaws.com",
                        f"{GITHUB}:sub": sub,
                    }
                },
            )

        role_imagem = iam.Role(
            self,
            "RoleImagem",
            role_name="rango-github-imagem",
            assumed_by=confia_em(f"repo:{repositorio_github}:ref:refs/heads/main"),
        )
        repositorio = ecr.Repository.from_repository_name(self, "RepoApi", "rango-api")
        repositorio.grant_pull_push(role_imagem)
        repositorio.grant(role_imagem, "ecr:DescribeImages")

        role_deploy = iam.Role(
            self,
            "RoleDeploy",
            role_name="rango-github-deploy",
            assumed_by=confia_em(f"repo:{repositorio_github}:environment:producao"),
        )
        role_deploy.add_to_policy(
            iam.PolicyStatement(
                actions=["sts:AssumeRole"],
                resources=[
                    f"arn:aws:iam::{self.account}:role/cdk-hnb659fds-*-{self.account}-{self.region}"
                ],
            )
        )
        role_deploy.add_to_policy(
            iam.PolicyStatement(
                actions=["cloudformation:DescribeStacks"],
                resources=[
                    f"arn:aws:cloudformation:{self.region}:{self.account}:stack/RangoProducao/*"
                ],
            )
        )
        role_deploy.add_to_policy(
            iam.PolicyStatement(
                actions=["ecs:UpdateService"],
                resources=[
                    f"arn:aws:ecs:{self.region}:{self.account}:service/rango-producao/*"
                ],
            )
        )
```

O `OpenIdConnectProvider` cadastra o GitHub no IAM; existe um por URL em cada conta. O `OpenIdConnectPrincipal` monta a trust policy com a ação `sts:AssumeRoleWithWebIdentity` e as duas condições com `StringEquals`. Você vai ver exemplos com `StringLike` e `repo:ORG/REPO:*`. O asterisco aceita qualquer branch, pull request ou environment do repositório, inclusive a branch que alguém criou ontem para testar uma ideia.

A `role_imagem` recebe o login no ECR, o envio de camadas e manifestos ao `rango-api` e o `DescribeImages`, que o workflow usa para saber se uma tag já existe.

A `role_deploy` pede mais cuidado, porque o `cdk deploy` cria VPC, banco e roles IAM. Muitos guias dão `AdministratorAccess` à role do GitHub. O caminho mais estreito usa as roles que o bootstrap do capítulo 15 criou, com o qualificador padrão `hnb659fds` no nome: `cdk-hnb659fds-deploy-role-...`, `...-file-publishing-role-...`, `...-image-publishing-role-...` e `...-lookup-role-...`. A CLI do CDK assume essas roles sozinha; a role do GitHub só precisa de permissão para assumi-las.

Isso desloca o risco em vez de eliminá-lo. A role de execução do bootstrap continua administradora, como o capítulo 15 avisou. A proteção está em quem assume a `role_deploy`: só um job no environment `producao`, a partir da `main`, depois de uma aprovação. O capítulo 23 volta a isso com contas separadas.

As duas últimas permissões atendem passos fora do CDK: ler as saídas da stack e forçar deploys no cluster `rango-producao`.

No `app.py`, a stack nova entra ao lado das outras:

```python
from rango_infra.pipeline_stack import PipelineStack

PipelineStack(app, "RangoPipeline", repositorio_github="SEU-USUARIO/rango", env=env)
```

Troque `SEU-USUARIO` pelo dono do repositório, respeitando maiúsculas e minúsculas, e faça o deploy a partir do notebook:

```bash
cdk deploy RangoPipeline -c versao_api=nenhuma
```

O `-c versao_api=nenhuma` existe porque o CDK sintetiza o app inteiro, e a `RangoProducao` precisa de algum valor para a tag, mesmo sem ser implantada. Este é o último deploy que sai do seu terminal, e só podia ser este: a role que autoriza o pipeline não pode ser criada pelo próprio pipeline.

### A produção abre a porta do front

O conteúdo do front fica fora da stack desde o capítulo 15. Quem vai enviá-lo agora é a `role_deploy`, que precisa escrever no bucket e invalidar a distribuição. As duas coisas estão na `RangoProducao`, e o nome do bucket é gerado pelo CDK, então a permissão nasce lá. Em `rango_infra/rango_infra_stack.py`, depois da distribuição:

```python
        role_pipeline = iam.Role.from_role_name(self, "RolePipeline", "rango-github-deploy")
        front.grant_read(role_pipeline)
        front.grant_put(role_pipeline)
        distribuicao.grant_create_invalidation(role_pipeline)
```

Os `grant_*` criam uma policy dentro da `RangoProducao` e a anexam à role importada; quando a stack for destruída, a policy vai junto. O `grant_read` traz o `s3:ListBucket`, de que o `aws s3 sync` precisa. Nenhum `grant` permite apagar, já que o deploy do front nunca usa `--delete` (capítulo 14).

É nesses passos fora do CDK que os pipelines quebram com `AccessDenied`: o `cdk deploy` passa, com as roles do bootstrap, e o `aws s3 sync` seguinte falha, porque roda com a role do GitHub.

### Blue/green na API

O deploy *rolling* do capítulo 17 tem um circuit breaker que volta atrás quando as tasks novas não ficam de pé. Quando elas ficam de pé e respondem errado, que é a história da sexta-feira, ele não faz nada.

O ECS tem quatro estratégias de deploy: rolling (o padrão), blue/green, canary e linear, estas duas desde outubro de 2025. No blue/green, a versão atual (azul) continua atendendo enquanto a nova (verde) sobe inteira num segundo target group. O ALB tem uma regra de produção e uma de teste. A de teste manda tráfego ao verde primeiro, para você conferir antes de qualquer cliente. Depois o ECS vira a regra de produção para o verde de uma vez, e começa o *bake time*: azul e verde rodam juntos por um período configurável. Se um alarme do CloudWatch disparar nessa janela, o tráfego volta ao azul, que ainda está de pé, no tempo de trocar o peso de uma regra.

O deploy passa por estágios que aparecem no console, como `TEST_TRAFFIC_SHIFT` e `PRODUCTION_TRAFFIC_SHIFT`. Em vários deles cabe um *lifecycle hook*: uma função Lambda que decide se o deploy continua, ou uma pausa que espera alguém chamar `ContinueServiceDeployment`. Um hook no `POST_TEST_TRAFFIC_SHIFT` com testes de fumaça é o próximo passo natural; para o Rangô, o alarme basta por enquanto. O custo do bake time é dobrar as tasks durante a janela, frações de centavo por deploy.

O `ApplicationLoadBalancedFargateService` do capítulo 17 cria um target group só. Para ter dois, e regras de listener, a API sai do pattern. Apague o bloco `api = ecs_patterns...` com o health check e a escala que vinham depois, e o import de `aws_ecs_patterns`. Acrescente `aws_cloudwatch as cloudwatch`. Primeiro, o ALB e as regras:

```python
        alb = elbv2.ApplicationLoadBalancer(
            self,
            "AlbApi",
            vpc=vpc,
            internet_facing=True,
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PUBLIC),
        )
        alb.add_redirect()
        https = alb.add_listener(
            "Https",
            port=443,
            certificates=[certificado],
            ssl_policy=elbv2.SslPolicy.RECOMMENDED_TLS,
            default_action=elbv2.ListenerAction.fixed_response(404),
        )
        sg_api.connections.allow_from(alb, ec2.Port.tcp(8000), "ALB para a API")

        def grupo_alvo(nome: str) -> elbv2.ApplicationTargetGroup:
            return elbv2.ApplicationTargetGroup(
                self,
                nome,
                vpc=vpc,
                port=8000,
                protocol=elbv2.ApplicationProtocol.HTTP,
                target_type=elbv2.TargetType.IP,
                deregistration_delay=Duration.seconds(30),
                health_check=elbv2.HealthCheck(
                    path="/health",
                    interval=Duration.seconds(10),
                    healthy_threshold_count=2,
                    unhealthy_threshold_count=2,
                ),
            )

        azul = grupo_alvo("GrupoAzul")
        verde = grupo_alvo("GrupoVerde")

        def regra(nome: str, prioridade: int, condicoes) -> elbv2.ApplicationListenerRule:
            return elbv2.ApplicationListenerRule(
                self,
                nome,
                listener=https,
                priority=prioridade,
                conditions=condicoes,
                action=elbv2.ListenerAction.weighted_forward(
                    [
                        elbv2.WeightedTargetGroup(target_group=azul, weight=100),
                        elbv2.WeightedTargetGroup(target_group=verde, weight=0),
                    ]
                ),
            )

        regra_teste = regra(
            "RegraTeste", 10, [elbv2.ListenerCondition.http_header("X-Rango-Teste", ["verde"])]
        )
        regra_producao = regra(
            "RegraProducao", 20, [elbv2.ListenerCondition.path_patterns(["/*"])]
        )
```

Os target groups repetem o health check do capítulo 13, e o `add_redirect` recria o redirecionamento da porta 80. As regras são avaliadas da menor prioridade para a maior: com o cabeçalho `X-Rango-Teste: verde`, a requisição cai na regra de teste; o resto cai na de produção. As duas começam com 100% no azul, e o ECS muda os pesos durante o deploy.

A regra de teste fica no listener público, e quem descobrir o cabeçalho alcança a versão verde durante um deploy. Como ela é o próximo código de produção, isso expõe pouco; rotas que ainda não podem ser vistas pedem uma feature flag (capítulo 6).

Agora o alarme que decide a volta, a task definition e o serviço:

```python
        erros_5xx = cloudwatch.Alarm(
            self,
            "ErrosApi",
            metric=alb.metrics.http_code_target(
                elbv2.HttpCodeTarget.TARGET_5XX_COUNT,
                period=Duration.minutes(1),
                statistic="Sum",
            ),
            threshold=10,
            evaluation_periods=1,
            comparison_operator=cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
            treat_missing_data=cloudwatch.TreatMissingData.NOT_BREACHING,
        )

        tarefa_api = ecs.FargateTaskDefinition(
            self,
            "TarefaApi",
            cpu=512,
            memory_limit_mib=1024,
            runtime_platform=plataforma,
            task_role=role_app,
        )
        tarefa_api.add_container(
            "api",
            image=imagem,
            secrets=variaveis,
            port_mappings=[ecs.PortMapping(container_port=8000)],
            logging=ecs.LogDrivers.aws_logs(stream_prefix="api", log_group=logs_app),
        )

        api = ecs.FargateService(
            self,
            "ServicoApi",
            cluster=cluster,
            task_definition=tarefa_api,
            desired_count=2,
            vpc_subnets=privadas,
            security_groups=[sg_api],
            deployment_strategy=ecs.DeploymentStrategy.BLUE_GREEN,
            bake_time=Duration.minutes(10),
            circuit_breaker=ecs.DeploymentCircuitBreaker(rollback=True),
            deployment_alarms=ecs.DeploymentAlarmConfig(
                alarm_names=[erros_5xx.alarm_name],
                behavior=ecs.AlarmBehavior.ROLLBACK_ON_ALARM,
            ),
        )
        api.load_balancer_target(
            container_name="api",
            container_port=8000,
            alternate_target=ecs.AlternateTarget(
                "Verde",
                alternate_target_group=verde,
                production_listener=ecs.ListenerRuleConfiguration.application_listener_rule(
                    regra_producao
                ),
                test_listener=ecs.ListenerRuleConfiguration.application_listener_rule(
                    regra_teste
                ),
            ),
        ).attach_to_application_target_group(azul)

        escala = api.auto_scale_task_count(min_capacity=2, max_capacity=6)
        escala.scale_on_cpu_utilization("Cpu", target_utilization_percent=60)
        api.node.add_dependency(rotacao, *endpoints)
```

O alarme dispara com dez ou mais respostas 5xx das tasks num minuto. O `NOT_BREACHING` trata minuto sem dados como normal, porque minuto sem erro não gera ponto na métrica. O número 10 é um ponto de partida; o capítulo 22 troca contagens por taxas e SLOs. O `deployment_alarms` faz o ECS observar o alarme durante o deploy e o bake time, e o `ROLLBACK_ON_ALARM` devolve o tráfego ao azul. O circuit breaker fica para a task que nem sobe.

O `load_balancer_target` com o `AlternateTarget` registra as tasks no azul e entrega ao ECS o verde e as duas regras. Para mexer nelas, o ECS usa uma role de infraestrutura com a policy gerenciada `AmazonECSInfrastructureRolePolicyForLoadBalancers`, que o CDK cria sozinho.

A escala mudou de métrica. Com blue/green, o target group ativo se alterna a cada deploy, e uma política de requisições presa ao azul veria zero depois do primeiro deploy. A CPU média do serviço não depende do grupo ativo.

Por fim, o registro `api.rango.com.br` volta a ser explícito, como no capítulo 15, e a saída `ServicoApiNome` passa a usar `api.service_name`:

```python
        route53.ARecord(
            self,
            "ApiA",
            zone=zona,
            record_name="api",
            target=route53.RecordTarget.from_alias(targets.LoadBalancerTarget(alb)),
        )
```

Os workers continuam com o deploy rolling. Eles não recebem tráfego HTTP, então não há o que testar antes nem para onde devolver.

Antes do commit, rode um `cdk synth` local para que o lookup da zona volte ao `cdk.context.json`, apagado no fim do capítulo 17, e faça commit desse arquivo. Sem ele, o pipeline usa a lookup role do bootstrap a cada execução. Funciona, mas o template passa a depender do que a conta responde naquele momento.

### O environment no GitHub

O `sub` da role de deploy fala de um environment chamado `producao`. No GitHub, um *environment* é um alvo de deploy com regras próprias. Crie o seu em Settings → Environments → New environment, com o nome `producao`, e configure duas regras:

- **Required reviewers**: o seu usuário. O job que usar esse environment para e espera alguém aprovar.
- **Deployment branches and tags**: "Selected branches and tags", com a regra `main`.

A segunda regra é a que fecha a porta. O `sub` diz qual environment o job declarou, e não qual branch o disparou. Sem a restrição, alguém com permissão de push cria uma branch, escreve um workflow com `environment: producao` e recebe as credenciais de deploy. Com a restrição, o GitHub recusa o job antes de emitir o token.

> **Armadilha:** Em repositórios privados, as regras de proteção de environment dependem do plano do GitHub. Confira se as suas aparecem na tela antes de contar com elas, porque o `sub` com environment sem a regra de branch é quase tão frouxo quanto um curinga.

Guarde também o ID da conta numa variável do repositório. Ele dispensa sigilo, e assim o ARN das roles não fica repetido no workflow:

```bash
gh variable set AWS_ACCOUNT_ID --body "123456789012"
```

### O workflow

O `.github/workflows/ci.yaml` do capítulo 6 tinha dois jobs: `testes` e `imagem`. O primeiro continua igual. O segundo passa a enviar a imagem, e entra um terceiro, `deploy`:

```yaml
# .github/workflows/ci.yaml
name: ci

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:
    inputs:
      versao:
        description: "Hash completo de um commit cuja imagem já está no ECR"
        required: true

permissions:
  contents: read

env:
  VERSAO: ${{ inputs.versao || github.sha }}
  AWS_REGION: us-east-1

jobs:
  testes:
    # igual ao capítulo 6

  imagem:
    needs: testes
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-24.04-arm
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@v5
      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/rango-github-imagem
          role-session-name: imagem-${{ github.run_id }}
          aws-region: ${{ env.AWS_REGION }}
      - id: ecr
        uses: aws-actions/amazon-ecr-login@v2
      - name: Build e push, se a tag ainda não existe
        env:
          REPO: ${{ steps.ecr.outputs.registry }}/rango-api
        run: |
          if aws ecr describe-images --repository-name rango-api \
               --image-ids imageTag="$VERSAO" > /dev/null 2>&1; then
            echo "A imagem $VERSAO já está no ECR"
            exit 0
          fi
          docker build -t "$REPO:$VERSAO" backend
          docker push "$REPO:$VERSAO"

  deploy:
    needs: imagem
    runs-on: ubuntu-24.04
    environment: producao
    concurrency: producao
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-python@v6
        with:
          python-version: "3.12"
      - uses: actions/setup-node@v5
        with:
          node-version: 22
      - run: npm install -g aws-cdk@2
      - run: pip install -r rango-infra/requirements.txt
      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/rango-github-deploy
          role-session-name: deploy-${{ github.run_id }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Infraestrutura e API
        working-directory: rango-infra
        run: |
          cdk deploy RangoRegistro RangoProducao \
            --require-approval never -c versao_api="$VERSAO"

      - name: Front
        if: github.event_name == 'push'
        working-directory: frontend
        run: |
          saida() {
            aws cloudformation describe-stacks --stack-name RangoProducao \
              --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
          }
          npm ci
          npm run build
          FRONT=$(saida FrontBucket)
          aws s3 sync dist/ "s3://$FRONT/" \
            --exclude index.html \
            --cache-control "public, max-age=31536000, immutable"
          aws s3 cp dist/index.html "s3://$FRONT/index.html" \
            --cache-control "no-cache"
          aws cloudfront create-invalidation \
            --distribution-id "$(saida DistribuicaoId)" --paths "/index.html"
```

Vamos por partes, porque cada linha tem um motivo.

O `id-token: write` autoriza o job a pedir o JWT ao GitHub e nada mais; quem decide o acesso é a trust policy. O job `testes` não pede essa permissão, então um teste comprometido nem consegue tentar.

O `VERSAO` é o hash completo do commit, que o capítulo 6 já usava como tag; as imagens de hash curto do capítulo 17 convivem com ele. Num disparo manual, o `inputs.versao` toma o lugar do hash, e isso vai servir para voltar versões.

O job `imagem` roda no runner `ubuntu-24.04-arm`, disponível em repositórios privados desde janeiro de 2026, com duas vCPUs e consumindo os minutos do plano. Na máquina arm64, um `docker build` comum gera a imagem do Graviton, sem `buildx` nem emulação. A checagem antes do build existe por causa das tags imutáveis: num re-run do mesmo commit, o push falharia com `ImageTagAlreadyExistsException`, e a imagem que já está lá é, por definição, a mesma.

O `environment: producao` muda o `sub` do token e faz o GitHub pedir aprovação. O `concurrency: producao` enfileira deploys: se chega um terceiro commit, o GitHub descarta o que esperava e fica com o mais novo.

A `configure-aws-credentials` está na versão 6, que roda em Node 24; exemplos com `@v1`, `@v2` ou `@v4` estão defasados, e runners próprios precisam do agente 2.327.1 ou mais novo. Ela pede o token, chama o STS e exporta as credenciais como variáveis de ambiente, onde a CLI e o CDK as encontram.

O `cdk deploy` recebe as stacks pelo nome em vez de `--all`, que incluiria a `RangoPipeline`: um commit que ampliasse a `role_deploy` seria aplicado pela própria `role_deploy`. O `--require-approval never` desliga a pergunta sobre mudanças de IAM, que travaria o job; a aprovação humana já aconteceu no environment.

O passo do front é o do capítulo 14 com as saídas da stack, e só roda em push, para que voltar a API não mexa no front. As primeiras 1.000 invalidações de caminho por mês são gratuitas, somando todas as distribuições da conta, e `/*` conta como um caminho (us-east-1, outubro de 2026; confira a página de preços). Um caminho por deploy fica longe disso.

> **Dica:** Os exemplos acima usam tags como `@v6` para facilitar a leitura. A documentação do GitHub sobre OIDC na AWS fixa as actions pelo hash do commit (`uses: aws-actions/configure-aws-credentials@<hash de 40 caracteres>`), e você deve fazer o mesmo, inclusive no `ci.yaml` do capítulo 6. Uma tag pode ser movida para outro commit por quem controla o repositório da action; um hash não. O Dependabot sabe atualizar actions fixadas por hash e abre pull requests quando sai versão nova.

### Por que não as actions de deploy do ECS?

A AWS mantém duas actions para o ECS: `amazon-ecs-render-task-definition`, que troca a imagem num JSON de task definition, e `amazon-ecs-deploy-task-definition`, hoje na versão 2, que registra a revisão nova e atualiza o serviço. Ela aceita `task-definition`, `service`, `cluster` e `wait-for-service-stability: true`, e o README mostra o fluxo completo: credenciais, login no ECR, build e push com a tag `${{ github.sha }}`, render e deploy.

É um bom caminho quando infraestrutura e aplicação têm donos separados. No Rangô, a task definition pertence ao CDK. Revisões registradas por fora seriam o drift do capítulo 15: no próximo `cdk deploy`, a tag antiga voltaria para produção sem ninguém pedir.

### O primeiro deploy pelo pipeline

Faça commit de tudo (a stack nova, as mudanças na produção, o `cdk.context.json` e o workflow) e envie para a `main`. Em vez de abrir a aba Actions, acompanhe pelo terminal:

```bash
gh run watch
```

Os testes passam, a imagem é construída e enviada, e o job `deploy` para com o status "Waiting". O GitHub manda um e-mail pedindo a revisão. Aprove pela página do run ou pela linha de comando:

```bash
gh run view --web
```

Este primeiro deploy cria a produção do zero, com o banco restaurado do snapshot, e leva os 15 a 20 minutos de sempre. Repare no que aparece no log do passo de infraestrutura: as credenciais usadas são da role `rango-github-deploy`, e a CLI do CDK anuncia que vai assumir a `cdk-hnb659fds-deploy-role`.

Como no capítulo 17, a primeira rotação do segredo corre em paralelo com a subida das tasks. Espere ela terminar e force tasks novas, agora com a permissão que a `role_deploy` tem no cluster. Isso nos leva à pendência do capítulo 17: a task que vive mais que duas rotações perde o acesso ao banco, e o `--force-new-deployment` semanal precisava de alguém para lembrar. Um segundo workflow, `.github/workflows/renovar-tasks.yaml`, lembra por você:

```yaml
# .github/workflows/renovar-tasks.yaml
name: renovar-tasks

on:
  schedule:
    - cron: "0 9 * * 1"
  workflow_dispatch:

permissions:
  contents: read
  id-token: write

jobs:
  renovar:
    runs-on: ubuntu-24.04
    environment: producao
    concurrency: producao
    steps:
      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/rango-github-deploy
          role-session-name: renovar-${{ github.run_id }}
          aws-region: us-east-1
      - run: |
          for servico in $(aws ecs list-services --cluster rango-producao \
                             --query "serviceArns[]" --output text); do
            aws ecs update-service --cluster rango-producao --service "$servico" \
              --force-new-deployment > /dev/null
            echo "Deploy forçado: $servico"
          done
```

Toda segunda-feira às 9h em UTC (6h em Brasília), as tasks são trocadas e leem o segredo atual. Acrescente à `role_deploy` um statement com `ecs:ListServices` e `resources=["*"]`, e refaça o deploy manual da `RangoPipeline`. Este job também pede aprovação; se incomodar, dê a ele um environment e uma role próprios, só com essas duas ações.

### A correção do Bruno, pelo celular

Volte à sexta-feira. A correção da taxa vai num pull request:

```bash
git switch -c corrige-taxa-sertao
# edite a taxa da Sabor do Sertão em backend/app/main.py
git commit -am "Corrige taxa de entrega da Sabor do Sertao"
git push -u origin corrige-taxa-sertao
gh pr create --fill
```

O job `testes` roda no pull request. Os jobs `imagem` e `deploy` aparecem como ignorados, por causa do `if` e do `needs`. A outra pessoa da equipe revisa, aprova e faz o merge pelo navegador. O push na `main` dispara o pipeline. Você recebe o e-mail de aprovação antes do bolo, abre o link no celular e aprova.

Enquanto o deploy roda, a regra de teste já mostra a versão verde. Qualquer um com o `curl` pode conferir antes da troca:

```bash
curl -s -H "X-Rango-Teste: verde" https://api.rango.com.br/restaurantes \
  | python3 -m json.tool | grep -A1 Sertao
```

Depois da troca, o estado do deploy aparece no ECS:

```bash
aws ecs list-service-deployments --cluster rango-producao \
  --service "$(saida ServicoApiNome)" \
  --query "serviceDeployments[0].[status,targetServiceRevisionArn]"
```

Durante os dez minutos de bake time, o status fica `IN_PROGRESS` e o serviço tem quatro tasks. Depois, as azuis são drenadas, o status vira `SUCCESSFUL` e o `cdk deploy` termina. O job inteiro leva uns 15 minutos, a maior parte esperando o bake time. Ninguém abriu um terminal.

### Quando a versão nova quebra

Agora o teste que interessa: uma versão que sobe, passa no `/health` e devolve erro. Numa branch de teste, troque o nome de uma coluna na consulta de `/restaurantes`, para que o Postgres responda `column "taxa_entrga" does not exist`. Faça o merge e aprove o deploy.

Durante o bake time, gere tráfego. O script do k6 do capítulo 13 serve, ou um laço simples:

```bash
for i in $(seq 1 300); do
  curl -s -o /dev/null -w "%{http_code}\n" https://api.rango.com.br/restaurantes
  sleep 0.5
done | sort | uniq -c
```

```text
    169 200
    131 500
```

Em um ou dois minutos, o alarme `ErrosApi` passa para `ALARM`. O ECS devolve a regra de produção ao azul, e os 500 param. Os sucessos do resultado são as respostas que chegaram depois da volta, já servidas pelas tasks azuis. O deploy termina como `ROLLBACK_SUCCESSFUL`, o CloudFormation reverte a stack para a revisão anterior da task definition, o `cdk deploy` sai com erro e o run fica vermelho no GitHub.

O vermelho é o aviso. Na versão do capítulo 17, ninguém teria percebido até um cliente reclamar.

Para os casos que o alarme não pega, voltar uma versão é rodar o mesmo pipeline com uma tag antiga:

```bash
gh workflow run ci -f versao=3f9c2b1e8d7a6c5b4a39281706f5e4d3c2b1a098
```

Os testes rodam sobre a `main`, o job `imagem` encontra a tag no ECR e não constrói nada, e o `deploy` aplica a infraestrutura atual com a imagem antiga, em blue/green, depois da aprovação. O hash vem do histórico de runs ou do `git log`. As 30 imagens que o lifecycle do ECR guarda são as suas versões disponíveis para voltar.

Voltar a imagem não desfaz uma migration de banco. Se a versão nova renomeou uma coluna, a antiga vai procurar a coluna com o nome antigo e falhar. É por isso que o capítulo 6 insistiu no expand/contract: cada deploy precisa funcionar com o esquema do deploy anterior e do seguinte.

### Desligar sem deixar o pipeline religar

Destrua a produção a partir do notebook, como nos capítulos anteriores:

```bash
cdk destroy RangoProducao -c versao_api=nenhuma
```

O banco sai com snapshot final; atualize o nome no `app.py` e faça commit quando for subir de novo. A `RangoRegistro` e a `RangoPipeline` ficam. O provedor OIDC e as roles não custam nada.

Há um detalhe novo. Com a produção destruída, qualquer push na `main` recria tudo, com banco e NAT de endpoints cobrando por hora. Desligue os workflows enquanto estiver estudando outra coisa:

```bash
gh workflow disable ci
gh workflow disable renovar-tasks
```

E religue com `gh workflow enable` quando quiser a produção de volta.

## E o CodePipeline?

O AWS CodePipeline é o orquestrador de pipelines da AWS. Ele encadeia estágios (origem, build, aprovação, deploy) e delega o trabalho a outros serviços: o AWS CodeBuild roda os comandos, como o runner do GitHub, e o deploy pode ir direto para o ECS, para o CloudFormation ou para um bucket. O código pode vir do GitHub, por meio de uma conexão autorizada uma vez no console.

Ele tem dois tipos de pipeline com cobranças diferentes (us-east-1, outubro de 2026; confira a página oficial). O V1 custa US$ 1,00 por mês por pipeline ativo, sendo ativo o pipeline com mais de 30 dias e pelo menos uma mudança no mês; o primeiro é gratuito no free tier. O V2 cobra US$ 0,002 por minuto de execução de ação, arredondado para cima, com 100 minutos gratuitos por mês, e a aprovação manual não conta. Nos dois, CodeBuild, S3 e outros serviços usados são cobrados à parte.

A vantagem é ficar tudo na AWS: só roles IAM, sem provedor OIDC, e o CodeBuild pode rodar dentro da VPC, alcançando um banco privado para testes de integração. O CDK tem um construct para isso, o CDK Pipelines, em que o pipeline se atualiza quando a definição dele muda. Para o Rangô, com pull requests e revisões no GitHub, seria um segundo lugar para olhar quando algo der errado.

## Armadilhas e casos reais

> **Armadilha:** Trust policy sem `sub`, ou com curinga. É o erro mais grave deste capítulo, porque não dá sinal nenhum: tudo funciona, e qualquer repositório do GitHub consegue assumir a role. Revise a trust policy de cada role federada com o mesmo cuidado de uma bucket policy pública. O IAM Access Analyzer aponta roles que podem ser assumidas de fora da conta.

> **Armadilha:** Dois provedores para a mesma URL. Só existe um provedor OIDC por URL em cada conta. Se alguém já criou o do GitHub pelo console, seguindo um tutorial, o deploy da `RangoPipeline` falha com `EntityAlreadyExists`. Apague o provedor antigo, se nenhuma role depender dele, ou importe-o com `iam.OpenIdConnectProvider.from_open_id_connect_provider_arn`.

> **Armadilha:** `cdk deploy` sem a versão. Sem o `-c versao_api`, a tag chega como `None` e o `from_ecr_repository` usa `latest`, que não existe num repositório de tags imutáveis enviado só com hashes. As tasks novas não conseguem baixar a imagem, o circuit breaker volta atrás e você perde 15 minutos para descobrir o motivo. Por isso os comandos manuais deste capítulo passam um valor qualquer; nenhum deles faz deploy da `RangoProducao`.

> **Armadilha:** Mexer nas regras do ALB no CDK depois do primeiro deploy. O ECS altera os pesos das regras a cada deploy, e depois de um número ímpar de deploys o tráfego está no verde. O CloudFormation não sabe disso. Se você mudar a definição de uma regra no código, o update reescreve os pesos com os valores do template, 100 para o azul, e o tráfego vai para um target group que pode estar vazio. Se precisar mudar uma regra, faça isso numa janela em que possa conferir o resultado com o `curl` logo em seguida.

> **Armadilha:** O bake time ocupa o runner. O `cdk deploy` só termina depois dele, e em repositórios privados são minutos do plano. Com deploys muito frequentes, reduza o bake time ou use a estratégia linear, com degraus de 3% a 100% e espera de 0 a 1.440 minutos entre eles.

> **Na vida real:** Em março de 2025, a action `tj-actions/changed-files`, usada por milhares de repositórios, foi comprometida. Os atacantes apontaram as tags existentes, inclusive as de versão, para um commit malicioso que imprimia os segredos do runner no log do workflow. Em repositórios públicos, esses logs podiam ser lidos por qualquer pessoa. Quem fixava a action por hash de commit não foi afetado, e quem autenticava na AWS por OIDC não tinha access key para perder: o token vazado expirava em minutos. Foi registrada como CVE-2025-30066.

> **Na vida real:** O deploy agora depende do GitHub Actions estar no ar. Mantenha documentado o caminho manual do capítulo 17, com o profile `rango-admin`, para emergências, e trate cada uso dele como incidente com postmortem.

## Resumo

- O GitHub Actions autentica na AWS por OIDC: o job pede um JWT, o STS confere assinatura, `aud` e `sub`, e devolve credenciais temporárias. Nenhuma access key fica guardada.
- A trust policy precisa sempre do `sub` com valor exato. Um environment no GitHub só protege com a regra de branch e a aprovação configuradas.
- O Rangô tem duas roles: `rango-github-imagem` (push na `main`, só o repositório `rango-api`) e `rango-github-deploy` (environment `producao`, assume as roles do bootstrap do CDK, lê saídas da stack, força deploys).
- O workflow testa, constrói a imagem uma vez num runner ARM, envia ao ECR com o hash completo do commit, roda `cdk deploy` com esse hash e envia o front com invalidação só do `/index.html`.
- A task definition continua com o CDK. Atualizar o serviço por fora causaria drift.
- A API usa o blue/green nativo do ECS: regra de teste por cabeçalho, troca de uma vez, bake time de dez minutos e rollback por alarme de 5xx. Os workers seguem com rolling.
- Voltar uma versão é rodar o workflow com uma tag antiga. Migrations precisam de expand/contract.
- O CodePipeline faz o mesmo de dentro da AWS e vale a pena quando o código ou as regras da empresa já estão lá.

## Três vezes por dia

Com o pipeline no ar, o Bruno pega gosto por pedir coisas. A próxima: um resumo de vendas para cada restaurante, enviado às 11h, às 15h e às 23h, com os pedidos do período, o ticket médio e os pratos mais pedidos. A lógica é uma consulta ao Postgres e um e-mail, coisa de quarenta linhas de Python.

Onde ela roda? O caminho mais curto com o que você tem é um terceiro worker no ECS, com um laço que dorme até a próxima hora cheia. Uma task de 0,25 vCPU ligada o mês inteiro para trabalhar uns poucos minutos por dia. O Rangô passaria a pagar 24 horas por dia por uma rotina que roda três vezes por dia, e o mesmo raciocínio vale para os próximos pedidos do Bruno: o relatório semanal, a limpeza de carrinhos abandonados, o webhook do gateway de pagamento que chega uma vez por pedido.

No próximo capítulo, o AWS Lambda roda código só quando algo acontece e cobra pelos milissegundos de execução. O capítulo mostra como ele executa uma função por dentro, o que é o cold start que o capítulo 4 apresentou, os limites que surpreendem, e quando o API Gateway na frente dele substitui um servidor inteiro. E também quando nada disso compensa.

## Referências

- GitHub, configurar OIDC na AWS (provedor, `aud`, formatos de `sub`, `id-token: write`, actions fixadas por hash): https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws
- Releases da action `configure-aws-credentials`: https://github.com/aws-actions/configure-aws-credentials/releases
- Action `amazon-ecs-deploy-task-definition`: https://github.com/aws-actions/amazon-ecs-deploy-task-definition
- Blue/green nativo no Amazon ECS (bake time, lifecycle hooks, rollback): https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-blue-green.html
- Estágios do deploy e lifecycle hooks, referência da API do ECS: https://docs.aws.eu/AmazonECS/latest/APIReference/API_DeploymentLifecycleHook.html
- Deploy linear no ECS: https://docs.aws.eu/AmazonECS/latest/developerguide/deployment-type-linear.html
- Anúncio dos deploys linear e canary no ECS (outubro de 2025): https://aws.amazon.com/about-aws/whats-new/2025/10/amazon-ecs-built-in-linear-canary-deployments
- AWS CDK, classe `AlternateTarget` do `aws_ecs`: https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_ecs.AlternateTarget.html
- AWS CDK, `DeploymentStrategy` em Python: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_ecs/DeploymentStrategy.html
- CloudFront, cobrança de invalidações: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/PayingForInvalidation.html
- Preços do AWS CodePipeline: https://aws.amazon.com/codepipeline/pricing
- `cdk deploy` no GitHub Actions com OIDC e roles do bootstrap (Classmethod): https://dev.classmethod.jp/articles/github-actions-oidc-aws-cdk-deploy/
- Permissões para passos fora do CDK no pipeline (DEV Community): https://dev.to/simonireilly/secure-aws-cdk-deployments-with-github-actions-3jfk
- Runners ARM padrão em repositórios privados (changelog do GitHub, janeiro de 2026): https://github.blog/changelog/2026-01-29-arm64-standard-runners-are-now-available-in-private-repositories
- Comprometimento da action `tj-actions/changed-files`, CVE-2025-30066: https://github.com/advisories/GHSA-mrrh-fwg8-r2c3
