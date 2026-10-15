# Custos e arquitetura

No capítulo anterior, o Rangô ganhou um registro de cada chamada de API no CloudTrail, um WAF na frente do login, o GuardDuty lendo os logs da organização e backups copiados para uma conta que ninguém da produção alcança. Ele também mudou de endereço: agora vive na conta `rango-producao`, ao lado de `rango-homologacao` e `rango-seguranca`, todas debaixo de SCPs, enquanto a `rango-estudos` cuida só do faturamento e do Identity Center. O capítulo terminou com uma fatura chegando.

## Segunda-feira, 4 de janeiro

A mensagem do Bruno chega às 9h12. É uma foto da tela do notebook, com o e-mail da AWS aberto: "Your AWS bill for December 2026 is available. Total: USD 687.18". Embaixo, uma pergunta só: "isso é normal?".

Você faz a conta que ele já fez. O Rangô cobra uma taxa de serviço de R$ 0,50 por pedido, e dezembro fechou com 6.812 pedidos: R$ 3.406. A fatura, convertida no cartão com câmbio e IOF, passou de R$ 3.700. Cada pedido custou mais em infraestrutura do que rendeu.

Você entra no console da `rango-estudos`, a conta de gerenciamento da organização. Desde o capítulo 8, quando o AWS Organizations foi ativado, ela paga a conta de todas as outras: isso se chama *consolidated billing*, uma fatura só para a organização inteira. A página de faturas mostra o total por serviço:

| Serviço | Dezembro (US$) |
|---------|---------------:|
| Amazon Virtual Private Cloud | 227,42 |
| Amazon Simple Storage Service | 124,70 |
| Amazon Elastic Container Service | 58,00 |
| Elastic Load Balancing | 54,00 |
| EC2 - Other | 48,98 |
| AWS WAF | 36,00 |
| Amazon DynamoDB | 34,10 |
| Amazon Relational Database Service | 29,40 |
| Amazon CloudWatch | 18,20 |
| AWS Config | 16,30 |
| Amazon GuardDuty | 13,70 |
| AWS Security Hub | 8,50 |
| Outros | 17,88 |
| **Total** | **687,18** |

Os valores desta história são hipotéticos, montados com os preços de referência que o livro usou (us-east-1, outubro de 2026). As perguntas que eles provocam são reais.

A linha mais cara é a VPC, que o capítulo 10 disse ser gratuita. O S3 guarda menos de 5 GB de fotos e custou mais que a API. Há um "EC2 - Other" numa organização sem instâncias desde o capítulo 17. E nada ali diz quanto é produção, quanto é homologação e quanto custa um pedido.

Você responde que não, e pede até o dia seguinte.

## Como a AWS cobra

Antes de abrir qualquer ferramenta, ajuda saber o que a AWS mede. Quase tudo na fatura cai em um de três medidores.

O primeiro é **tempo ligado**: horas de NAT Gateway, endpoint, load balancer, banco, task do Fargate, IPv4 público. Ele gira às 4h da manhã, sem nenhum pedido. O segundo é **volume guardado**: GB-mês de EBS, S3, snapshot, log, que nunca diminui sozinho. O terceiro é **movimento**: GB que saem para a internet, requisições, invocações, unidades do DynamoDB.

Para um projeto do tamanho do Rangô, o perigo mora no primeiro. Somando as linhas que cobram por hora, o Rangô gastou perto de US$ 0,60 por hora só por existir, nas duas contas. Os 6.812 pedidos mexeram pouco no total.

## Cost Explorer: a fatura aberta em fatias

O **AWS Cost Explorer** é a ferramenta da AWS para olhar o gasto por dimensão: serviço, conta, região, tipo de uso, tag. O console dele não tem custo adicional; cada chamada pela API é cobrada. Os dados são atualizados pelo menos uma vez a cada 24 horas, então o gasto de hoje só aparece amanhã. Ele também projeta o futuro com base no histórico: até 18 meses na visão mensal e 3 meses na diária.

Na primeira vez, é preciso abrir o Cost Explorer no console da conta de gerenciamento para ativá-lo. Ela enxerga o gasto de todas as contas membro.

### Por conta e por serviço

Com o profile de administrador da `rango-estudos`, a primeira pergunta é de onde vem o dinheiro:

```bash
aws sso login --sso-session rango

aws ce get-cost-and-usage \
  --profile rango-admin \
  --time-period Start=2026-12-01,End=2027-01-01 \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=LINKED_ACCOUNT Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[].[Keys[0],Keys[1],Metrics.UnblendedCost.Amount]' \
  --output text | sort -t$'\t' -k3 -rn | head -12
```

A data de fim é exclusiva, e o Cost Explorer aceita até dois agrupamentos por consulta. O `sort` separa por tabulação porque os nomes de serviço têm espaços.

```text
456789012345	Amazon Simple Storage Service	124.6987
345678901234	Amazon Virtual Private Cloud	115.3196
456789012345	Amazon Virtual Private Cloud	112.1034
345678901234	EC2 - Other	48.9821
456789012345	Amazon DynamoDB	34.0977
456789012345	Amazon Elastic Container Service	29.0113
345678901234	Amazon Elastic Container Service	28.9890
456789012345	Elastic Load Balancing	27.1203
345678901234	Elastic Load Balancing	26.8811
456789012345	AWS WAF	18.0410
345678901234	AWS WAF	17.9604
456789012345	Amazon Relational Database Service	15.1031
```

A conta `345678901234` é a `rango-homologacao`, que só a equipe usa, e ela custa quase o mesmo que a produção em VPC, load balancer, Fargate e WAF. No total, homologação ficou com US$ 231,28 e produção com US$ 434,70; o resto é de `rango-seguranca` e `rango-estudos`. As contas do capítulo 23, criadas por segurança, viraram de graça a primeira dimensão de custo do Rangô.

### Descendo ao tipo de uso

"Amazon Virtual Private Cloud" ainda diz pouco. O tipo de uso (*usage type*) é o nome do medidor que gerou o valor:

```bash
aws ce get-cost-and-usage \
  --profile rango-admin \
  --time-period Start=2026-12-01,End=2027-01-01 \
  --granularity MONTHLY \
  --metrics UnblendedCost UsageQuantity \
  --filter '{"Dimensions": {"Key": "SERVICE", "Values": ["Amazon Virtual Private Cloud"]}}' \
  --group-by Type=DIMENSION,Key=USAGE_TYPE \
  --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.UsageQuantity.Amount,Metrics.UnblendedCost.Amount]' \
  --output text
```

```text
USE1-PublicIPv4:InUseAddress	3720	18.6000
USE1-VpcEndpoint-Bytes	52.3	0.5230
USE1-VpcEndpoint-Hours	20832	208.3200
```

Os nomes trazem prefixo de região e podem variar; o que importa são as quantidades. São 20.832 horas de endpoint num mês de 744: os 7 interface endpoints do Rangô (Ssm, SecretsManager, EcrApi, EcrDocker, Logs, StepFunctions e XRay) em 2 AZs e 2 contas, a cerca de US$ 0,01 por hora cada, o preço do capítulo 10. E 3.720 horas de IPv4 são 5 endereços: os nós dos dois ALBs e um quinto inesperado. A VPC continua gratuita; o que se paga são as peças dentro dela.

A mesma consulta, filtrando "EC2 - Other", explica a linha fantasma. Esse grupo junta tudo o que o Cost Explorer associa ao EC2 sem ser instância: volumes EBS, snapshots, NAT Gateway, transferência entre AZs. Em homologação, ele mostra `NatGateway-Hours` com 744 horas, `NatGateway-Bytes` quase zerado e `EBS:VolumeUsage.gp3` com 100 GB-mês. Um NAT Gateway e um volume de 100 GiB numa conta que, pelo código, não tem nenhum dos dois.

## Tags de custo: quem gastou o quê

Contas separam ambientes. Dentro da produção, a pergunta seguinte é por componente: quanto custam as fotos, o rastreamento de entregas, o fluxo do pedido, a observabilidade. A resposta vem de *tags*, os pares chave-valor que quase todo recurso da AWS aceita.

Uma tag no recurso só aparece na fatura depois de ativada como **cost allocation tag** na conta de gerenciamento, e vale dali em diante.

### Tags no CDK

No CDK, `Tags.of(escopo).add(chave, valor)` aplica a tag em tudo abaixo daquele escopo, como um middleware do FastAPI que alcança todas as rotas. Em `app.py`, depois de criar as stacks:

```python
cdk.Tags.of(app).add("projeto", "rango")
```

No construtor da `RangoInfraStack`, no começo, a tag do ambiente e uma variável que vai aparecer de novo neste capítulo:

```python
        producao = ambiente == "producao"
        Tags.of(self).add("ambiente", ambiente)
```

E no fim do construtor, depois que todos os recursos existem, a tag de componente nos constructs principais, buscados pelo ID:

```python
        componentes = {
            "api": ["ServicoApi", "AlbApi"],
            "entregas": ["TabelaEntregas"],
            "fluxo": ["TabelaFluxo"],
        }
        for componente, ids in componentes.items():
            for id_construct in ids:
                Tags.of(self.node.find_child(id_construct)).add("componente", componente)
```

O `Tags` vem do `aws_cdk`, como o `RemovalPolicy`. O `find_child` falha no `cdk synth` se o ID não existir, o que pega nome digitado errado. Depois do deploy, as chaves levam até 24 horas para aparecer como ativáveis. Aí, na conta de gerenciamento:

```bash
aws ce update-cost-allocation-tags-status \
  --profile rango-admin \
  --cost-allocation-tags-status \
    TagKey=projeto,Status=Active \
    TagKey=ambiente,Status=Active \
    TagKey=componente,Status=Active
```

A partir do dia seguinte, `--group-by Type=TAG,Key=componente` funciona no Cost Explorer. Os grupos vêm como `componente$api`, `componente$entregas` e um `componente$` vazio com o que não tem a tag. Esse grupo nunca zera, porque transferência, IPv4 e algumas taxas não carregam tag; use-o para medir quanto do gasto está sem dono.

> **Dica:** A AWS gera sozinha a tag `aws:cloudformation:stack-name` em tudo o que uma stack cria. Ela também pode ser ativada como cost allocation tag, e dá o custo por stack sem uma linha de código.

E dezembro? A AWS permite pedir um preenchimento retroativo (*backfill*) das tags ativadas, de até 12 meses. Só que ele só preenche os períodos em que o recurso já tinha a tag. Os recursos do Rangô nunca tiveram, então dezembro continua explicado só por conta e por serviço. Tags que entram hoje pagam o relatório de fevereiro.

## Avisos que chegam antes da fatura

O capítulo 7 criou o budget `rango-mensal` de US$ 20 e o alarme `cobranca-acima-de-10-usd`. O alarme disparou em setembro, quando o primeiro banco subiu, e nunca mais voltou para OK. O budget avisa todo mês desde outubro. Uma regra do e-mail move tudo da AWS para uma pasta, que tem 31 mensagens não lidas.

Um alerta que dispara sempre equivale a nenhum alerta, como o capítulo 22 disse das métricas. O limite de US$ 20 servia para uma conta de estudos vazia; para o Rangô em produção, virou barulho.

### Um budget por ambiente, no código

Um **budget** do AWS Budgets compara o gasto, real ou previsto, com um valor que você define, e avisa ao cruzar um percentual. Os budgets que só monitoram não custam nada, e os dois primeiros com ações também são gratuitos em cada conta. Um budget criado numa conta membro vê só o gasto daquela conta, o que encaixa no desenho do Rangô: cada stack cria o seu.

No `cdk.json`, um valor por ambiente, ao lado do `email_alertas` do capítulo 21:

```json
    "orcamento_producao": 320,
    "orcamento_homologacao": 110
```

E na stack, com `aws_budgets as budgets` nos imports:

```python
        orcamento = self.node.try_get_context(f"orcamento_{ambiente}")
        email = self.node.try_get_context("email_alertas")

        def aviso(tipo: str, percentual: int):
            return budgets.CfnBudget.NotificationWithSubscribersProperty(
                notification=budgets.CfnBudget.NotificationProperty(
                    notification_type=tipo,
                    comparison_operator="GREATER_THAN",
                    threshold=percentual,
                    threshold_type="PERCENTAGE",
                ),
                subscribers=[
                    budgets.CfnBudget.SubscriberProperty(
                        subscription_type="EMAIL", address=email
                    )
                ],
            )

        budgets.CfnBudget(
            self,
            "Orcamento",
            budget=budgets.CfnBudget.BudgetDataProperty(
                budget_name=f"rango-{ambiente}-mensal",
                budget_type="COST",
                time_unit="MONTHLY",
                budget_limit=budgets.CfnBudget.SpendProperty(amount=orcamento, unit="USD"),
            ),
            notifications_with_subscribers=[
                aviso("FORECASTED", 100),
                aviso("ACTUAL", 80),
            ],
        )
```

O aviso que importa é o `FORECASTED`: ele dispara quando a projeção do mês passa do limite. Com ele em dezembro, o NAT esquecido teria aparecido por volta do dia 10, e não no dia 4 do mês seguinte. O `ACTUAL` a 80% é a segunda chance.

Na `rango-estudos`, ajuste o `rango-mensal` para o total da organização, uns US$ 450, e apague o alarme de US$ 10 e o Zero spend, que já cumpriram o papel deles.

### Anomalias

Um budget só vê o total do mês. Uma Lambda em laço que gasta US$ 30 numa tarde mal mexe na projeção. Para isso existe o **AWS Cost Anomaly Detection**, que aprende o padrão de gasto de cada serviço e avisa quando um dia foge dele. Ele precisa de pelo menos 10 dias de histórico para começar e detecta a anomalia em até 24 horas depois do uso.

No console de Billing and Cost Management, crie um monitor do tipo "AWS services" e uma assinatura diária para o e-mail de alertas, só com anomalias de impacto acima de US$ 20. Sem o filtro, avisos sobre centavos ensinam a equipe a ignorá-lo.

> **Armadilha:** Budget avisa, mas não bloqueia. Passar do limite não desliga nada, e a AWS continua cobrando. As *budget actions* conseguem aplicar uma policy ou uma SCP e parar instâncias EC2 e RDS ao cruzar um limite, mas desligar produção por causa de um número é uma decisão de negócio. Em homologação, pode valer a pena; em produção, quase nunca.

## Os vilões clássicos

Com os números abertos, a investigação vira uma lista de suspeitos. Três deles aparecem em quase toda conta da AWS que cresceu sem ninguém olhando para a fatura.

### O NAT que ninguém pediu

O NAT Gateway de homologação tem um ID, e o capítulo 23 deixou a ferramenta certa para descobrir quem o criou:

```bash
export AWS_PROFILE=rango-homologacao

aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=CreateNatGateway \
  --query 'Events[].[EventTime,Username]' --output text
```

```text
2026-11-30T14:22:41-03:00	diego@rango.com.br
```

O profile `rango-homologacao` segue o modelo dos profiles do capítulo 23. O Diego explica no Slack: o gateway de pagamento abriu um ambiente de testes novo, e a API de homologação precisava alcançá-lo. Ele criou o NAT no console, acrescentou uma rota nas subnets privadas, testou, e o plano era apagar tudo no dia seguinte.

O preço é o do capítulo 10: US$ 0,045 por hora e por GB processado, mais o Elastic IP a US$ 0,005 por hora (us-east-1, outubro de 2026). Parado, uns US$ 36 por mês. Com tráfego, cada GB que sai para a internet pelo NAT pagaria processamento e saída, perto de US$ 0,135.

Na limpeza, a ordem importa: a rota manual sai primeiro, o NAT depois, e o Elastic IP por último, senão ele continua cobrando como endereço ocioso. O `cdk drift` de homologação mostra a rota a mais, e o capítulo 15 já avisou que um `cdk deploy` não desfaz drift. No postmortem sem culpa, a causa raiz fica registrada: homologação aceita mudança manual, e nada avisava quando um recurso fora do código continuava ligado.

### Os endpoints que nós pedimos

No Rangô, pesa mais que o NAT uma escolha que o livro fez de propósito: subnets sem saída para a internet e um interface endpoint por serviço. As tasks não alcançam nenhum endereço fora da AWS, e um pacote malicioso numa dependência não tem para onde mandar dados. O capítulo 17 já tinha comparado cinco endpoints com dois NATs. Com sete, ficou assim (us-east-1, outubro de 2026, aproximado):

| Saída das subnets privadas | Custo fixo por mês |
|----------------------------|-------------------:|
| 7 interface endpoints em 2 AZs | ~US$ 100,80 |
| 7 interface endpoints em 1 AZ | ~US$ 50,40 |
| 1 NAT Gateway com Elastic IP | ~US$ 36 + GB |
| 2 NAT Gateways com Elastic IP | ~US$ 72 + GB |

Os gateway endpoints do S3 e do DynamoDB ficam fora da tabela porque não cobram por hora nem por dados, nos dois desenhos. Eles são o motivo de as fotos e as posições dos entregadores nunca terem passado por um NAT.

A decisão muda por ambiente. Em produção, os endpoints ficam nas duas AZs: se uma cair, a outra continua alcançando o ECR, o Secrets Manager e os logs, e os US$ 50 a mais entram no orçamento como preço do isolamento. Em homologação, uma AZ basta. Logo depois da linha `privadas = ...` do capítulo 16, crie a seleção nova:

```python
        subnets_endpoints = ec2.SubnetSelection(
            subnet_type=ec2.SubnetType.PRIVATE_ISOLATED,
            availability_zones=None if producao else [vpc.availability_zones[0]],
        )
```

E troque `subnets=privadas` por `subnets=subnets_endpoints` nos sete `add_interface_endpoint`. Tasks da outra AZ continuam funcionando pelo DNS privado do endpoint, pagando US$ 0,01 por GB entre AZs, centavos em homologação.

### Tráfego de saída: as fotos dos pratos

A segunda linha da fatura era o S3, com US$ 124,70. Armazenamento quase não pesa: 5 GB custam menos de 12 centavos. O que pesa é a saída. Filtrando o S3 por tipo de uso, aparecem uns 1.450 GB de `DataTransfer-Out-Bytes` em dezembro. Tirando os 100 GB mensais gratuitos de saída que o capítulo 11 citou, sobram 1.350 GB a US$ 0,09: US$ 121,50.

A origem é o capítulo 11. A rota de fotos devolve URLs pré-assinadas do S3, e o React mostra cada foto como chegou do celular do dono do restaurante: 4 MB. Um cardápio com 12 pratos baixa 48 MB, e como cada URL pré-assinada é diferente, nem o cache do navegador ajuda.

A maior economia vem de foto menor, e o navegador consegue reduzir a imagem antes do upload. Em `frontend/src/reduzirFoto.ts`:

```tsx
export async function reduzirFoto(arquivo: File, larguraMaxima = 1280): Promise<Blob> {
  const imagem = await createImageBitmap(arquivo);
  const escala = Math.min(1, larguraMaxima / imagem.width);
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(imagem.width * escala);
  canvas.height = Math.round(imagem.height * escala);
  canvas.getContext("2d")!.drawImage(imagem, 0, 0, canvas.width, canvas.height);
  return new Promise((resolve, reject) =>
    canvas.toBlob(
      (blob) => (blob ? resolve(blob) : reject(new Error("Falha ao converter a foto"))),
      "image/jpeg",
      0.82,
    ),
  );
}
```

No `EnviarFoto.tsx`, o `PUT` passa a enviar `await reduzirFoto(arquivo)`, e o pedido da URL de upload declara `image/jpeg`: o capítulo 11 mostrou que o `Content-Type` entra na assinatura, e um tipo diferente termina em `SignatureDoesNotMatch`. A foto de 4 MB vira uns 300 KB. O JPEG está ali porque todo navegador sabe gerá-lo; o Safari, por exemplo, ignora o pedido de WebP no `canvas` e devolve PNG, maior que o original.

A segunda parte é servir as fotos pelo CloudFront que já entrega o React. A transferência do S3 para o CloudFront sai de graça, e o plano pay-as-you-go do capítulo 14 inclui 1 TB de saída por mês. A distribuição ganha um comportamento para `/fotos/*`:

```python
        fotos = s3.Bucket.from_bucket_name(
            self, "BucketFotos", f"rango-fotos-pratos-{self.account}"
        )
        distribuicao.add_behavior(
            "/fotos/*",
            origins.S3BucketOrigin.with_origin_access_control(fotos),
            viewer_protocol_policy=cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
            cache_policy=cloudfront.CachePolicy.CACHING_OPTIMIZED,
        )
```

Como o bucket foi criado fora da stack, o CDK não consegue editar a policy dele e avisa isso no `cdk synth`. A permissão do OAC entra à mão em `infra/s3/rango-fotos-policy.json`, com o mesmo formato do bucket do front no capítulo 14: `s3:GetObject` em `fotos/*` para o principal `cloudfront.amazonaws.com`, com a condição `AWS:SourceArn` apontando para a distribuição.

A API para de assinar leituras. O dicionário `configuracao` do capítulo 16 ganha `"url_publica": f"https://{dominio}"`, que chega ao container como `URL_PUBLICA`. E a lista de fotos deixa o Valkey, onde estava desde o capítulo 11: o cache vai embora a cada `cdk destroy` e leva o registro junto, enquanto as fotos continuam no bucket. A fonte da verdade passa a ser o próprio bucket, e a `role_app` ganha a listagem, restrita ao prefixo das fotos:

```python
        role_app.add_to_policy(
            iam.PolicyStatement(
                actions=["s3:ListBucket"],
                resources=[fotos.bucket_arn],
                conditions={"StringLike": {"s3:prefix": ["fotos/*"]}},
            )
        )
```

```python
URL_PUBLICA = os.environ["URL_PUBLICA"]


@router.get("/restaurantes/{restaurante}/fotos")
def listar_fotos(restaurante: str = Restaurante):
    paginas = s3.get_paginator("list_objects_v2").paginate(
        Bucket=BUCKET, Prefix=f"fotos/{restaurante}/"
    )
    chaves = [obj["Key"] for pagina in paginas for obj in pagina.get("Contents", [])]
    return [f"{URL_PUBLICA}/{chave}" for chave in sorted(chaves)]
```

O `registrar_foto` continua conferindo o prefixo e o tamanho, mas o `r.sadd` sai.

As chaves já começam com `fotos/`, então a URL fica `https://rango.com.br/fotos/cantina-da-nona/...jpg`. O upload continua pré-assinado; a leitura de foto de prato é pública por natureza, porque está no cardápio. As fotos antigas podem ser reduzidas uma vez com um script em Pillow.

Com fotos de 300 KB, os acessos de dezembro dariam uns 110 GB, dentro do 1 TB gratuito do CloudFront.

> **Na vida real:** Em 2024, o engenheiro Maciej Pocwierz criou um bucket S3 vazio e privado para um teste e recebeu uma conta de cerca de US$ 1.300. Uma ferramenta de código aberto usava o mesmo nome de bucket na configuração padrão, e o S3 cobrava até as requisições negadas com 403. Depois da repercussão, a AWS anunciou em maio de 2024 que o dono deixaria de pagar por requisições não autorizadas vindas de fora da conta ou da organização.

### Recursos esquecidos

Sobra o volume EBS de 100 GiB. O CloudTrail conta a história de novo: em 26 de novembro, alguém criou o volume a partir de um snapshot do banco para investigar uma consulta lenta, e o volume nunca foi preso a máquina nenhuma. A gp3 cobra US$ 0,08 por GB-mês com ou sem uso: US$ 8 por mês para guardar uma cópia de banco que ninguém lembra.

Este laço procura volumes soltos, Elastic IPs sem associação e NATs em todas as regiões da conta do profile ativo:

```bash
for regiao in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
  echo "== $regiao"
  aws ec2 describe-volumes --region "$regiao" \
    --filters Name=status,Values=available \
    --query 'Volumes[].[VolumeId,Size,CreateTime]' --output text
  aws ec2 describe-addresses --region "$regiao" \
    --query 'Addresses[?AssociationId==null].PublicIp' --output text
  aws ec2 describe-nat-gateways --region "$regiao" \
    --filter Name=state,Values=available \
    --query 'NatGateways[].[NatGatewayId,VpcId,CreateTime]' --output text
done
```

O `describe-nat-gateways` usa `--filter`, no singular, uma das esquisitices da CLI. Nas contas da OU `Cargas`, a SCP de regiões do capítulo 23 faz as regiões fora de `us-east-1` e `sa-east-1` responderem com erro de autorização. Ótimo sinal: ninguém consegue criar nada lá. Na `rango-estudos`, que é a conta de gerenciamento e não sofre SCP, o laço varre tudo.

E é na `rango-estudos` que aparece o resto. Cada `cdk destroy` dos capítulos 15 a 22 deixou um snapshot final do banco, e eles continuam lá:

```bash
aws rds describe-db-snapshots --profile rango-admin --snapshot-type manual \
  --query 'DBSnapshots[].[DBSnapshotIdentifier,AllocatedStorage,SnapshotCreateTime]' \
  --output text
```

Com o banco em `rango-producao` e protegido pelo AWS Backup, esses snapshots viraram arqueologia: apague-os com `aws rds delete-db-snapshot`, depois de conferir os nomes. A hosted zone antiga de `rango.com.br` também cobra a taxa mensal; confira que o Registro.br aponta para a zona nova e apague a velha.

## Pagar menos pelo que fica ligado

Depois da limpeza, sobra a parte do gasto que tem motivo para existir. A AWS oferece dois descontos para ela, com contratos opostos: você promete ficar, ou aceita ser despejado.

### Savings Plans: desconto em troca de compromisso

Um **Savings Plan** é um compromisso de gastar um valor fixo por hora, em dólares, durante 1 ou 3 anos. Em troca, o uso coberto por esse valor sai com desconto. Existem quatro tipos: Compute, EC2 Instance, SageMaker AI e Database.

O **Compute Savings Plan** dá até 66% de desconto e vale para EC2, Fargate e Lambda, em qualquer família, região ou sistema operacional. O **EC2 Instance Savings Plan** chega a 72%, preso a uma família numa região. O **Database Savings Plan** cobre Aurora, RDS, DynamoDB, ElastiCache e outros bancos gerenciados. Os percentuais variam por serviço, prazo e quanto você paga adiantado.

O Cost Explorer recomenda um valor por hora a partir do histórico. A regra é comprometer o piso, nunca o pico: o compromisso é cobrado mesmo que você desligue tudo amanhã, e não pode ser cancelado.

No Rangô, o piso de computação são as 2 tasks da API em produção: uns US$ 29 por mês, perto de US$ 0,04 por hora. Um plano de US$ 0,03 por hora economiza alguns dólares por mês. Para o Rangô de hoje, a limpeza das seções anteriores rende dez vezes mais; o Savings Plan fica para quando o piso crescer.

### Spot: capacidade de sobra, com aviso prévio de 2 minutos

A AWS tem capacidade ociosa em todas as regiões e a vende com desconto de até 90% em relação ao preço normal, o *On-Demand*. É a **Spot**. A condição é que ela pode pedir a máquina de volta quando precisar, com um aviso de interrupção 2 minutos antes. Às vezes chega antes uma *rebalance recommendation*, avisando que o risco de interrupção subiu. O EventBridge recebe os dois avisos, e o Auto Scaling Group tem o Capacity Rebalancing para trocar a instância antes da hora.

Spot combina com carga sem estado e tolerante a falha, como a API ficou desde o capítulo 4. No ECS, existe o **Fargate Spot**, que aceita tasks ARM desde setembro de 2024. Na interrupção, a task recebe `SIGTERM` com 2 minutos de prazo, e o `CMD` em forma de lista do capítulo 3 garante que o Uvicorn termine as requisições em andamento.

Homologação é a candidata óbvia. No cluster, ative os capacity providers do Fargate:

```python
        cluster = ecs.Cluster(
            self,
            "Cluster",
            vpc=vpc,
            cluster_name=f"rango-{ambiente}",
            enable_fargate_capacity_providers=True,
        )
```

E no `ecs.FargateService` da API, a estratégia de capacidade por ambiente:

```python
            capacity_provider_strategies=None if producao else [
                ecs.CapacityProviderStrategy(capacity_provider="FARGATE_SPOT", weight=1)
            ],
```

Trocar o modo de lançamento de um serviço existente pode fazer o CloudFormation recriá-lo. Em homologação, isso custa alguns minutos fora do ar numa hora combinada. Em produção, a API fica no Fargate comum: o pico do Rangô dura poucas horas por semana, e a economia de colocar as tasks extras em Spot não paga o risco de recriar o serviço que recebe pedidos.

### Desligar o que ninguém usa à noite

O pilar de custo do Well-Architected Framework, que aparece na próxima seção, traz um exemplo que serve direto para homologação: um ambiente de desenvolvimento e teste ligado só no horário comercial usa 40 das 168 horas da semana e economiza 75%.

A escala da API em homologação vira zero à noite e nos fins de semana, com ações agendadas no mesmo `escala` do capítulo 18. Nos imports, entram `aws_applicationautoscaling as appscaling` e `TimeZone`:

```python
        if not producao:
            for nome, hora, minimo, maximo in (("Noite", "20", 0, 0), ("Manha", "8", 1, 2)):
                escala.scale_on_schedule(
                    nome,
                    schedule=appscaling.Schedule.cron(hour=hora, minute="0", week_day="MON-FRI"),
                    min_capacity=minimo,
                    max_capacity=maximo,
                    time_zone=TimeZone.AMERICA_SAO_PAULO,
                )
```

A ação "Noite" roda de segunda a sexta às 20h e zera as tasks. A "Manha" volta para 1 a 2 tasks às 8h dos dias úteis. Como nenhuma ação roda no sábado e no domingo, o zero de sexta à noite vale até segunda de manhã. O fuso explícito evita o erro de UTC que o capítulo 19 já mostrou.

O ALB de homologação continua cobrando, porque load balancer não tem pausa. O banco até pode ser parado, mas o RDS liga sozinho de novo depois de 7 dias, e no `db.t4g.micro` a economia não compensa o trabalho.

## O Rangô contra o Well-Architected

O **AWS Well-Architected Framework** é o conjunto de perguntas que a AWS usa para revisar arquiteturas, organizado em seis pilares: Operational Excellence, Security, Reliability, Performance Efficiency, Cost Optimization e Sustainability. A **AWS Well-Architected Tool**, no console, faz as perguntas uma a uma e guarda as respostas como uma revisão da carga de trabalho. Ela não analisa nada sozinha: quem responde é você, e o valor está nas perguntas que ninguém tinha feito.

O pilar de custo tem cinco princípios de design, e este capítulo aplicou quatro sem dar nome. *Implement cloud financial management*: budgets por ambiente e alguém que lê os avisos. *Adopt a consumption model*: a homologação desligada à noite. *Measure overall efficiency*: o custo por pedido. *Analyze and attribute expenditure*: contas e tags. O quinto, *stop spending money on undifferentiated heavy lifting*, o livro aplica desde o capítulo 12, quando o RDS assumiu backup, patch e failover do Postgres.

Em dezembro, o custo por pedido foi de US$ 687,18 por 6.812 pedidos: perto de US$ 0,10. Com as mudanças deste capítulo, a estimativa para fevereiro fica perto de US$ 430: uns US$ 310 de produção, uns US$ 105 de homologação e o resto nas contas de segurança e gerenciamento. O custo por pedido cai para uns US$ 0,06. A margem segue apertada com uma taxa de R$ 0,50, e essa é a conversa que o Bruno precisa ter com os sócios, agora sabendo quanto custa cada parte.

### A revisão final

Este é o Rangô que saiu do `localhost:8000` do capítulo 1:

```text
                   rango.com.br / www / api
                              │
                         Route 53 (alias)
                 ┌────────────┴─────────────┐
           CloudFront + WAF            ALB + WAF (443)
           │           │                    │  blue/green
     S3 (React)   S3 (fotos/*)      ECS Fargate (API FastAPI, ARM)
                                     │      │      │       │
                                RDS PG 18  Valkey  DynamoDB  Step Functions
                                (1 AZ)   serverless (entregas)  │
                                                         SQS · SNS · Lambda
   ── conta rango-producao, VPC 10.20.0.0/16, 2 AZs, sem NAT, 7 interface endpoints ──
   CloudWatch (logs, métricas, alarmes, SLO) · X-Ray via ADOT · AWS Backup → cofre em rango-seguranca
   CloudTrail da organização · GuardDuty · Security Hub · SCPs · GitHub Actions com OIDC
```

E esta é a revisão honesta, pilar por pilar:

| Pilar | O que o Rangô tem | O que falta |
|-------|-------------------|-------------|
| Operational Excellence | Tudo em CDK, pipeline com OIDC e aprovação, blue/green com rollback por alarme, postmortems sem culpa | Runbooks escritos e um ensaio de incidente por trimestre |
| Security | Identity Center sem chaves longas, contas separadas, SCPs, segredos rotacionados com KMS, WAF, GuardDuty, trilha imutável | Rotas do entregador ainda sem autenticação (capítulo 20); grupos gerenciados do WAF ainda em `Count` |
| Reliability | Duas AZs na rede e na API, PITR, backups em outra conta, filas com DLQ e alarme | Banco em uma AZ só; esgotamento de conexões do Postgres sem correção definitiva (capítulo 22); restore testado à mão, não automático |
| Performance Efficiency | CloudFront na borda, Graviton, Valkey como cache, DynamoDB para o rastreamento | Teste de carga com k6 só antes de eventos, nunca no pipeline |
| Cost Optimization | Contas e tags como dimensão de custo, budgets por ambiente, anomalias, homologação dormindo | Revisar Savings Plans quando o piso de computação crescer |
| Sustainability | Graviton, fotos menores, escala a zero fora do horário | Medir com a ferramenta de pegada de carbono do console de Billing |

Os buracos de confiabilidade são os próximos itens. O Multi-AZ dobra o custo da instância do banco, uma decisão que pede o número de pedidos perdidos por hora de queda. O RDS Proxy, citado no capítulo 19, resolve as conexões e também cobra por hora. As duas mudanças cabem no orçamento que a limpeza abriu.

## Para onde ir daqui

Você começou este livro sabendo construir a aplicação. Agora conhece o caminho de uma requisição desde o DNS até a linha da tabela, e quanto cada passo custa. Algumas direções para continuar:

1. **Refaça o Rangô sozinho**, sem o livro aberto, numa conta de estudos. Onde você travar está o que ainda falta aprender.
2. **Leia postmortems.** Os Post-Event Summaries da AWS e a Amazon Builders' Library contam como quem opera a AWS lida com timeouts, retries e deploys.
3. **Faça uma revisão do Well-Architected** num sistema do seu trabalho.
4. **Aprenda Terraform ou OpenTofu**, muito usados fora do mundo só-AWS, e **Kubernetes** se o seu time precisar; o capítulo 17 deu os critérios.

E leia a fatura todo mês. Ela é o resumo mais honesto da arquitetura que você tem.

### Desligando tudo

Se o Rangô foi um projeto de estudo e você quer parar de pagar, a ordem é:

1. Desabilite os workflows do GitHub (`gh workflow disable`).
2. `cdk destroy` de `RangoProducao` e `RangoHomologacao`, cada uma na sua conta, e depois os snapshots finais que elas deixarem.
3. `cdk destroy` de `RangoPipeline` e `RangoRegistro`; o repositório do ECR tem `RETAIN` e sai com `aws ecr delete-repository --force`.
4. Buckets restantes, hosted zones e cofres do AWS Backup. Um cofre com Vault Lock em modo compliance só some quando os pontos de recuperação vencerem, como o capítulo 23 escolheu.
5. GuardDuty, Security Hub e Config em cada região, o laço de recursos esquecidos em cada conta e, por fim, o fechamento das contas membro.
6. O budget da `rango-estudos` fica até a última fatura chegar zerada.

## Armadilhas e casos reais

> **Armadilha:** O Free plan das contas criadas desde 15 de julho de 2025 expira 6 meses depois do cadastro ou quando os créditos acabam. Sem a mudança para o Paid plan, a conta passa por 90 dias de carência e depois é fechada, com os recursos apagados.

> **Armadilha:** IPv4 público cobra US$ 0,005 por hora por endereço, em uso ou ocioso: uns US$ 3,65 por mês cada. Tasks em subnet pública com IP público pagam um cada, e com dezenas delas a linha cresce sem ninguém perceber.

> **Armadilha:** Testes gratuitos que terminam no meio do mês. GuardDuty, Security Hub e outros serviços têm 30 dias grátis por conta e região. Ligados em várias contas e regiões no mesmo dia, todos começam a cobrar juntos, e a fatura do mês seguinte é a primeira a mostrar o custo real.

> **Armadilha:** Cost Explorer pela API em laço. Um script que consulta a cada minuto para alimentar um painel cria uma linha nova na fatura que deveria vigiar.

## Resumo

- A AWS cobra tempo ligado, volume guardado e movimento. Em projetos pequenos, o tempo ligado domina, mesmo sem tráfego.
- O Cost Explorer abre a fatura por conta, serviço, tipo de uso e tag; console gratuito, API cobrada, dados a cada 24 horas.
- Contas são a primeira dimensão de custo. Tags de custo precisam de ativação e valem dali em diante.
- Budgets por previsão avisam na primeira semana; o Cost Anomaly Detection pega o dia fora do padrão. Nenhum dos dois bloqueia gasto.
- Vilões clássicos: NAT Gateway, interface endpoints multiplicados por AZ, saída para a internet e recursos esquecidos.
- Savings Plans trocam compromisso por desconto; compre pelo piso. Spot e Fargate Spot dão até 90% para carga sem estado.
- O Well-Architected revisa em seis pilares. O custo por pedido do Rangô cai de uns US$ 0,10 para uns US$ 0,06.

## O fim do livro, o começo da operação

O Rangô começou num notebook, com uma sócia em Recife tentando abrir um link que apontava para `localhost`. Hoje ele tem domínio, certificado, rede própria, banco com recuperação até o minuto, deploy sem ninguém digitar comando, alarme que acorda a pessoa certa, trilha de auditoria e uma fatura que alguém sabe ler.

Nada disso está terminado, e a tabela de pilares tem uma coluna de "o que falta" porque toda arquitetura em produção tem uma. O que mudou foram as perguntas: de "como alguém acessa isso?" para "quanto custa uma hora de banco fora do ar?". A segunda é a pergunta de quem cuida de um sistema em produção, e a partir daqui ela é sua.

## Referências

- AWS Cost Explorer e AWS Cost Management (previsões, recursos): https://aws.amazon.com/aws-cost-management/
- AWS Budgets e Cost Explorer, comparação (console gratuito, API cobrada): https://aws.amazon.com/compare/budgets-and-cost-explorer/
- Cotas e limites do AWS Cost Management (Budgets, Cost Anomaly Detection): https://docs.aws.amazon.com/cost-management/latest/userguide/management-limits.html
- Cost allocation tags: https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html
- Backfill de cost allocation tags: https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-allocation-backfill.html
- Anúncio do backfill de tags (março de 2024): https://aws.amazon.com/about-aws/whats-new/2024/03/aws-cost-allocation-tags-retroactive-application/
- Preços da Amazon VPC (NAT Gateway, IPv4 público, endpoints, transferência): https://aws.amazon.com/vpc/pricing/
- Preços do Amazon CloudFront: https://aws.amazon.com/cloudfront/pricing/
- Preços do AWS Fargate: https://aws.amazon.com/fargate/pricing/
- AWS Pricing Calculator: https://calculator.aws/
- Savings Plans, perguntas frequentes: https://aws.amazon.com/savingsplans/faqs
- Tipos de Savings Plans: https://docs.aws.amazon.com/savingsplans/latest/userguide/plan-types.html
- Boas práticas de Spot no EC2: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-best-practices.html
- Fargate Spot com Graviton (setembro de 2024): https://aws.amazon.com/about-aws/whats-new/2024/09/amazon-ecs-graviton-based-spot-compute-fargate/
- Well-Architected, pilar de otimização de custos: https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html
- Princípios de design do pilar de custos: https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/design-principles.html
- AWS Well-Architected Tool: https://aws.amazon.com/well-architected-tool/
- Free Tier com créditos, Free plan e Paid plan (julho de 2025): https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/
- Caso do bucket S3 vazio e mudança na cobrança de requisições não autorizadas (InfoQ, maio de 2024): https://www.infoq.com/news/2024/05/aws-empty-s3-bucket-billing/
- Amazon Builders' Library: https://aws.amazon.com/builders-library/
- AWS Post-Event Summaries: https://aws.amazon.com/premiumsupport/technology/pes/
