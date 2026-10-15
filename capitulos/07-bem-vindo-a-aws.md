# Bem-vindo à AWS

Na Parte I, o Rangô saiu do `localhost` e aprendeu o que existe entre o notebook e o usuário: IPs, portas e NAT, DNS e TLS, servidores, containers e proxy reverso, balanceadores e cache, filas com idempotência e, no capítulo anterior, backups testados, RPO e RTO, réplicas, pipeline e observabilidade. Tudo isso rodou na sua máquina, dentro do Docker Compose. A Parte II começa agora e responde à pergunta que ficou pendurada: onde essa infraestrutura vai existir de verdade, e quem vai mantê-la. A resposta deste livro é a AWS, e o primeiro passo é abrir a conta sem deixar uma porta aberta para a fatura.

## Onde o Rangô vai morar

Volte à lista que o capítulo 6 deixou na mesa. Um Postgres com réplica em outro prédio e arquivamento contínuo de WAL. Backups guardados longe dos servidores. Máquinas recriadas a partir de código. Logs e métricas centralizados, com alertas. Um cofre de segredos. Um destino para o pipeline. E, desde o capítulo 1, um computador com IP público ligado o tempo todo.

Você tem três caminhos.

O primeiro é comprar hardware e alugar espaço num data center. O investimento sai antes do primeiro pedido, e a capacidade é decidida com meses de antecedência. Ninguém compra um servidor às 21h14 de uma quinta-feira porque o Rangô apareceu na TV.

O segundo é alugar um servidor virtual num provedor de VPS. Sai barato e resolve o IP público, mas o Postgres replicado, os backups em outra cidade, o balanceador e o cofre de segredos continuam sendo trabalho seu, montado à mão.

O terceiro é a nuvem. Você aluga cada peça da lista como um serviço, por hora ou por uso, e cria tudo por uma API. O Postgres com réplica vira um formulário, e mais adiante algumas linhas de código.

Esse terceiro caminho tem um custo que não aparece na propaganda. Considere uma situação hipotética, mas comum. Uma desenvolvedora cria um cluster de banco de dados para testar numa sexta à tarde e esquece dele. O cluster fica ligado o mês inteiro, junto com um NAT Gateway que ela nem sabia ter criado. No dia 3 do mês seguinte, a fatura chega com quatro dígitos em dólar. Ninguém foi hackeado. A nuvem fez o que prometia: cobrou pelo que estava ligado.

A pergunta deste capítulo, então, tem duas metades. Onde o Rangô vai morar? E como garantir que você seja avisado antes de a conta virar um susto?

## O que a nuvem vende

Tirando o folheto, computação em nuvem é isto: alguém com data centers enormes aluga pedaços deles para você, por uma API, cobrando pelo uso. Três características separam isso de alugar um servidor tradicional.

A primeira é o autosserviço. Você cria um servidor ou uma fila com uma chamada de API, em minutos, sem falar com ninguém. O console, a CLI e as ferramentas de infraestrutura como código são clientes dessa mesma API: tudo que você clica no console vira uma requisição HTTP assinada para um *endpoint* da AWS.

A segunda é a cobrança por uso: servidor por segundo ou hora, armazenamento por gigabyte por mês, tráfego por gigabyte que sai para a internet. Você paga pelo que deixou ligado.

A terceira é a elasticidade. Os 21 processos que o capítulo 4 calculou para o pico da TV sobem em minutos e são desligados quando o programa acaba.

Você vai ouvir as siglas IaaS (máquinas virtuais, discos e redes, como o Amazon EC2) e PaaS (um lugar para rodar código ou banco sem administrar o sistema operacional, como o Amazon RDS). A fronteira entre elas é borrada. A pergunta prática é outra: neste serviço, o que fica comigo?

## O mapa da Parte II

A AWS tem mais de duzentos serviços. O Rangô vai usar uns vinte. A tabela abaixo liga o que a Parte I mostrou que precisa existir ao serviço que vamos usar e ao capítulo em que ele aparece.

| O que precisa existir | Serviço AWS | Capítulo |
|---|---|---|
| Identidades e permissões | IAM, IAM Identity Center | 8 |
| Computador com IP público | Amazon EC2 | 9 |
| Rede, subnets públicas e privadas, NAT | Amazon VPC | 10 |
| Fotos dos pratos e backups | Amazon S3 | 11 |
| Postgres com réplica e PITR, Redis | Amazon RDS, Amazon ElastiCache | 12 |
| Balanceador e escala horizontal | Elastic Load Balancing, EC2 Auto Scaling | 13 |
| DNS, certificados, CDN | Amazon Route 53, AWS Certificate Manager, Amazon CloudFront | 14 |
| Infraestrutura como código | AWS CloudFormation, AWS CDK | 15 |
| Cofre de segredos | Parameter Store, AWS Secrets Manager, AWS KMS | 16 |
| Containers e orquestração | Amazon ECR, Amazon ECS, AWS Fargate | 17 |
| Pipeline de deploy | GitHub Actions com OIDC | 18 |
| Serverless | AWS Lambda, Amazon API Gateway | 19 |
| Banco chave-valor para dados que mudam a cada segundo | Amazon DynamoDB | 20 |
| Filas, pub/sub, eventos, fluxos com estado | Amazon SQS, Amazon SNS, Amazon EventBridge, AWS Step Functions | 21 |
| Logs, métricas, traces, alertas | Amazon CloudWatch, OpenTelemetry com AWS X-Ray | 22 |
| Auditoria, firewall, contas separadas | AWS CloudTrail, AWS WAF, Amazon GuardDuty, AWS Organizations | 23 |
| Custo sob controle | AWS Cost Explorer, AWS Budgets | 24 |

Cada linha corresponde a uma ideia que você já entende. A Parte II mostra como a AWS implementa cada uma e onde estão as letras miúdas.

## Quem cuida de quê

A primeira coisa que muda quando você aluga infraestrutura é a divisão de responsabilidades. A AWS chama isso de **modelo de responsabilidade compartilhada**, e a frase que ela usa para resumir é boa: a AWS cuida da segurança *da* nuvem; você cuida da segurança *na* nuvem.

Segurança da nuvem é o prédio, os discos destruídos ao sair de uso, o hypervisor que isola a sua máquina virtual da do vizinho, a rede física. Você não mexe em nada disso.

Segurança na nuvem é tudo o que você configura: quem acessa a conta, quais portas estão abertas, se o bucket das fotos está público, se o sistema operacional recebe atualizações, se a senha do banco está no repositório.

Uma analogia de desenvolvedor ajuda. Quando você usa o Django, o framework protege contra CSRF e escapa o HTML dos templates. Mas se você escrever uma view que devolve os pedidos de qualquer usuário sem conferir quem está logado, o framework não vai impedir. A fronteira existe, e o lado de lá é bem feito; o lado de cá é seu.

O detalhe que confunde iniciantes é que essa fronteira se move conforme o serviço:

| Quem atualiza... | EC2 (cap. 9) | RDS (cap. 12) | Lambda (cap. 19) |
|---|---|---|---|
| Hardware e data center | AWS | AWS | AWS |
| Sistema operacional | Você | AWS | AWS |
| Versão do Postgres ou do runtime | Você | Você escolhe e agenda; AWS aplica | Você escolhe o runtime |
| Código da aplicação | Você | Você | Você |
| Quem acessa, portas abertas, dados expostos | Você | Você | Você |

A última linha nunca muda de coluna. Quase todos os vazamentos famosos em nuvem caíram ali: um bucket público, uma porta aberta, uma chave de acesso publicada. O capítulo 11 traz alguns casos de buckets expostos, e o capítulo 8 começa com uma chave de acesso no GitHub.

## Regiões e zonas de disponibilidade

No capítulo 6, a réplica do Postgres precisava ficar "em outro prédio", e o backup, "em outra cidade". A AWS organiza a infraestrutura física exatamente nesses dois níveis.

Uma **Region** (região) é uma área geográfica com vários data centers, como Norte da Virgínia, Irlanda ou São Paulo. Cada região tem um código: `us-east-1` é o Norte da Virgínia, `sa-east-1` é São Paulo. As regiões são independentes entre si. Um recurso criado em `us-east-1` existe só lá, e a maioria dos serviços não copia nada para outra região, a menos que você peça.

Uma **Availability Zone** (zona de disponibilidade, ou AZ) é um ou mais data centers dentro de uma região, com energia, refrigeração e rede próprias. As AZs ficam longe o bastante umas das outras para que um incêndio não derrube duas, e perto o bastante para que a latência entre elas seja de poucos milissegundos. Os nomes são a região mais uma letra: `us-east-1a`, `sa-east-1c`.

Em outubro de 2026, a página oficial da infraestrutura global listava 39 regiões e 124 AZs, com mais duas regiões anunciadas (Arábia Saudita e Chile). Esses números crescem todo ano. São Paulo existe desde 2011 e tem três AZs.

Traduzindo para o vocabulário do capítulo 6:

- Alta disponibilidade, na AWS, quase sempre significa espalhar o sistema por **duas ou mais AZs da mesma região**. Banco primário numa AZ, réplica em outra; servidores da API divididos entre elas; balanceador nas duas.
- Recuperação de desastres contra a perda de uma região inteira significa **copiar dados para outra região**. Isso é mais caro e mais raro, e o Rangô vai tratar do assunto só para os backups.

Existem ainda as **Local Zones** (extensões de uma região perto de grandes cidades, que você pode ignorar por enquanto) e os pontos de presença do CloudFront, a CDN do capítulo 2, que entram no capítulo 14.

> **Armadilha:** o nome `us-east-1a` na sua conta pode apontar para um data center diferente do `us-east-1a` na conta de outra pessoa. A AWS embaralha os nomes por conta para distribuir a carga. Quando precisar comparar AZs entre contas, use o **AZ ID** (como `use1-az1`), que é fixo.

### Qual região escolher

Para um app brasileiro, a intuição diz São Paulo: latência menor, e alguns clientes exigem dados no Brasil. Em contrapartida, `sa-east-1` costuma ter preços mais altos que as regiões dos Estados Unidos para os mesmos serviços, e alguns serviços e tipos de máquina chegam lá mais tarde.

Os exemplos deste livro usam `us-east-1` por três motivos práticos. É a região padrão de quase toda a documentação, então os exemplos que você encontrar por aí vão bater com os daqui. Alguns recursos globais vivem só nela: as métricas de cobrança, que você vai usar daqui a pouco, e os certificados do ACM usados pelo CloudFront, que aparecem no capítulo 14. E ela costuma ser a primeira a receber serviços novos.

Quando latência ou custo pesarem para o leitor brasileiro, o livro avisa. Na sua empresa, a decisão depende de onde estão os usuários, de exigências legais sobre os dados e da diferença de preço.

> **Na vida real:** `us-east-1` é a região mais antiga e mais usada, e seus incidentes têm alcance enorme. Entre 19 e 20 de outubro de 2025, um defeito latente no sistema que gerencia o DNS do Amazon DynamoDB deixou o endpoint do serviço sem resolução em `us-east-1`. Outros serviços da AWS caíram em cascata, e a criação de instâncias EC2 falhou por horas. Usar `us-east-1` é razoável; supor que ela nunca cai, não.

## Mão na massa: a conta do Rangô

Hora de abrir a conta. Separe uns 40 minutos, um cartão de crédito internacional e o celular.

### Antes de clicar em "Criar conta"

Três decisões merecem um minuto de reflexão antes do cadastro.

**O e-mail.** O e-mail da conta vira o login do usuário com mais permissões que existe nela. Não use o seu e-mail pessoal nem o seu e-mail corporativo individual. Use uma lista ou um alias que mais de uma pessoa da empresa receba, como `aws-root@rango.com.br`. Se você sair do Rangô, ou se a sua caixa de entrada for comprometida, a conta não vai junto. Se você está só estudando, um alias do seu e-mail pessoal (`voce+aws@gmail.com`) já resolve o problema de misturar as mensagens.

**O cartão.** A AWS cobra em dólar, o que significa compra internacional, com câmbio e IOF. Um cartão virtual com limite baixo protege enquanto você aprende.

**O nome da conta.** Algo como `rango-estudos`. No capítulo 23, o Rangô vai ter várias contas, e nomes claros ajudam desde já.

### Criando a conta

Acesse `https://aws.amazon.com/` e clique no botão de criar conta. O cadastro pede, nesta ordem aproximada (a tela muda de tempos em tempos): e-mail e nome da conta, um código de verificação enviado ao e-mail, a senha do root user, dados de contato, dados de pagamento, verificação por telefone e a escolha do plano de suporte. Escolha o plano **Basic**, que é gratuito. Os planos pagos de suporte servem para empresas com produção crítica e não fazem falta agora.

No meio desse processo aparece uma escolha nova, que vale uma seção própria.

### Free plan ou Paid plan

O *free tier* da AWS mudou em julho de 2025. Para contas criadas a partir de 15 de julho de 2025, existem dois planos:

| | Free plan | Paid plan |
|---|---|---|
| Créditos | Até US$ 200 (US$ 100 no cadastro, até US$ 100 por atividades no painel "Explore AWS") | Os mesmos créditos |
| Serviços | Um subconjunto | Todos |
| Cobrança | Nenhuma enquanto estiver nesse plano | Uso além dos créditos é cobrado no preço normal |
| Fim | 6 meses após a criação ou quando os créditos acabarem, o que vier primeiro | Créditos restantes têm validade; o uso continua |
| Volta | Pode migrar para o Paid a qualquer momento | Não volta para o Free |

O Free plan é uma caixa de areia. Nada é cobrado, e em troca nem todos os serviços estão liberados: ficam de fora os que consumiriam os créditos rápido demais e os que envolvem compra de hardware. Quando o plano acaba, a conta é suspensa. A AWS guarda os seus dados por 90 dias; se você migrar para o Paid plan nesse prazo, recupera o acesso. Depois disso, a conta e tudo dentro dela são apagados.

O Paid plan é a conta normal da AWS, com os créditos abatendo a fatura até acabarem ou expirarem. A própria página de perguntas frequentes da AWS dá prazos diferentes para a validade dos créditos em lugares diferentes, então confira a regra que vale para a sua conta no console de Billing and Cost Management, na área de créditos.

Qual escolher para acompanhar este livro? Se você vai estudar com calma, comece no Free plan. Os capítulos 8 e 9 cabem bem nele. A partir do 10, o NAT Gateway, os interface endpoints e o RDS consomem os créditos depressa, e alguns serviços que o Rangô usa podem estar fora do subconjunto liberado, e aí a migração para o Paid plan é um clique, sem volta. Se você está montando a conta de uma empresa, escolha o Paid plan desde o início.

> **Armadilha:** ouvir falar em "750 horas grátis por mês durante 12 meses" e confiar nisso. Esse era o modelo antigo, e muitos tutoriais ainda o descrevem. As regras mudaram em 2025. Para saber o que vale para a sua conta, a fonte é o console de Billing and Cost Management, e não um vídeo de 2023.

Quando o cadastro terminar, você entra no console pela primeira vez. Repare no canto superior direito: o nome da conta, um seletor de região e um número de 12 dígitos, o **account ID**. Nos exemplos do livro ele aparece como `123456789012`, o número fictício que a própria documentação da AWS usa.

### O root user

O login que você acabou de usar é o **root user**. Ele é a identidade criada junto com a conta, e tem acesso total e irrestrito a tudo. Pense no `postgres` do seu banco local, o superusuário que ignora qualquer `GRANT`, multiplicado pelo cartão de crédito: o root pode criar qualquer recurso, apagar qualquer recurso, trocar o e-mail da conta, mudar o plano de suporte e fechar a conta.

No capítulo 8 você vai entender por que as permissões normais da AWS não conseguem limitar o root e como criar identidades para o dia a dia. Por enquanto, as regras são três:

1. Proteger o root com MFA, agora.
2. Nunca criar uma chave de acesso para o root.
3. Usar o root só para as poucas tarefas que exigem o root. Hoje, isso inclui o que vem a seguir.

### MFA no root

MFA (autenticação multifator) exige algo além da senha para entrar: um código de um aplicativo ou a confirmação de um dispositivo. Desde junho de 2025, a AWS exige MFA no root user de todos os tipos de conta. Em uma conta nova, você provavelmente vai ser conduzido a configurá-lo logo no primeiro acesso. Se não for, faça agora:

1. Clique no nome da conta, no canto superior direito, e depois em **Security credentials**.
2. Na seção **Multi-factor authentication (MFA)**, clique em **Assign MFA device**.
3. Dê um nome ao dispositivo, como `root-passkey-notebook`.
4. Escolha o tipo e siga as instruções da tela.

As opções são *passkey* ou chave de segurança (uma YubiKey, ou a passkey do gerenciador de senhas), aplicativo autenticador com códigos de seis dígitos e token físico. Prefira passkey ou chave de segurança. Elas seguem o padrão FIDO, que amarra a autenticação ao domínio real da AWS, então uma página falsa que imita o console não consegue reaproveitar a resposta. Um código de seis dígitos pode ser digitado numa página falsa e repassado ao site real em segundos. SMS deixou de ser opção.

Cadastre **pelo menos dois** dispositivos. O root e cada usuário IAM aceitam até oito, e qualquer um deles basta para entrar. Se o único dispositivo for o celular, e o celular cair no rio, recuperar o acesso ao root vira um processo com o suporte da AWS que pode levar dias. Uma chave física guardada no cofre da empresa, ou uma segunda passkey em outro gerenciador, evita isso.

O MFA do root só pode ser configurado pelo console, nunca pela CLI ou pela API. Se alguém já tivesse credenciais de API do root, o MFA chegaria tarde demais.

Na mesma página, a seção **Access keys** de uma conta nova está vazia. Deixe assim.

Duas configurações rápidas na página **Account** (no menu do nome da conta). Preencha os **Alternate contacts** de cobrança, operações e segurança, os endereços para onde a AWS escreve quando detecta algo estranho. E ative **IAM user and role access to Billing information**; sem isso, só o root vê a fatura, e o capítulo 8 vai criar outras identidades.

### O alarme de cobrança, antes de tudo

Esta é a promessa do capítulo anterior. Antes de criar qualquer servidor, você vai configurar o aviso que chega quando a fatura passa de um valor que você escolheu.

A AWS publica uma métrica chamada `EstimatedCharges` no Amazon CloudWatch, o serviço de métricas e alarmes que o capítulo 22 vai detalhar. Ela representa o total estimado da fatura do mês corrente, somando todas as regiões. Um **alarme do CloudWatch** observa uma métrica e muda de estado quando ela cruza um limite; quando isso acontece, ele publica uma mensagem num tópico do Amazon SNS, o serviço de pub/sub da AWS (o mesmo conceito do capítulo 5), que entrega a mensagem por e-mail.

São três passos.

**Passo 1: habilitar as métricas de cobrança.** Elas vêm desligadas.

1. Abra o console **Billing and Cost Management**.
2. No menu lateral, clique em **Billing Preferences**.
3. Em **Alert preferences**, clique em **Edit**.
4. Marque **Receive CloudWatch Billing Alerts** e clique em **Save preferences**.

Essa coleta não pode ser desligada depois, e os primeiros dados levam uns 15 minutos para aparecer. Só o root ou uma identidade com permissão para ver a cobrança consegue fazer isso.

**Passo 2: trocar a região para Norte da Virgínia.** No seletor de região, no canto superior direito, escolha **US East (N. Virginia) us-east-1**. As métricas de cobrança existem só nessa região, mesmo que todos os seus recursos estejam em São Paulo. Se você tentar criar o alarme em `sa-east-1`, a métrica simplesmente não aparece na lista.

**Passo 3: criar o alarme.**

1. Abra o console do **CloudWatch** e vá em **Alarms**, **All alarms**, **Create alarm**.
2. Clique em **Select metric**, depois em **Billing**, **Total Estimated Charge**. Marque a linha com a moeda **USD** e clique em **Select metric**.
3. Configure a estatística como **Maximum** e o período como **6 hours**.
4. Em **Conditions**, escolha **Static**, **Greater** e digite o limite. Para quem está estudando, `10` (dólares) é um bom começo. Para a conta de uma empresa, use um valor um pouco acima do gasto mensal esperado.
5. Em **Additional configuration**, deixe **Datapoints to alarm** em `1 out of 1` e o tratamento de dados ausentes em **Treat missing data as missing**.
6. Em **Notification**, escolha **In alarm**, **Create new topic**. Dê ao tópico o nome `alertas-cobranca` e informe o e-mail que deve receber o aviso (o alias da empresa, de preferência). Clique em **Create topic**.
7. Nomeie o alarme como `cobranca-acima-de-10-usd` e conclua.

Agora abra a caixa de entrada. Chegou um e-mail com o assunto "AWS Notification - Subscription Confirmation". Clique em **Confirm subscription**. Sem essa confirmação, o SNS não entrega nada, e o alarme dispara para o vazio. Esse é o erro mais comum desta configuração inteira.

Na lista de alarmes, o seu deve aparecer com o estado **Insufficient data** nas primeiras horas, até a métrica ter dados. Depois, **OK**.

Esse alarme compara o valor **atual** da fatura estimada com o limite, sem projeção: se um recurso caro começou a rodar hoje cedo, ele só dispara quando a soma passar de US$ 10. A métrica é atualizada algumas vezes por dia, e o alarme só avisa; nada é desligado. Se a fatura já estiver acima do limite na criação, ele vai direto para **ALARM**.

### Um orçamento como segunda rede

O AWS Budgets complementa o alarme com o que falta a ele: previsão. Um *budget* compara o gasto real e o gasto **projetado** para o mês com um valor que você define. Criar budgets que só monitoram e notificam é gratuito.

1. No console **Billing and Cost Management**, vá em **Budgets** e clique em **Create budget**.
2. Escolha **Use a template** e o modelo **Monthly cost budget**.
3. Nomeie como `rango-mensal`, defina o valor (por exemplo, US$ 20) e informe o e-mail.
4. Crie.

O modelo mensal já vem com alertas para quando o gasto real passar de 85% e 100% do valor e para quando a previsão passar de 100%. Se a previsão do meio do mês disser que você vai fechar em US$ 60, o aviso chega no dia 15, e não no dia 3 do mês seguinte.

Enquanto estuda, crie também um budget com o modelo **Zero spend budget**, que avisa assim que o primeiro centavo for cobrado.

No Paid plan, o console oferece ainda um limite mensal de gasto por projeto, a partir de US$ 20, que pausa o projeto ao ser atingido. O que conta como "projeto" ainda é pouco documentado; leia a explicação no console antes de confiar nele.

## Console, CLI e CloudShell

O console é ótimo para aprender e para olhar. Você vê os recursos, os gráficos e as opções disponíveis, e o formulário de criação ensina quais parâmetros existem. Para fazer a mesma coisa duas vezes, ele é péssimo. Quantos cliques o alarme de cobrança exigiu? Repita isso em três contas, ou tente lembrar daqui a seis meses qual opção você marcou no passo 5.

A AWS CLI resolve isso. Ela é um programa de linha de comando que transforma cada operação da API num comando. O que você clicou no console vira uma linha que pode ir para um script, para um README ou para o pipeline. No capítulo 15, o CDK vai dar o passo seguinte, descrever a infraestrutura inteira em Python, mas a CLI continua sendo a ferramenta do dia a dia para consultar, testar e consertar.

Existe um jeito de usar a CLI sem instalar nada e sem configurar credenciais: o **AWS CloudShell**. É um terminal Linux no navegador, aberto a partir do console, com a CLI já instalada e autenticada com a mesma identidade que está logada no console. O uso do CloudShell não tem cobrança extra, e cada região guarda um diretório pessoal persistente de 1 GB.

### Primeiros comandos no CloudShell

Com a região ainda em `us-east-1`, clique no ícone do CloudShell (um quadradinho com `>_`, na barra superior) e espere o terminal abrir. O primeiro comando responde à pergunta "quem sou eu?":

```bash
aws sts get-caller-identity
```

```json
{
    "UserId": "123456789012",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:root"
}
```

Repare no `Arn`, o identificador único de um recurso na AWS. Ele termina em `root`. Você está usando o superusuário, e esse incômodo é proposital: o capítulo 8 acaba com ele.

Agora confira as zonas de disponibilidade de São Paulo:

```bash
aws ec2 describe-availability-zones \
  --region sa-east-1 \
  --query 'AvailabilityZones[].[ZoneName,ZoneId,State]' \
  --output table
```

```
-----------------------------------------------
|          DescribeAvailabilityZones          |
+-------------+-------------+-----------------+
|  sa-east-1a |  sae1-az1   |  available      |
|  sa-east-1b |  sae1-az2   |  available      |
|  sa-east-1c |  sae1-az3   |  available      |
+-------------+-------------+-----------------+
```

Na sua conta, a associação entre nome e ID pode ser outra. O `--query` usa JMESPath, uma linguagem de consulta para JSON que funciona como uma list comprehension aplicada à resposta: `AvailabilityZones[].[ZoneName,ZoneId,State]` equivale a `[[z["ZoneName"], z["ZoneId"], z["State"]] for z in resposta["AvailabilityZones"]]`.

Por fim, confira o alarme que você criou no console:

```bash
aws cloudwatch describe-alarms \
  --alarm-names cobranca-acima-de-10-usd \
  --region us-east-1 \
  --query 'MetricAlarms[].[AlarmName,StateValue,Threshold]' \
  --output text
```

```
cobranca-acima-de-10-usd	OK	10.0
```

Se aparecer `INSUFFICIENT_DATA`, a métrica ainda não chegou; espere algumas horas.

Para comparar com os sete passos do console, veja o mesmo alarme criado só pela CLI. Não precisa rodar, porque o seu já existe; o objetivo é ver como cada campo do formulário vira um parâmetro:

```bash
aws sns create-topic --name alertas-cobranca --region us-east-1

aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:123456789012:alertas-cobranca \
  --protocol email \
  --notification-endpoint aws-root@rango.com.br \
  --region us-east-1

aws cloudwatch put-metric-alarm \
  --alarm-name cobranca-acima-de-10-usd \
  --namespace AWS/Billing \
  --metric-name EstimatedCharges \
  --dimensions Name=Currency,Value=USD \
  --statistic Maximum \
  --period 21600 \
  --evaluation-periods 1 \
  --threshold 10 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data missing \
  --alarm-actions arn:aws:sns:us-east-1:123456789012:alertas-cobranca \
  --region us-east-1
```

O período de "6 hours" do console vira `--period 21600`, em segundos. O namespace que o console mostrava como "Billing" se chama `AWS/Billing` na API. Troque o account ID e o e-mail pelos seus se algum dia precisar recriar o alarme. Esse bloco é a primeira peça de infraestrutura do Rangô escrita como texto, e você pode guardá-lo no repositório.

### A CLI no seu computador

O trabalho diário acontece no seu terminal, junto do código do Rangô. Instale a AWS CLI versão 2. No Linux (x86_64):

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

No macOS:

```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
```

No Windows, baixe e execute o instalador `https://awscli.amazonaws.com/AWSCLIV2.msi`. Em computadores ARM com Linux, o pacote é o `awscli-exe-linux-aarch64.zip`. Confira:

```bash
aws --version
```

```
aws-cli/2.x.y Python/3.x.y Linux/6.x exe/x86_64
```

O número exato da versão vai variar; o que importa é o `aws-cli/2`. A CLI v2 traz o próprio Python embutido e não interfere no Python do Rangô.

> **Armadilha:** `pip install awscli` instala a CLI **versão 1**, antiga, que pode conflitar com as dependências do projeto. Se `aws --version` mostrar `aws-cli/1.`, rode `pip uninstall awscli` e use o instalador oficial.

Agora repita a pergunta do CloudShell, desta vez no seu terminal:

```bash
aws sts get-caller-identity
```

```
Unable to locate credentials. You can configure credentials by running "aws configure".
```

O CloudShell sabia quem você era porque herdava a sessão do console. O seu terminal não sabe. E a mensagem de erro sugere um caminho que parece óbvio. Guarde essa sugestão; ela é o assunto da ponte.

## Armadilhas e casos reais

**O recurso esquecido em outra região.** O console mostra os recursos de uma região de cada vez. Você cria um servidor em `sa-east-1` para testar latência, troca o seletor para `us-east-1` e esquece que ele existe. Ele não aparece na tela, mas aparece na fatura. O alarme de cobrança soma todas as regiões, e é exatamente por isso que ele vem antes de tudo. Para encontrar o culpado, a página **Bills** do Billing and Cost Management detalha o gasto por serviço e por região.

**O IP público que custa dinheiro.** Desde fevereiro de 2024, todo endereço IPv4 público custa US$ 0,005 por hora, pouco mais de US$ 3,60 por mês (referência de outubro de 2026 em `us-east-1`; confira a página oficial), esteja ele anexado a um servidor ou parado. Load balancers e NAT Gateways também usam IPs públicos cobrados.

**A conta do Free plan que some.** Seis meses depois da criação, ou quando os créditos acabam, a conta do Free plan é suspensa. Os avisos chegam por e-mail. Se o e-mail da conta for uma caixa que ninguém lê, os 90 dias passam, e a conta e os dados somem.

**A métrica que não aparece.** Se **Billing** não aparece na lista de métricas, a região do console provavelmente está errada ou a coleta foi habilitada há menos de 15 minutos. Contas da AWS Partner Network não publicam essas métricas; nelas, use o Budgets.

**O e-mail da pessoa que saiu.** Uma conta criada com o e-mail pessoal do primeiro desenvolvedor da empresa vira refém quando essa pessoa vai embora. Recuperar o root sem acesso ao e-mail exige provar a posse da conta ao suporte da AWS.

## Resumo

- Nuvem é infraestrutura alugada por API e cobrada pelo que fica ligado.
- A AWS cuida da segurança *da* nuvem; você, da segurança *na* nuvem. Acesso, portas e dados expostos são sempre seus.
- Alta disponibilidade usa várias AZs; desastre regional pede outra região. O livro usa `us-east-1`.
- Contas novas escolhem entre Free plan (sem cobrança, limitado, expira) e Paid plan, com até US$ 200 em créditos.
- O root user tem poder total. MFA com passkey ou chave de segurança, pelo menos dois dispositivos, nenhuma chave de acesso.
- O alarme de cobrança usa a métrica `EstimatedCharges`, existe só em `us-east-1`, avisa sobre o valor atual e depende de uma assinatura SNS confirmada. O AWS Budgets acrescenta a previsão.
- Console para aprender e olhar; CLI para repetir; CloudShell para usar a CLI sem configurar nada.

## Ponte: a sugestão perigosa

O Rangô agora tem uma casa: uma conta na AWS com o root protegido, um alarme de cobrança vigiando a fatura e a CLI instalada no seu notebook. Só que a CLI não sabe quem você é. A mensagem de erro sugeriu `aws configure`, e esse comando pede um *Access Key ID* e um *Secret Access Key*. O caminho mais curto para conseguir esse par é voltar à página **Security credentials** do root e clicar em **Create access key**.

Muita gente faz isso. Copia as duas strings para o `~/.aws/credentials`, depois para um `.env`, depois para um script que vai parar num commit. E há robôs varrendo cada push público do GitHub atrás desse formato de chave. No próximo capítulo, você vai ver o que acontece com uma conta cuja chave vazou, entender o IAM por dentro e configurar a CLI do jeito certo, com login por SSO e credenciais temporárias, sem nenhuma chave permanente no disco.

## Referências

- AWS Free Tier, perguntas frequentes: https://aws.amazon.com/free/faqs/
- Anúncio do novo Free Tier (julho de 2025): https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/
- Criar um alarme de cobrança no CloudWatch: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/monitor_estimated_charges_with_cloudwatch.html
- Preços do AWS Budgets: https://aws.amazon.com/aws-cost-management/aws-budgets/pricing
- MFA obrigatório para root em todos os tipos de conta (junho de 2025): https://aws.amazon.com/about-aws/whats-new/2025/06/aws-iam-mfa-root-users-across-all-account-types
- MFA no IAM: https://docs.aws.amazon.com/IAM/latest/UserGuide/Using_ManagingMFA.html
- Regiões e zonas de disponibilidade: https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
- Cobrança de IPv4 público: https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights
- Resumo do incidente do DynamoDB em `us-east-1` (outubro de 2025): https://aws.amazon.com/message/101925/
- Modelo de responsabilidade compartilhada: https://aws.amazon.com/compliance/shared-responsibility-model/
- Instalar a AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
- AWS CloudShell: https://docs.aws.amazon.com/cloudshell/latest/userguide/welcome.html
