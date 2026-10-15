# Segurança em produção

No capítulo anterior, o Rangô ganhou olhos: logs em JSON com o mesmo vocabulário em todos os grupos, alarmes nas DLQs e na taxa de erro, um dashboard, traces com OpenTelemetry e um SLO para a confirmação do pedido. Foi esse painel que mostrou, numa segunda-feira de manhã, duas coisas que a observabilidade da aplicação sozinha não explica: um robô testando senhas e uma fila que sumiu. Os logs contam o que o Rangô fez. Agora precisamos saber o que fizeram com a conta.

## Segunda-feira, 16 de novembro, 8h40

Vamos retomar a cena com os detalhes. A rota que recebeu as 41 mil respostas 401 é a `POST /painel/entrar`, o login do painel que o capítulo 20 criou para a Cantina da Nona e o Sabor do Sertão acompanharem as entregas. As tentativas começaram às 3h17 e vieram de seis endereços na faixa `203.0.113.0/24`, cada um com um ritmo constante de umas 57 requisições por minuto. Ninguém usa um login assim. É um programa percorrendo uma lista de e-mails e senhas vazados de outros sites, apostando que algum dono de restaurante repetiu a senha.

Nada impediu o robô. O ALB entregou cada requisição, a API consultou a tabela do painel e calculou um hash Argon2 41 mil vezes, e uma única senha certa abriria o painel de um restaurante, com os pedidos em andamento e a posição de cada entregador na rua.

A fila incomoda mais. O alarme da DLQ de SMS não tocou, porque a DLQ continuava vazia: a fila principal deixou de existir às 7h02, com as mensagens dentro. O `cdk drift` acusa o recurso como `DELETED`, e o `cdk deploy` de rotina não traz de volta, como o capítulo 15 avisou.

Três perguntas ficam na mesa. Quem apagou a fila, de onde e com que credencial? Como parar o robô antes que ele chegue à API? E por que uma pessoa da equipe conseguiu apagar um recurso de produção?

A terceira pergunta é a mais desconfortável. Desde o capítulo 8, o Rangô inteiro mora numa conta só, a `rango-estudos`, que também é a conta de gerenciamento da organização. A homologação, a segunda instância da `RangoInfraStack` que o capítulo 15 previu, a equipe sobe ali mesmo quando precisa testar algo; você, leitor, vinha destruindo só a produção no fim de cada capítulo. Homologação e produção dividem a conta, e o grupo `rango-devs` tem `PowerUserAccess` em tudo. O capítulo 16 já tinha avisado que esse permission set lê os segredos de produção. Estava funcionando por sorte.

## CloudTrail: o registro de quem chamou a API

Toda ação na AWS é uma chamada de API. Clicar em "Delete" no console, rodar `aws sqs delete-queue`, um `cdk destroy`, um `boto3` dentro de uma Lambda: tudo vira uma requisição assinada para um endpoint. O **AWS CloudTrail** registra essas chamadas. Cada registro é um **evento** com quem chamou (a identidade, a role, a sessão), quando, de qual IP, com qual programa, quais parâmetros foram enviados e se a AWS aceitou ou recusou.

Pense no `git log` da conta, gravado pela própria AWS: o autor de cada linha é a credencial que assinou a chamada.

Os **eventos de gerenciamento** são as operações sobre os recursos: criar uma fila, apagar uma tabela, assumir uma role. Ficam registrados por padrão e sem custo. Os **eventos de dados** são as operações dentro dos recursos, como um `GetObject` no bucket de fotos ou um `PutItem` no DynamoDB. São muito mais numerosos, ficam desligados por padrão e são cobrados à parte, assim como o **Insights**, que procura picos anormais de chamadas.

Os eventos de gerenciamento aparecem no **Event History** pelos últimos 90 dias, por região. Para guardar por mais tempo, num lugar de onde ninguém consiga apagá-los, você cria uma **trail**, que entrega cópias dos eventos em arquivos num bucket S3. A primeira cópia dos eventos de gerenciamento não tem custo do CloudTrail; você paga só o S3. O CloudTrail Lake, que guarda eventos consultáveis por SQL, existe para quem precisa de consultas frequentes; para o Rangô, a trail basta.

### Encontrando quem apagou a fila

O Event History já tem a resposta. Com o profile de administrador:

```bash
aws cloudtrail lookup-events \
  --profile rango-admin \
  --region us-east-1 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=DeleteQueue \
  --start-time 2026-11-16T00:00:00Z \
  --query 'Events[].CloudTrailEvent' \
  --output text | jq '{eventTime, eventName, sourceIPAddress, userAgent, arn: .userIdentity.arn, fila: .requestParameters.queueUrl}'
```

O `lookup-events` aceita um atributo de busca por vez (nome do evento, usuário, recurso, origem) e devolve o evento original como uma string JSON dentro do campo `CloudTrailEvent`, por isso o `jq`. A saída:

```json
{
  "eventTime": "2026-11-16T10:02:41Z",
  "eventName": "DeleteQueue",
  "sourceIPAddress": "198.51.100.77",
  "userAgent": "aws-cli/2.31.4 md/awscrt#0.27.6 ua/2.1 os/linux#6.8.0-48-generic",
  "arn": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_PowerUserAccess_3f9a1c2b7d4e5f60/diego",
  "fila": "https://sqs.us-east-1.amazonaws.com/123456789012/rango-producao-sms"
}
{
  "eventTime": "2026-11-16T10:02:39Z",
  "eventName": "DeleteQueue",
  "sourceIPAddress": "198.51.100.77",
  "userAgent": "aws-cli/2.31.4 md/awscrt#0.27.6 ua/2.1 os/linux#6.8.0-48-generic",
  "arn": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_PowerUserAccess_3f9a1c2b7d4e5f60/diego",
  "fila": "https://sqs.us-east-1.amazonaws.com/123456789012/rango-homologacao-sms"
}
```

O horário está em UTC: 10h02 é 7h02 em Brasília, o minuto em que o gráfico parou. A identidade é uma sessão da role que o Identity Center cria para o permission set `PowerUserAccess`, e o nome da sessão é o usuário: `diego`. O user agent mostra a CLI rodando num Linux. Duas filas apagadas com dois segundos de diferença.

Diego entrou na equipe há duas semanas e está testando um provedor novo de SMS em homologação. A conversa durou cinco minutos e não teve nada de dramático. O script de limpeza da manhã era este:

```bash
aws sqs list-queues --queue-name-prefix rango- --query 'QueueUrls[]' --output text \
  | tr '\t' '\n' | grep -- '-sms$' | xargs -n1 aws sqs delete-queue --queue-url
```

O prefixo `rango-` pega as filas dos dois ambientes. Ninguém agiu de má-fé; a conta permitiu. No postmortem sem culpados, a causa raiz ficou registrada assim: produção e homologação na mesma conta, com a mesma permissão para os dois.

A fila foi recriada com o mesmo nome (o SQS exige esperar 60 segundos para reusar um nome), com os atributos do `cdk synth` e a política de acesso do SNS reaplicada. As mensagens que estavam nela se perderam.

> **Dica:** Para ver tudo o que uma pessoa fez, use `AttributeKey=Username,AttributeValue=diego`. Para tudo o que aconteceu com um recurso, `AttributeKey=ResourceName`.

Um detalhe que confunde: o Event History é por região, e serviços globais como o IAM registram em `us-east-1`. Um invasor que cria máquinas em `ap-southeast-1` não aparece na sua consulta de `us-east-1`. A trail multirregião, mais adiante, junta tudo.

## O robô no login: AWS WAF

O CloudTrail explica a fila. O robô pede outra ferramenta, porque as requisições dele nunca passam pela API da AWS: elas chegam ao ALB, que faz o trabalho dele direitinho e entrega cada uma ao Uvicorn.

O **AWS WAF** (*Web Application Firewall*) é um filtro de requisições HTTP que roda antes da sua aplicação, no CloudFront, no ALB ou no API Gateway. A analogia com o FastAPI é direta: um middleware que inspeciona a requisição (IP, caminho, cabeçalhos, corpo) e decide se ela segue, é bloqueada ou só é contada. A diferença é que esse middleware roda na infraestrutura da AWS, e a requisição bloqueada nunca consome CPU das suas tasks.

Uma **web ACL** é o conjunto de regras associado a um recurso, com uma ação padrão para o que nenhuma regra decidir. Cada **regra** tem uma condição e uma ação (`Allow`, `Block`, `Count`, que só registra, ou um `CAPTCHA`), e as regras são avaliadas por prioridade, da menor para a maior. Os **managed rule groups** são pacotes de regras mantidos pela AWS e atualizados sem você mexer: padrões comuns de ataque, entradas maliciosas conhecidas, IPs de má reputação. Uma web ACL comporta 1.500 WCU (*web ACL capacity units*, a medida do custo de processamento das regras) no preço base.

A peça que resolve o robô é a **regra baseada em taxa** (*rate-based rule*): ela conta requisições por IP numa janela de tempo e bloqueia quem passar do limite. Um dono de restaurante erra a senha duas ou três vezes; ninguém tenta 20 vezes em cinco minutos.

O WAF tem web ACLs regionais (ALB, API Gateway) e web ACLs para CloudFront, que só existem em `us-east-1`. A API do Rangô chega direto ao ALB por `api.rango.com.br`, então o login fica numa web ACL regional. O front ganha uma web ACL própria, mais simples.

Valores de referência da página oficial, outubro de 2026: US$ 5,00 por web ACL por mês, US$ 1,00 por regra ou rule group por mês e US$ 0,60 por milhão de requisições, à parte do ALB e do CloudFront. A web ACL da API, com uma regra de taxa e três rule groups, custa US$ 9 por mês; a do front, US$ 6. O Bot Control (US$ 10,00 por mês por web ACL, mais requisições) e o Fraud Control ficam para quando o ataque vier de milhares de IPs residenciais, cada um tentando poucas vezes, o que passa por baixo de qualquer limite por IP.

### Mão na massa: a web ACL da API

No `rango_infra_stack.py`, acrescente `aws_wafv2 as wafv2` aos imports. Os rule groups gerenciados repetem a mesma estrutura, então uma função ajuda:

```python
def visibilidade(nome: str) -> wafv2.CfnWebACL.VisibilityConfigProperty:
    return wafv2.CfnWebACL.VisibilityConfigProperty(
        cloud_watch_metrics_enabled=True,
        metric_name=nome,
        sampled_requests_enabled=True,
    )


def regra_gerenciada(nome: str, prioridade: int) -> wafv2.CfnWebACL.RuleProperty:
    return wafv2.CfnWebACL.RuleProperty(
        name=nome,
        priority=prioridade,
        statement=wafv2.CfnWebACL.StatementProperty(
            managed_rule_group_statement=wafv2.CfnWebACL.ManagedRuleGroupStatementProperty(
                vendor_name="AWS",
                name=nome,
            )
        ),
        # count={} = só registra; trocar por none={} depois de uma semana sem falso positivo
        override_action=wafv2.CfnWebACL.OverrideActionProperty(count={}),
        visibility_config=visibilidade(nome),
    )
```

O WAF não tem construções L2 no CDK, então usamos as L1 (`Cfn*`), que espelham o CloudFormation campo a campo. É mais verboso, e só isso.

Agora a regra do login e a web ACL, depois da criação do `alb`:

```python
        limite_login = wafv2.CfnWebACL.RuleProperty(
            name="LimiteLogin",
            priority=0,
            action=wafv2.CfnWebACL.RuleActionProperty(block={}),
            statement=wafv2.CfnWebACL.StatementProperty(
                rate_based_statement=wafv2.CfnWebACL.RateBasedStatementProperty(
                    limit=20,
                    evaluation_window_sec=300,
                    aggregate_key_type="IP",
                    scope_down_statement=wafv2.CfnWebACL.StatementProperty(
                        byte_match_statement=wafv2.CfnWebACL.ByteMatchStatementProperty(
                            field_to_match=wafv2.CfnWebACL.FieldToMatchProperty(uri_path={}),
                            positional_constraint="EXACTLY",
                            search_string="/painel/entrar",
                            text_transformations=[
                                wafv2.CfnWebACL.TextTransformationProperty(priority=0, type="NONE")
                            ],
                        )
                    ),
                )
            ),
            visibility_config=visibilidade("LimiteLogin"),
        )

        firewall_api = wafv2.CfnWebACL(
            self,
            "FirewallApi",
            name=f"rango-{ambiente}-api",
            scope="REGIONAL",
            default_action=wafv2.CfnWebACL.DefaultActionProperty(allow={}),
            rules=[
                limite_login,
                regra_gerenciada("AWSManagedRulesAmazonIpReputationList", 1),
                regra_gerenciada("AWSManagedRulesKnownBadInputsRuleSet", 2),
                regra_gerenciada("AWSManagedRulesCommonRuleSet", 3),
            ],
            visibility_config=visibilidade(f"rango-{ambiente}-api"),
        )
        wafv2.CfnWebACLAssociation(
            self,
            "FirewallApiNoAlb",
            resource_arn=alb.load_balancer_arn,
            web_acl_arn=firewall_api.attr_arn,
        )
```

A regra `LimiteLogin` conta, por IP, só as requisições para `/painel/entrar` (o papel do `scope_down_statement`), numa janela de 300 segundos. Passou de 20, o IP recebe 403 até a taxa cair. O resto da API fica fora da conta.

Os rule groups começam em `Count`: você observa por alguns dias o que cada um teria bloqueado e só então passa a bloquear. A regra de taxa já nasce bloqueando, porque é estreita e você sabe o que ela pega.

A web ACL do front, criada na mesma stack em `us-east-1`, usa só a lista de reputação:

```python
        firewall_front = wafv2.CfnWebACL(
            self,
            "FirewallFront",
            name=f"rango-{ambiente}-front",
            scope="CLOUDFRONT",
            default_action=wafv2.CfnWebACL.DefaultActionProperty(allow={}),
            rules=[regra_gerenciada("AWSManagedRulesAmazonIpReputationList", 0)],
            visibility_config=visibilidade(f"rango-{ambiente}-front"),
        )
```

Na `cloudfront.Distribution` existente, acrescente `web_acl_id=firewall_front.attr_arn`. Faça commit e deixe o pipeline do capítulo 18 rodar o `cdk deploy`.

Para conferir a regra de taxa, rode de uma máquina sua (nunca contra o sistema de outra pessoa):

```bash
for i in $(seq 1 30); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST https://api.rango.com.br/painel/entrar \
    -H 'Content-Type: application/json' -d '{"email":"teste@rango.com.br","senha":"errada"}'
done | sort | uniq -c
```

O WAF agrega as contagens e pode levar até um minuto ou mais para começar a bloquear. Rodando o laço duas ou três vezes, a saída fica parecida com:

```text
     22 401
      8 403
```

Os 403 vêm do WAF, sem passar pela API, e as requisições amostradas no console mostram o IP da sua máquina. Em cinco minutos sem tentativas, o bloqueio cai sozinho.

> **Armadilha:** O WAF protege o login de força bruta vinda de poucos IPs, e só. Ele não substitui as defesas da própria aplicação: atraso progressivo depois de erros seguidos na mesma conta, mensagem de erro igual para e-mail inexistente e senha errada, MFA para os donos de restaurante e hash de senha com um algoritmo próprio para isso (Argon2 ou bcrypt, via uma biblioteca estabelecida). Código de autenticação deve passar por revisão de alguém de segurança antes de ir para produção.

### E o Shield?

CloudFront, Route 53 e load balancers já vêm com o **AWS Shield Standard**, sem custo e sem configuração, contra os ataques de negação de serviço mais comuns nas camadas 3 e 4. O **Shield Advanced** custa US$ 3.000 por mês, com compromisso de um ano, mais uma taxa sobre a transferência de dados (referência, outubro de 2026), e acrescenta proteção de camada 7 via WAF. Compensa quando uma hora fora do ar custa mais que a assinatura; para o Rangô, o Standard e a regra de taxa bastam.

## Organizações com várias contas

Dá para resolver o problema do Diego com IAM, escrevendo policies que distinguem `rango-producao-*` de `rango-homologacao-*`. Funciona até a próxima fila ou o próximo serviço: uma cerca feita de exceções.

A fronteira mais simples é a **conta**. Recursos de uma conta não enxergam os de outra sem que você abra a porta dos dois lados, como no acesso entre contas do capítulo 8. Um `delete-queue` em homologação nunca encontra a fila de produção. É a ideia de ter bancos separados para teste e produção, em vez de prefixar as tabelas. A prática do mercado, inclusive em empresas pequenas, é uma organização com várias contas:

```text
Organização (conta de gerenciamento: rango-estudos)
  │   só faturamento, Organizations, Identity Center
  │
  ├── OU Seguranca
  │     └── rango-seguranca   logs do CloudTrail, administrador do GuardDuty
  │
  └── OU Cargas
        ├── rango-homologacao
        └── rango-producao
```

Uma **OU** (*organizational unit*) é uma pasta de contas, onde você pendura políticas que valem para tudo dentro dela. A conta de gerenciamento fica vazia de propósito, por um motivo que aparece nas SCPs. Contas novas não custam nada.

### Criando as contas

O Organizations está ligado desde o capítulo 8, com `rango-estudos` como conta de gerenciamento. Com o profile `rango-admin`, que aponta para ela:

```bash
export AWS_PROFILE=rango-admin

RAIZ=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
OU_SEG=$(aws organizations create-organizational-unit --parent-id "$RAIZ" \
  --name Seguranca --query 'OrganizationalUnit.Id' --output text)
OU_CARGAS=$(aws organizations create-organizational-unit --parent-id "$RAIZ" \
  --name Cargas --query 'OrganizationalUnit.Id' --output text)

aws organizations create-account --email aws-seguranca@rango.com.br --account-name rango-seguranca
aws organizations create-account --email aws-homologacao@rango.com.br --account-name rango-homologacao
aws organizations create-account --email aws-producao@rango.com.br --account-name rango-producao
```

A criação é assíncrona: `aws organizations describe-create-account-status --create-account-request-id <id>` mostra quando vira `SUCCEEDED`, com o número da conta. Cada e-mail precisa ser único na AWS inteira.

As contas nascem na raiz. Mova cada uma para a sua OU:

```bash
aws organizations move-account --account-id 210987654321 \
  --source-parent-id "$RAIZ" --destination-parent-id "$OU_SEG"
aws organizations move-account --account-id 345678901234 \
  --source-parent-id "$RAIZ" --destination-parent-id "$OU_CARGAS"
aws organizations move-account --account-id 456789012345 \
  --source-parent-id "$RAIZ" --destination-parent-id "$OU_CARGAS"
```

Os números são exemplos (segurança, homologação e produção). No Identity Center, o grupo `rango-devs` recebe `PowerUserAccess` em `rango-homologacao` e um permission set novo, `SomenteLeitura`, em `rango-producao`, baseado na policy gerenciada `ViewOnlyAccess`, que lista e descreve recursos sem ler conteúdo (nada de `GetSecretValue`), mais uma inline para o Logs Insights. O grupo `rango-admins` recebe `AdministratorAccess` nas três contas, e o deploy em produção passa a ser só do pipeline.

### Root centralizado

O capítulo 8 prometeu tratar do root das contas novas. Em vez de configurar MFA em três roots, a AWS permite remover as credenciais de root das contas membro e executar as tarefas só-root a partir da conta de gerenciamento:

```bash
aws organizations enable-aws-service-access --service-principal iam.amazonaws.com
aws iam enable-organizations-root-credentials-management
aws iam enable-organizations-root-sessions
```

A partir daí, contas novas da organização nascem sem credenciais de root. O root da conta de gerenciamento continua existindo, com o MFA que você configurou no capítulo 7.

### A mudança do Rangô para a conta nova

Tirar o Rangô da conta de gerenciamento dá trabalho nos recursos com estado ou fora da stack. Na ordem:

1. `cdk bootstrap` na conta `rango-producao` com `--cloudformation-execution-policies` apontando para uma policy restrita aos serviços do Rangô: a exec role restrita que o capítulo 15 deixou para depois.
2. `RangoRegistro` e `RangoPipeline` na conta nova; a variável `AWS_ACCOUNT_ID` do repositório muda.
3. Hosted zone nova com os registros copiados, NS trocados no Registro.br, certificado do ACM reemitido e ARN novo no `cdk.json`.
4. Snapshots criptografados com a chave `aws/rds` não podem ser compartilhados: copie com uma chave customer managed liberada para a conta de produção, compartilhe a cópia e restaure.
5. Bucket de fotos novo e `aws s3 sync`.
6. `cdk deploy` da `RangoProducao` pelo pipeline.

Homologação segue o mesmo caminho, com `ambiente="homologacao"`.

## SCPs: o teto das permissões

Contas separadas resolvem o engano entre ambientes. Falta proteger cada conta de quem tem permissão demais dentro dela, inclusive um administrador com pressa ou uma credencial roubada.

Uma **SCP** (*service control policy*) é uma policy no formato que você conhece, anexada a uma OU ou a uma conta, que define o máximo que qualquer identidade daquela conta pode fazer. O capítulo 8 já mostrou onde ela entra na avaliação: a permissão efetiva é a interseção. Se a SCP nega, nenhum `Allow` em role ou usuário da conta consegue liberar. Pense num decorator aplicado acima de todos os outros decorators de permissão, que pode tirar acesso e nunca dar.

As regras que mais confundem, conferidas na documentação:

- SCPs só existem em organizações com *all features* habilitado. Uma organização só com faturamento consolidado não tem.
- SCPs não concedem permissão. A política `FullAWSAccess`, anexada por padrão em tudo, só diz "o teto é tudo". Se você a remover sem colocar outra no lugar, todas as ações das contas abaixo passam a falhar.
- SCPs não afetam a conta de gerenciamento. Nenhum usuário e nenhuma role de lá é limitado por elas. Esse é o motivo técnico para deixar a conta de gerenciamento vazia: tudo o que roda nela fica fora do alcance das suas proteções.
- SCPs afetam o root das contas membro.
- SCPs não afetam service-linked roles, as roles que os próprios serviços da AWS usam (o ECS, por exemplo, para registrar tasks no target group).

Primeiro, ligue o tipo de política:

```bash
aws organizations enable-policy-type --root-id "$RAIZ" --policy-type SERVICE_CONTROL_POLICY
```

A primeira SCP protege a auditoria e prende as regiões. Salve em `organizacao/scp-base.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ProtegerAuditoria",
      "Effect": "Deny",
      "Action": [
        "cloudtrail:StopLogging",
        "cloudtrail:DeleteTrail",
        "cloudtrail:UpdateTrail",
        "guardduty:DeleteDetector",
        "guardduty:DisassociateFromAdministratorAccount",
        "organizations:LeaveOrganization"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SoRegioesDoRango",
      "Effect": "Deny",
      "NotAction": [
        "iam:*",
        "organizations:*",
        "sts:*",
        "route53:*",
        "cloudfront:*",
        "support:*",
        "budgets:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": ["us-east-1", "sa-east-1"]
        }
      }
    }
  ]
}
```

O segundo bloco lembra a `SoRegioesDoRango` do capítulo 8, agora valendo para a conta inteira e para todos os serviços. O `NotAction` deixa de fora os serviços globais, para que uma chamada a eles nunca seja confundida com uma chamada fora das regiões permitidas. Um invasor com credencial roubada não consegue subir máquinas de mineração em `ap-southeast-1`, que é onde ninguém olharia.

A segunda SCP vale só para produção e responde diretamente à fila apagada. Salve em `organizacao/scp-producao.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SoOCloudFormationApagaDados",
      "Effect": "Deny",
      "Action": [
        "sqs:DeleteQueue",
        "dynamodb:DeleteTable",
        "rds:DeleteDBInstance",
        "rds:DeleteDBSnapshot",
        "s3:DeleteBucket",
        "backup:DeleteRecoveryPoint"
      ],
      "Resource": "*",
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalArn": "arn:aws:iam::*:role/cdk-hnb659fds-cfn-exec-role-*"
        }
      }
    }
  ]
}
```

Em produção, só a role de execução do CloudFormation (a do bootstrap do CDK) apaga filas, tabelas, bancos e buckets. Nem o administrador pelo console. Se um recurso precisa sumir, ele sai do código e o pipeline aplica, deixando rastro no git e no CloudTrail.

A documentação recomenda testar SCPs numa OU antes de anexá-las a contas importantes, e nunca começar pela raiz. Por isso a ordem abaixo começa por homologação, que fica numa OU de teste por alguns dias:

```bash
SCP_BASE=$(aws organizations create-policy --type SERVICE_CONTROL_POLICY \
  --name rango-base --description "Auditoria protegida e regioes do Rango" \
  --content file://organizacao/scp-base.json --query 'Policy.PolicySummary.Id' --output text)
SCP_PROD=$(aws organizations create-policy --type SERVICE_CONTROL_POLICY \
  --name rango-producao --description "Apagar dados so pelo CloudFormation" \
  --content file://organizacao/scp-producao.json --query 'Policy.PolicySummary.Id' --output text)

aws organizations attach-policy --policy-id "$SCP_BASE" --target-id "$OU_CARGAS"
aws organizations attach-policy --policy-id "$SCP_PROD" --target-id 456789012345
```

Agora repita o script do Diego, com o seu profile de administrador da conta de produção:

```bash
aws sqs delete-queue --profile rango-producao-admin \
  --queue-url https://sqs.us-east-1.amazonaws.com/456789012345/rango-producao-sms
```

```text
An error occurred (AccessDenied) when calling the DeleteQueue operation: User:
arn:aws:sts::456789012345:assumed-role/AWSReservedSSO_AdministratorAccess_9b8c7d6e5f4a3b21/voce
is not authorized to perform: sqs:DeleteQueue on resource:
arn:aws:sqs:us-east-1:456789012345:rango-producao-sms with an explicit deny in a service control policy
```

O final da mensagem diz de onde veio a negação: a resposta está no Organizations, longe das policies da conta.

> **Armadilha:** Se você desabilitar o tipo de política SCP na raiz, todas as SCPs são desanexadas. Ao reabilitar, só a `FullAWSAccess` volta; os anexos se perdem e precisam ser refeitos à mão. Mantenha os comandos de `attach-policy` num script versionado, junto com os JSON.

## Os logs num lugar que ninguém apaga

Uma trail que grava no bucket da própria conta tem um ponto fraco: quem é administrador ali apaga o bucket e a prova junto. Os logs vão para a conta `rango-seguranca`, e a trail é uma **organization trail**: criada na conta de gerenciamento, registra os eventos de todas as contas, em todas as regiões. O bucket nasce numa stack nova, `RangoSeguranca`, em `rango_infra/seguranca_stack.py`:

```python
from aws_cdk import Duration, RemovalPolicy, Stack
from aws_cdk import aws_events as events
from aws_cdk import aws_events_targets as alvos
from aws_cdk import aws_iam as iam
from aws_cdk import aws_s3 as s3
from aws_cdk import aws_sns as sns
from aws_cdk import aws_sns_subscriptions as assinaturas
from constructs import Construct


class SegurancaStack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        conta_gerenciamento: str,
        id_organizacao: str,
        email_alertas: str,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        trilha_arn = f"arn:aws:cloudtrail:us-east-1:{conta_gerenciamento}:trail/rango-organizacao"

        bucket = s3.Bucket(
            self,
            "LogsTrilha",
            bucket_name=f"rango-trilha-{self.account}",
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            enforce_ssl=True,
            versioned=True,
            removal_policy=RemovalPolicy.RETAIN,
            lifecycle_rules=[
                s3.LifecycleRule(
                    transitions=[
                        s3.Transition(
                            storage_class=s3.StorageClass.GLACIER_INSTANT_RETRIEVAL,
                            transition_after=Duration.days(90),
                        )
                    ],
                    expiration=Duration.days(730),
                    noncurrent_version_expiration=Duration.days(30),
                )
            ],
        )
        cloudtrail = iam.ServicePrincipal("cloudtrail.amazonaws.com")
        bucket.add_to_resource_policy(
            iam.PolicyStatement(
                actions=["s3:GetBucketAcl"],
                principals=[cloudtrail],
                resources=[bucket.bucket_arn],
                conditions={"StringEquals": {"aws:SourceArn": trilha_arn}},
            )
        )
        bucket.add_to_resource_policy(
            iam.PolicyStatement(
                actions=["s3:PutObject"],
                principals=[cloudtrail],
                resources=[
                    bucket.arn_for_objects(f"AWSLogs/{conta_gerenciamento}/*"),
                    bucket.arn_for_objects(f"AWSLogs/{id_organizacao}/*"),
                ],
                conditions={
                    "StringEquals": {
                        "aws:SourceArn": trilha_arn,
                        "s3:x-amz-acl": "bucket-owner-full-control",
                    }
                },
            )
        )
```

A condição `aws:SourceArn` impede que outra trail use o seu bucket. O lifecycle segue o capítulo 11: Glacier Instant Retrieval depois de 90 dias, exclusão com dois anos; com exigência legal de retenção, ajuste o prazo e considere o S3 Object Lock. No `app.py`, a stack recebe o `env` da conta de segurança, o ID da organização (`aws organizations describe-organization --query Organization.Id`) e o `email_alertas` do contexto. Com o bucket pronto, a trail nasce na conta de gerenciamento:

```bash
aws organizations enable-aws-service-access --service-principal cloudtrail.amazonaws.com

aws cloudtrail create-trail \
  --name rango-organizacao \
  --s3-bucket-name rango-trilha-210987654321 \
  --is-multi-region-trail \
  --is-organization-trail \
  --enable-log-file-validation \
  --region us-east-1

aws cloudtrail start-logging --name rango-organizacao --region us-east-1
```

O `--enable-log-file-validation` faz o CloudTrail gravar, a cada hora, um arquivo de resumo (*digest*) assinado com os hashes dos arquivos de log. Se alguém alterar ou apagar um arquivo, `aws cloudtrail validate-logs --trail-arn <arn> --start-time 2026-11-16T00:00:00Z` acusa. Em alguns minutos, os primeiros arquivos `.json.gz` aparecem sob `AWSLogs/<id-da-organização>/<conta>/CloudTrail/<região>/`.

> **Na vida real:** O AWS Control Tower monta esta mesma estrutura (OUs, conta de logs, organization trail, guardrails) com alguns cliques, e compensa para quem vai ter dezenas de contas. Fazer à mão uma vez ensina o que ele cria por você.

## GuardDuty: quem olha os logs às 3h

O CloudTrail grava tudo, mas ninguém lê milhões de eventos. O **Amazon GuardDuty** lê por você. Ele analisa continuamente os eventos de gerenciamento do CloudTrail, os VPC Flow Logs e as consultas DNS das suas VPCs, sem que você precise ligar essas fontes nem pagar por elas separadamente, e compara o que vê com listas de ameaças conhecidas e com o comportamento normal da conta.

O resultado são **findings**, com tipo e severidade. Alguns que fazem sentido para o Rangô:

- `UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS`: credenciais temporárias de uma instância ou task sendo usadas a partir de um IP fora da AWS. É o padrão do caso Capital One do capítulo 9.
- `Recon:IAMUser/MaliciousIPCaller`: chamadas de API vindas de um IP numa lista de ameaças.
- `CryptoCurrency:EC2/BitcoinTool.B!DNS`: uma máquina consultando domínios de pools de mineração.
- `Policy:IAMUser/RootCredentialUsage`: alguém usando o root.

Os *protection plans* opcionais (eventos de dados do S3, logins no RDS, Runtime Monitoring em containers, varredura de malware) são cobrados à parte. O primeiro uso tem 30 dias grátis por conta e por região, e cada plano novo ganha os seus 30 dias, exceto o Malware Protection for S3, que tem franquia gratuita. O console mostra os dias restantes e uma estimativa de custo diário com base no uso real; use-a no fim do teste para decidir o que manter.

### Ligando para a organização inteira

Na conta de gerenciamento, delegue a administração do GuardDuty à conta de segurança:

```bash
aws guardduty enable-organization-admin-account \
  --admin-account-id 210987654321 --region us-east-1
```

Na conta de segurança, faça o GuardDuty ser ligado automaticamente em todas as contas, atuais e futuras:

```bash
export AWS_PROFILE=rango-seguranca-admin
DETECTOR=$(aws guardduty list-detectors --region us-east-1 --query 'DetectorIds[0]' --output text)
aws guardduty update-organization-configuration \
  --detector-id "$DETECTOR" --auto-enable-organization-members ALL --region us-east-1
```

Repita em `sa-east-1`: o GuardDuty é regional, e as outras regiões estão bloqueadas pela SCP. Os findings de todas as contas aparecem na conta de segurança. Para não depender de alguém abrir o console, acrescente à `SegurancaStack` uma regra do EventBridge:

```python
        topico = sns.Topic(self, "TopicoSeguranca", topic_name="rango-seguranca-alertas")
        topico.add_subscription(assinaturas.EmailSubscription(email_alertas))

        events.Rule(
            self,
            "AchadosGraves",
            event_pattern=events.EventPattern(
                source=["aws.guardduty"],
                detail_type=["GuardDuty Finding"],
                detail={"severity": [{"numeric": [">=", 7]}]},
            ),
            targets=[alvos.SnsTopic(topico)],
        )
```

Severidade 7 ou mais é *high* ou crítica; o resto fica para a revisão semanal, porque mandar tudo por e-mail ensina a equipe a ignorar o GuardDuty. Para testar, gere um finding de exemplo:

```bash
aws guardduty create-sample-findings --detector-id "$DETECTOR" \
  --finding-types "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS" \
  --region us-east-1
```

Em alguns minutos, chega no e-mail um JSON com `"severity": 8` e o título do finding, marcado como amostra. Arquive os exemplos no console depois.

## Config e Security Hub: o que está configurado errado agora

GuardDuty olha comportamento. Falta olhar configuração: um Security Group que alguém abriu para `0.0.0.0/0` na porta 5432, um bucket novo sem Block Public Access, um banco com acesso público.

O **AWS Config** grava o histórico de configuração de cada recurso: cada mudança vira um *configuration item*, ligado ao evento do CloudTrail que a causou, e você pergunta como estava o `SgApi` na terça às 15h. Por cima rodam as **Config rules**, como `restricted-ssh` e `rds-instance-public-access-check`, que marcam recursos como conformes ou não. Ele cobra por item gravado e por avaliação de regra.

O **AWS Security Hub** junta tudo num painel. A versão nova, em disponibilidade geral desde 2 de dezembro de 2025, correlaciona findings do GuardDuty, do Amazon Inspector (vulnerabilidades em imagens do ECR e em Lambdas) e das checagens de configuração, e prioriza o que é risco real. O serviço anterior, com padrões como o AWS Foundational Security Best Practices, passou a se chamar **Security Hub CSPM** e faz parte do novo.

O plano Essentials cobra por *resource unit* por mês: uma instância EC2, ou 18 imagens no ECR, ou 12 Lambdas, ou 125 usuários e roles do IAM; o resto entra sem custo. Inclui o CSPM, o Inspector e um gravador do Config gerenciado pelo serviço. O Rangô tem zero EC2, umas 30 imagens no ECR, 10 Lambdas e menos de 125 roles: umas 4 unidades. O exemplo oficial usa US$ 3,75 por unidade, valor que a AWS pede para confirmar na calculadora. São 30 dias de teste.

Ligue pelo console da conta de segurança, como administrador delegado. O primeiro relatório assusta, com dezenas de itens de severidade baixa; no Rangô, vieram primeiro o bucket `rango-trilha` sem Object Lock e o ALB sem logs de acesso. Corrija críticos e altos, e suprima com justificativa escrita o que não se aplica.

## AWS Backup: o backup que o administrador não apaga

O capítulo 12 deixou uma fraqueza à vista: os backups automáticos do RDS somem quando a instância é apagada, e um snapshot manual pode ser apagado por qualquer pessoa com permissão na conta. As tabelas do DynamoDB têm o mesmo problema. Se uma credencial de administrador de produção vazar, quem a tiver apaga o banco e os backups juntos.

O **AWS Backup** centraliza backups de vários serviços (RDS, DynamoDB, EBS, EFS, S3 e outros) em **planos**: regras com horário, retenção e cópias. Os pontos de restauração ficam em **cofres** (*backup vaults*), e um cofre pode estar em outra conta da organização. Com o **Vault Lock** em modo *compliance*, depois de um período de carência de alguns dias, ninguém consegue apagar os pontos de restauração antes do prazo: nem você, nem o root da conta.

Na `RangoProducao`, acrescente `aws_backup as backup`:

```python
        cofre = backup.BackupVault(
            self, "CofreLocal", backup_vault_name=f"rango-{ambiente}"
        )
        cofre_seguranca = backup.BackupVault.from_backup_vault_arn(
            self,
            "CofreSeguranca",
            self.node.try_get_context("cofre_seguranca_arn"),
        )
        plano = backup.BackupPlan(self, "PlanoBackup", backup_plan_name=f"rango-{ambiente}")
        plano.add_rule(
            backup.BackupPlanRule(
                rule_name="diario",
                backup_vault=cofre,
                schedule_expression=events.Schedule.cron(hour="6", minute="0"),
                delete_after=Duration.days(35),
                copy_actions=[
                    backup.BackupPlanCopyActionProps(
                        destination_backup_vault=cofre_seguranca,
                        delete_after=Duration.days(90),
                    )
                ],
            )
        )
        plano.add_selection(
            "DadosDoRango",
            resources=[
                backup.BackupResource.from_rds_database_instance(db),
                backup.BackupResource.from_dynamo_db_table(tabela_entregas),
                backup.BackupResource.from_dynamo_db_table(tabela_fluxo),
            ],
        )
```

Todo dia às 6h UTC (3h em Brasília), o plano copia banco e tabelas para o cofre local, guarda por 35 dias e envia cada ponto de restauração para o cofre da conta de segurança (ARN em `cofre_seguranca_arn` no `cdk.json`), onde fica por 90.

Fora deste código ficam: habilitar a cópia entre contas nas configurações do AWS Backup da conta de gerenciamento, uma política de acesso no cofre de destino aceitando cópias da organização, o Vault Lock aplicado com `aws backup put-backup-vault-lock-configuration` e, para o RDS criptografado com a chave do capítulo 16, a key policy liberando a conta de destino. Teste uma restauração a partir do cofre de segurança antes de confiar nele. O preço depende do serviço e do volume; consulte a página oficial com os tamanhos reais.

## Quando acontecer de verdade

A segunda-feira do Rangô terminou bem: um engano honesto e um robô sem sorte. Um incidente de verdade começa com um e-mail do GuardDuty às 2h. O roteiro do capítulo 6 vale, com passos próprios de segurança:

1. **Confirmar** o que está acontecendo com o CloudTrail: qual credencial, de qual IP, desde quando, o que ela fez.
2. **Conter** sem destruir. Desative a access key suspeita (`aws iam update-access-key --status Inactive`). Para uma role, use "Revoke active sessions" no console do IAM, que acrescenta uma policy negando tudo para sessões emitidas antes daquele instante. No Identity Center, desativar o usuário impede novos logins, mas as sessões já emitidas valem até expirar; se não puder esperar, uma SCP de emergência negando tudo na conta afetada corta todo mundo na hora, inclusive o invasor. Para tráfego, um IP set no WAF bloqueia faixas em segundos.
3. **Preservar evidências.** Antes de apagar uma instância comprometida, tire um snapshot do disco. Os logs já estão a salvo na conta de segurança.
4. **Erradicar e recuperar**: rotacionar segredos que a credencial podia ler (a rotação do capítulo 16 ajuda), recriar recursos a partir do código, restaurar dados do cofre.
5. **Escrever o postmortem** sem culpados.

A AWS avisa sobre abuso na conta pelo contato de segurança dos *alternate contacts* do capítulo 7. Confira se ele chega a alguém que ainda trabalha no Rangô.

> **Dica:** Guarde esse roteiro no repositório, com os comandos prontos e os números das contas.

## Armadilhas e casos reais

> **Armadilha:** Trail de uma região só. Uma trail criada pelo console já nasce multirregião, mas pela CLI o padrão é uma região só, sem o `--is-multi-region-trail`. O invasor que cria recursos em outra região fica de fora dos seus arquivos.

> **Armadilha:** Web ACL do CloudFront criada fora de `us-east-1`. O CloudFront só aceita web ACLs de escopo `CLOUDFRONT`, e elas só existem em `us-east-1`. A mesma regra do certificado do ACM, do capítulo 14.

> **Armadilha:** Rule group gerenciado esquecido em `Count`. Ligar em modo de contagem é o certo; esquecer lá por meses dá a sensação de proteção sem proteção nenhuma. Ponha uma data no calendário para revisar as métricas e trocar para bloqueio.

> **Armadilha:** Limite de taxa e CGNAT. O capítulo 1 mostrou que muitos clientes de operadoras brasileiras compartilham o mesmo IP público. Um limite por IP muito baixo numa rota usada por todos os clientes, como `POST /pedidos`, bloqueia gente honesta. No login do painel, com poucos usuários, o risco é pequeno.

> **Armadilha:** O `AWSManagedRulesCommonRuleSet` bloqueia corpos grandes com a regra `SizeRestrictions_BODY`. O Rangô escapa porque as fotos vão direto para o S3, mas uma API que recebe uploads começa a devolver 403 sem motivo aparente.

> **Armadilha:** Workload na conta de gerenciamento. Nenhuma SCP vale lá. Se o Rangô continuasse em `rango-estudos`, todas as políticas desta seção seriam decorativas para ele.

> **Armadilha:** Custo do Config. Recursos que mudam o tempo todo, como tasks do ECS substituídas a cada deploy, geram muitos itens gravados. Confira a fatura da primeira semana.

> **Na vida real:** Os vazamentos de chave do capítulo 8 seguem o mesmo roteiro: em minutos, alguém chama `RunInstances` em várias regiões para minerar criptomoeda. A SCP de regiões barra as máquinas, o GuardDuty avisa, e a trail guarda a prova onde o invasor não alcança.

## Resumo

- O CloudTrail registra cada chamada de API: gerenciamento grátis por 90 dias no Event History, por região. Uma organization trail multirregião guarda tudo num bucket de outra conta.
- O WAF filtra requisições no ALB e no CloudFront; uma regra de taxa com `scope_down_statement` protege o login. Rule groups gerenciados começam em `Count`. Shield Standard vem incluso.
- O GuardDuty lê CloudTrail, VPC Flow Logs e DNS sem configuração; o EventBridge manda os findings graves por e-mail.
- Config grava o histórico de configuração; o Security Hub (novo desde dezembro de 2025, com o antigo renomeado para Security Hub CSPM) reúne e prioriza findings.
- Contas separadas são a fronteira mais simples entre ambientes. A conta de gerenciamento fica vazia, porque SCPs não valem nela.
- SCPs definem o teto de permissões das contas membro, nunca concedem nada, valem até para o root e não alcançam service-linked roles. Teste numa OU antes de anexar em produção.
- AWS Backup com cópia para um cofre em outra conta, com Vault Lock, protege os dados até de um administrador comprometido.

## A fatura de dezembro

O Rangô está protegido como nunca esteve: três contas novas, trail da organização, GuardDuty, Security Hub, WAF e backups em outra conta. Cada peça custa pouco. A soma é outra conversa.

No dia 4 de janeiro, chega a fatura de dezembro, o primeiro mês inteiro com as contas novas, maior que o faturamento do Rangô no mês. O Bruno manda uma foto do e-mail com uma pergunta só: "isso é normal?". Você não sabe dizer qual linha é de qual coisa, nem quanto custa um pedido. Os endpoints de interface somam mais que a API inteira, os testes grátis do GuardDuty e do Security Hub acabaram no meio do mês, e há um volume EBS de 100 GiB que ninguém lembra de ter criado.

No último capítulo: AWS Cost Explorer, budgets, tags de custo, os vilões clássicos (NAT Gateway, tráfego de saída, recursos esquecidos), Savings Plans e Spot, o Well-Architected Framework, uma revisão final do Rangô e os próximos passos para você.

## Referências

- AWS CloudTrail, preços (Event History, primeira cópia grátis, CloudTrail Lake): https://aws.amazon.com/cloudtrail/pricing/
- AWS CloudTrail, User Guide: https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
- CloudTrail, trails para organizações: https://docs.aws.amazon.com/awscloudtrail/latest/userguide/creating-trail-organization.html
- CloudTrail, validação de integridade dos arquivos de log: https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-validation-intro.html
- AWS WAF, preços: https://aws.amazon.com/waf/pricing
- AWS WAF, regras baseadas em taxa: https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-rate-based.html
- AWS WAF, managed rule groups da AWS: https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-list.html
- AWS Shield, preços: https://aws.amazon.com/shield/pricing
- Amazon GuardDuty, preços e período de teste: https://docs.aws.amazon.com/guardduty/latest/ug/guardduty-pricing.html
- Amazon GuardDuty, página de preços dos protection plans: https://aws.amazon.com/guardduty/pricing
- Amazon GuardDuty, tipos de finding: https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_finding-types-active.html
- AWS Config, preços: https://aws.amazon.com/config/pricing
- AWS Security Hub, anúncio de disponibilidade geral (dezembro de 2025): https://aws.amazon.com/about-aws/whats-new/2025/12/security-hub-near-real-time-risk-analytics/
- AWS Security Hub, perguntas frequentes (Security Hub CSPM): https://aws.amazon.com/security-hub/faqs/
- AWS Security Hub, preços: https://aws.amazon.com/security-hub/pricing/
- AWS Organizations, service control policies: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- IAM, gerenciamento centralizado do root das contas membro: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html
- AWS Backup, Developer Guide: https://docs.aws.amazon.com/aws-backup/latest/devguide/whatisbackup.html
- AWS Security Incident Response Guide: https://docs.aws.amazon.com/whitepapers/latest/aws-security-incident-response-guide/welcome.html
