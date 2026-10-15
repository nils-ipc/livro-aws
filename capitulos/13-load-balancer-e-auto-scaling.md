# Load Balancer e Auto Scaling

No capítulo anterior, os pedidos foram para o RDS e o Valkey saiu da EC2 para o ElastiCache Serverless. Com as fotos no S3 desde o capítulo 11, a `rango-api-01` ficou só com o código, o Nginx e o Uvicorn: se ela sumir, nada se perde. Terminamos com o banco desligado, guardado no snapshot `rango-db-final-cap12`, e com uma notícia: o especial de TV com a Cantina da Nona vai ao ar no sábado à noite.

## O plano das dez instâncias

Quinta-feira, você abre uma planilha e faz a conta do capítulo 4. Na última vez em que a Cantina da Nona apareceu na TV, o tráfego foi de 5 para 250 requisições por segundo em poucos minutos. Cada instância `t3.micro` roda dois workers do Uvicorn, e cada worker atende umas 12 requisições por segundo. Dez instâncias, com folga.

O primeiro plano que vem à cabeça é subir dez `rango-api` à mão no sábado às 20h, com o comando do capítulo 10. Vale a pena seguir esse plano no papel até o fim da noite, porque cada passo dele quebra em algum lugar.

Às 20h, você tem dez IPs públicos, e o capítulo 4 já descartou colocar dez registros A no DNS: quem guardou o IP de uma instância travada continua mandando pedidos para ela até o TTL vencer. Às 21h20, a instância 7 fica sem memória. Alguém precisa perceber, tirar ela da lista e subir outra. Esse alguém é você, na sala, com o programa passando ao fundo.

Às 21h40, o apresentador repete o cupom e o tráfego dobra. Você sobe mais cinco instâncias, cada uma levando uns três minutos para ficar pronta. À meia-noite, o tráfego volta para 5 requisições por segundo, e quinze instâncias continuam ligadas até a segunda-feira, junto com a fatura.

O que falta tem três partes bem separadas: um endereço único que distribui as requisições e sabe quem está saudável, uma receita de como criar uma instância do Rangô sem ninguém entrar nela, e um processo que olha a carga e decide quantas instâncias precisam existir. A AWS tem um serviço para cada uma.

## As peças da AWS

### Elastic Load Balancing

O Elastic Load Balancing é a família de balanceadores gerenciados da AWS. Dela, dois tipos interessam aqui, e eles correspondem às camadas que você viu no capítulo 4. O **Application Load Balancer** (ALB) trabalha na camada 7: lê o HTTP, sabe o path e o cabeçalho `Host`, e pode decidir para onde mandar cada requisição com base neles. O **Network Load Balancer** (NLB) trabalha na camada 4: repassa conexões TCP e UDP sem abrir o conteúdo, com latência menor e IPs fixos por AZ. Existe ainda o Gateway Load Balancer, para appliances de rede, e o Classic Load Balancer, a geração antiga, que você só vai encontrar em contas legadas.

Para uma API HTTP como a do Rangô, a escolha é o ALB.

O ALB tem uma característica que surpreende quem vem do Nginx do capítulo 4: por trás dele existe um conjunto de nós que a AWS mantém em cada AZ onde você o habilita, e que cresce e encolhe conforme o tráfego. Por isso o ALB recebe um **nome DNS**, algo como `rango-alb-1234567890.us-east-1.elb.amazonaws.com`, e os IPs por trás desse nome mudam com o tempo. A regra é a mesma do endpoint do RDS no capítulo 12: a aplicação e o DNS apontam para o nome, nunca para o IP.

Por dentro, o ALB tem três conceitos encaixados:

- O **listener** escuta uma porta e um protocolo (HTTP na 80, HTTPS na 443).
- As **regras** do listener olham a requisição e escolhem uma ação. Se o path começa com `/admin`, manda para um lugar; se o `Host` é `api.rango.com.br`, para outro. Sempre existe uma ação padrão.
- O **target group** é a lista de destinos, com o seu próprio health check. É o bloco `upstream rango_api` do Nginx, só que com API, métricas e registro automático.

Se você pensar no `APIRouter` do FastAPI, o listener é a aplicação, as regras são os decoradores de rota, e o target group é a função que atende. O Rangô vai usar só a ação padrão, mandando tudo para um único target group.

O algoritmo padrão do target group é o round robin. Dá para trocar para *least outstanding requests*, que escolhe o alvo com menos requisições em andamento, útil quando algumas rotas demoram muito mais que outras, mudando o atributo `load_balancing.algorithm.type` para `least_outstanding_requests`.

### Health checks e draining

O target group pergunta periodicamente a cada alvo se ele está bem, com uma requisição HTTP para um path que você escolhe. É o health check ativo do capítulo 4. Os valores padrão, para alvos do tipo instância, são um intervalo de 30 segundos, timeout de 5 segundos e cinco respostas boas seguidas para considerar um alvo saudável. Com esses números, uma instância nova leva dois minutos e meio até receber a primeira requisição. Para o Rangô, vamos usar 10 segundos de intervalo e duas checagens, o que cai para uns 20 segundos.

O path é o `/health` que existe desde o capítulo 1, e ele continua raso de propósito. O capítulo 4 mostrou o que acontece com um health check que testa o banco: um soluço do Postgres faz todos os alvos falharem juntos, e o balanceador tira da roda as instâncias que estavam funcionando.

Quando todos os alvos estão doentes, o ALB faz algo que parece estranho na primeira vez: passa a mandar tráfego para todos eles. A documentação chama isso de *fail open*. A lógica é que, se tudo parece quebrado, o problema provavelmente está no health check, e mandar requisições para alvos talvez bons é melhor do que devolver erro para todo mundo.

O outro lado é a saída. Quando um alvo é removido do target group, ele entra no estado `draining`: o ALB para de mandar requisições novas, mas deixa as que estão em andamento terminarem. Esse prazo se chama *deregistration delay*, tem padrão de 300 segundos e vai de 0 a 3.600. Se não houver nenhuma requisição em aberto, a remoção termina na hora, mesmo que o console continue mostrando `draining` até o prazo acabar. Se a instância fechar a conexão antes, o cliente recebe um erro 5xx. Para uma API cujas requisições duram milissegundos, cinco minutos de espera só atrasam cada redução de capacidade, e 30 segundos bastam.

### Launch Template

A segunda peça é a receita da instância. Um **Launch Template** guarda tudo o que você passava ao `run-instances`: AMI, tipo, Security Groups, instance profile, opções de metadados, disco, tags e user data. Ele tem versões numeradas, e cada alteração cria uma versão nova, como um commit. Se o `run-instances` do capítulo 10 era um `docker run` com quinze flags, o Launch Template é o serviço no `compose.yaml`.

> **Armadilha:** Tutoriais antigos usam *launch configurations*, a versão anterior desse recurso. Contas criadas a partir de 1º de outubro de 2024 não conseguem mais criá-las por nenhum meio (console, API, CLI ou CloudFormation), e elas não recebem tipos de instância novos desde 1º de janeiro de 2023. A conta `rango-estudos` é de 2025. Se um `create-launch-configuration` falhar, é isso.

### Auto Scaling Group

A terceira peça é o **Auto Scaling Group** (ASG), do Amazon EC2 Auto Scaling. Você informa três números: mínimo, máximo e capacidade desejada. O ASG cria instâncias a partir do Launch Template até chegar à capacidade desejada, espalhando-as pelas subnets e AZs que você indicou, e registra cada uma no target group.

Daí em diante, ele fica comparando o que existe com o que deveria existir. Uma instância morreu? Ele cria outra. Alguém mudou a capacidade desejada de 2 para 4? Ele cria duas. É a reconciliação do Kubernetes que você viu no capítulo 3, aplicada a máquinas virtuais: você declara o estado, e o serviço corre atrás dele.

Para saber se uma instância morreu, o ASG precisa de um critério. Com a opção `--health-check-type ELB`, ele passa a considerar também o veredito do target group, além do estado da instância no EC2. Uma máquina ligada, mas com o Nginx travado, é marcada como doente e substituída.

Esse critério precisa de uma pausa no começo. Uma instância recém-criada ainda está iniciando o sistema e os serviços, e falharia no health check. A *health check grace period* é o tempo em que o ASG ignora o veredito do balanceador para uma instância nova. Durante esse período, só uma coisa derruba a instância: sair do estado `running` no EC2.

### Políticas de escala

Falta decidir quando a capacidade desejada muda. O EC2 Auto Scaling oferece alguns tipos de política, e dois deles resolvem o sábado do Rangô.

A **target tracking** funciona como o termostato de um ar-condicionado. Você escolhe uma métrica e um valor alvo, e o ASG cria e remove instâncias para manter a métrica perto do alvo. A métrica mais direta para uma API atrás de um ALB é `ALBRequestCountPerTarget`: quantas requisições cada instância recebeu, em média, no último minuto. Se o alvo é 600 e as instâncias estão recebendo 1.200, o ASG dobra a frota. Por baixo, ele cria alarmes no Amazon CloudWatch e os ajusta sozinho; você não mexe neles. A redução é mais conservadora que o aumento, para evitar o efeito sanfona de criar e destruir máquinas a cada minuto.

A **ação agendada** muda o mínimo, o máximo ou a capacidade desejada num horário marcado. O capítulo 4 avisou que auto scaling leva minutos e que, para um pico com hora marcada, o certo é escalar antes. O programa começa às 21h. Às 20h30, o Rangô já pode estar com quatro instâncias, e a target tracking cuida do que passar disso.
Uma instância nova não fica útil no instante em que é criada. O *default instance warmup* diz ao ASG quantos segundos esperar antes de contar as métricas dela na média do grupo. Sem isso, uma instância que acabou de subir e ainda não recebeu tráfego puxa a média para baixo, e a política pode concluir que já existem máquinas suficientes.

## O que ainda guarda estado

Antes de multiplicar o Rangô, vale repassar a lista de estado escondido do capítulo 4, agora contra o código real.

As sessões não existem no Rangô: o carrinho fica no Valkey, num hash por usuário, e qualquer instância lê o mesmo carrinho. Os uploads vão direto do navegador para o S3 com presigned URLs, e a instância só gera a URL e confere o objeto. O cache de `/restaurantes` mora no Valkey, compartilhado. As chaves de idempotência também. Os pedidos estão no RDS.

Sobram três itens menos óbvios.

O primeiro são os workers. Cada instância roda `rango-worker@restaurante` e `rango-worker@email`, e o nome do consumidor no stream é o hostname da máquina. Com várias instâncias, os workers disputam as mensagens do mesmo grupo, que é o *competing consumers* do capítulo 5. O problema aparece quando o ASG remove uma instância: as mensagens pendentes do consumidor que sumiu ficam esperando alguém que nunca mais vai voltar com aquele hostname. O `XAUTOCLAIM`, citado no capítulo 5, existe para isso, e o capítulo 21 troca o stream pelo Amazon SQS, que devolve a mensagem para a fila sozinho.

O segundo são os logs. O `journalctl -u rango-api` mostra os logs em JSON, guardados no disco da instância. Quando o ASG destrói uma máquina, os logs dela vão junto com o volume. O capítulo 22 manda os logs para o CloudWatch Logs; até lá, um erro numa instância já substituída fica sem explicação.

O terceiro é a configuração, que vamos resolver agora. Até aqui, cada servidor do Rangô foi montado à mão: deploy key, `git clone`, ambiente virtual, `api.env`, units do systemd. Nenhum ASG vai fazer isso às 21h40 por você.

E se a aplicação tivesse sessão em memória? O ALB oferece *sticky sessions* por target group, com um cookie `AWSALB` que prende o cliente a um alvo por 1 segundo a 7 dias. Se esse alvo ficar doente ou sair, o ALB escolhe outro, e a sessão em memória se perde. É o remendo do capítulo 4, útil para segurar uma aplicação legada enquanto o estado sai da memória.

## Mão na massa: o Rangô atrás de um balanceador

Pré-requisitos: AWS CLI v2 com o profile `rango-dev`, a `rango-vpc` com as quatro subnets, os Security Groups `rango-web`, `rango-db` e `rango-cache`, o subnet group `rango-db-subnets`, o parameter group `rango-pg18`, o snapshot `rango-db-final-cap12` e a role `rango-ec2` com a policy `RangoFotos`. Tudo em `us-east-1`. Para o teste de carga, o k6 instalado no seu computador.

Sobre custo: o ALB cobra por hora desde a criação, mais o uso, e cada nó dele tem um IPv4 público cobrado à parte. O banco, o cache e as instâncias também. A seção de armadilhas traz os números. No fim, tudo o que cobra por hora é desligado.

### Banco e cache de volta

Recupere as variáveis com as funções `id_subnet` e `id_sg` do capítulo 12 e acrescente as subnets públicas e o grupo do cache:

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

PUB_A=$(id_subnet rango-publica-a)
PUB_B=$(id_subnet rango-publica-b)
PRIV_A=$(id_subnet rango-privada-a)
PRIV_B=$(id_subnet rango-privada-b)
SG_WEB=$(id_sg rango-web)
SG_DB=$(id_sg rango-db)
SG_CACHE=$(id_sg rango-cache)
```

O banco volta do snapshot, com o mesmo identificador:

```bash
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier rango-db \
  --db-snapshot-identifier rango-db-final-cap12 \
  --db-instance-class db.t4g.micro \
  --db-subnet-group-name rango-db-subnets \
  --vpc-security-group-ids "$SG_DB" \
  --db-parameter-group-name rango-pg18 \
  --no-publicly-accessible \
  --no-multi-az \
  --deletion-protection \
  --tags Key=Projeto,Value=rango \
  --query "DBInstance.DBInstanceStatus" --output text

aws rds wait db-instance-available --db-instance-identifier rango-db

aws rds modify-db-instance --db-instance-identifier rango-db \
  --backup-retention-period 7 --max-allocated-storage 100 --apply-immediately
```

Como o identificador é o mesmo, o endpoint também é: `rango-db.c1abcd2efgh3.us-east-1.rds.amazonaws.com`. O sufixo depende da conta e da região, e o `DATABASE_URL` do capítulo 12 continua valendo. O usuário `rango`, a senha dele e os três pedidos de teste vieram no snapshot. O `modify-db-instance` garante a retenção de backup e o teto de disco que o capítulo 12 tinha configurado.

O cache serverless é criado com o mesmo comando do capítulo 12. Anote o endpoint novo, porque ele muda a cada criação:

```bash
aws elasticache create-serverless-cache \
  --serverless-cache-name rango-cache \
  --engine valkey \
  --subnet-ids "$PRIV_A" "$PRIV_B" \
  --security-group-ids "$SG_CACHE" \
  --cache-usage-limits 'DataStorage={Maximum=1,Unit=GB},ECPUPerSecond={Maximum=5000}' \
  --tags Key=Projeto,Value=rango
```

### Duas mudanças no repositório

O capítulo 12 deixou duas pendências, e o ASG torna as duas urgentes.

A primeira é o `valkey` no `infra/ec2/user-data.sh`. As instâncias novas não precisam dele. As duas primeiras linhas de comando do script ficam assim:

```bash
dnf install -y nginx git python3.12 python3.12-pip
systemctl enable --now nginx
```

A segunda é o pool de conexões. No failover do capítulo 12, a API devolveu `500` porque o pool entregou conexões que tinham morrido com a primária antiga. Num grupo com seis instâncias, isso vira `500` em seis lugares ao mesmo tempo. O `psycopg_pool` a partir da versão 3.2 aceita uma função que testa a conexão antes de entregá-la. Em `backend/app/banco.py`:

```python
pool = ConnectionPool(
    os.environ["DATABASE_URL"],
    min_size=1,
    max_size=5,
    kwargs={"row_factory": dict_row},
    check=ConnectionPool.check_connection,
    open=True,
)
```

O `check_connection` faz uma ida e volta ao banco a cada empréstimo, coisa de fração de milissegundo dentro da VPC, e troca a conexão se ela estiver morta. Uma conexão que cai no meio de uma consulta ainda gera erro: nas leituras, uma retentativa com o backoff do capítulo 5 resolve; no `INSERT` do pedido, a retentativa fica com o cliente, que já manda o `Idempotency-Key`.

Faça o commit e o push dessas duas mudanças.

### A imagem do Rangô

Como uma instância criada pelo ASG ganha código, dependências e configuração? Existem dois caminhos. No primeiro, o user data faz tudo a cada boot: instala pacotes, baixa o código, monta o ambiente. No segundo, você monta uma máquina uma vez, tira uma AMI dela e o ASG cria todas as instâncias a partir dessa imagem. O mercado chama a segunda de *golden AMI*.

O Rangô vai pela AMI. Uma instância que nasce pronta fica saudável em segundos, e no meio de um pico cada minuto de boot pesa. Além disso, as instâncias do ASG vão para as subnets privadas, sem NAT Gateway: não há como rodar `dnf install` nem `git clone` no boot. É a imagem Docker do capítulo 3 aplicada à máquina inteira.

Suba uma instância de montagem na subnet pública, com o comando do capítulo 10, trocando o nome para `rango-base` e guardando o ID em `BASE_ID`. Nela, repita as seções "Trazendo o código" e "Configuração e serviços" do capítulo 9, com duas diferenças.

As units do systemd não dependem mais do Valkey. Depois de criá-las:

```bash
sudo sed -i 's/ valkey.service//' \
  /etc/systemd/system/rango-api.service \
  /etc/systemd/system/rango-worker@.service
sudo systemctl daemon-reload
```

E o `/etc/rango/api.env` (editado com `sudoedit`) recebe a configuração completa: a do capítulo 12, o endpoint novo do cache e as variáveis de fotos do capítulo 11, que até agora só existiam no Compose. Troque a conta e o endpoint do cache pelos seus:

```bash
REDIS_URL=rediss://rango-cache-d4e5f6.serverless.use1.cache.amazonaws.com:6379
CORS_ORIGINS=http://localhost:5173
DATABASE_URL=postgresql://rango@rango-db.c1abcd2efgh3.us-east-1.rds.amazonaws.com:5432/rango?sslmode=verify-full&sslrootcert=/etc/rango/rds-ca.pem
PGPASSWORD=a-senha-que-voce-definiu-no-password
FOTOS_BUCKET=rango-fotos-pratos-123456789012
AWS_REGION=us-east-1
```

Baixe também o `/etc/rango/rds-ca.pem`, como no capítulo 12. Teste dentro da instância, lendo um pedido que veio do snapshot:

```bash
curl -s http://127.0.0.1/pedidos/6f1c2a9e-3b4d-4e8f-9a1b-2c3d4e5f6a7b
```

```text
{"id":"6f1c2a9e-3b4d-4e8f-9a1b-2c3d4e5f6a7b","restaurante":"cantina-da-nona","total":"58.90","status":"recebido","criado_em":"2026-10-15T14:28:41.512309Z"}
```

Antes de tirar a foto da máquina, apague o que não pode ir junto. A deploy key serviu para o clone, e as instâncias do ASG nunca vão falar com o GitHub:

```bash
sudo rm -rf /opt/rango/.ssh
```

Remova a deploy key também no GitHub. Saia da sessão e, no seu terminal, crie a imagem:

```bash
AMI_ID=$(aws ec2 create-image \
  --instance-id "$BASE_ID" \
  --name rango-api-20261015 \
  --description "Rango API, cap. 13" \
  --tag-specifications \
    'ResourceType=image,Tags=[{Key=Projeto,Value=rango}]' \
    'ResourceType=snapshot,Tags=[{Key=Projeto,Value=rango}]' \
  --query ImageId --output text)

aws ec2 wait image-available --image-ids "$AMI_ID"
aws ec2 terminate-instances --instance-ids "$BASE_ID"
```

O `create-image` reinicia a instância para que o disco seja copiado num estado consistente, e leva alguns minutos. O snapshot da AMI herda a criptografia do volume.

> **Armadilha:** Esta AMI carrega o `api.env`, com a senha do banco dentro. Ela é privada da sua conta e o snapshot está criptografado, mas qualquer pessoa da conta com permissão para criar instâncias consegue subir uma cópia e ler o arquivo. Nunca torne uma AMI dessas pública nem a compartilhe com outra conta. O capítulo 16 tira a senha da imagem, e a instância passa a buscá-la no boot.

### Security Groups, e um erro de propósito

O ALB precisa de um grupo próprio, aberto para a internet na porta 80:

```bash
SG_ALB=$(aws ec2 create-security-group --vpc-id "$VPC_ID" \
  --group-name rango-alb --description "ALB do Rango, HTTP publico" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=rango-alb},{Key=Projeto,Value=rango}]' \
  --query GroupId --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0
```

E o `rango-web` deixa de aceitar a internet. Desde o capítulo 9, ele tem a porta 80 aberta para `0.0.0.0/0`. As instâncias vão para subnets privadas e nem teriam como receber esse tráfego, mas a regra não precisa existir:

```bash
aws ec2 revoke-security-group-ingress --group-id "$SG_WEB" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0
```

Falta a regra que deixa o ALB falar com as instâncias. Vamos esquecê-la por enquanto, para ver o sintoma.

### Target group e ALB

```bash
TG_ARN=$(aws elbv2 create-target-group \
  --name rango-api \
  --protocol HTTP --port 80 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-path /health \
  --health-check-interval-seconds 10 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --matcher HttpCode=200 \
  --tags Key=Projeto,Value=rango \
  --query "TargetGroups[0].TargetGroupArn" --output text)

aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30
```

A porta 80 do target group é a do Nginx em cada instância. O ALB fica nas subnets públicas, uma por AZ:

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name rango-alb \
  --type application \
  --scheme internet-facing \
  --subnets "$PUB_A" "$PUB_B" \
  --security-groups "$SG_ALB" \
  --tags Key=Projeto,Value=rango \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)

aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"

aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN"

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].DNSName" --output text)
echo "$ALB_DNS"
```

```text
rango-alb-1234567890.us-east-1.elb.amazonaws.com
```

Os nós do ALB, nas subnets públicas, recebem a requisição e abrem uma conexão nova até a instância, nas privadas, pela rota `local` da VPC. A instância dispensa IP público e os US$ 3,65 mensais dele.

### Launch Template

O Launch Template recebe a AMI e o resto do que estava no `run-instances`. Crie `infra/asg/launch-template.json` a partir das variáveis:

```bash
mkdir -p infra/asg
cat > infra/asg/launch-template.json <<EOF
{
  "ImageId": "$AMI_ID",
  "InstanceType": "t3.micro",
  "CreditSpecification": {"CpuCredits": "standard"},
  "IamInstanceProfile": {"Name": "rango-ec2"},
  "SecurityGroupIds": ["$SG_WEB"],
  "MetadataOptions": {"HttpTokens": "required", "HttpEndpoint": "enabled"},
  "BlockDeviceMappings": [{
    "DeviceName": "/dev/xvda",
    "Ebs": {"VolumeSize": 10, "VolumeType": "gp3", "Encrypted": true, "DeleteOnTermination": true}
  }],
  "TagSpecifications": [
    {"ResourceType": "instance", "Tags": [{"Key": "Name", "Value": "rango-api"}, {"Key": "Projeto", "Value": "rango"}]},
    {"ResourceType": "volume", "Tags": [{"Key": "Projeto", "Value": "rango"}]}
  ]
}
EOF

aws ec2 create-launch-template \
  --launch-template-name rango-api \
  --version-description "AMI rango-api-20261015" \
  --launch-template-data file://infra/asg/launch-template.json \
  --tag-specifications 'ResourceType=launch-template,Tags=[{Key=Projeto,Value=rango}]'
```

Não há user data: a imagem já sabe tudo. Repare que o template não diz em qual subnet a instância nasce. Essa decisão é do ASG.

### O Auto Scaling Group

```bash
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name rango-api \
  --launch-template 'LaunchTemplateName=rango-api,Version=$Default' \
  --min-size 2 --max-size 6 --desired-capacity 2 \
  --vpc-zone-identifier "$PRIV_A,$PRIV_B" \
  --target-group-arns "$TG_ARN" \
  --health-check-type ELB \
  --health-check-grace-period 90 \
  --default-instance-warmup 60 \
  --tags Key=Projeto,Value=rango,PropagateAtLaunch=false
```

O mínimo de 2, com duas subnets, deixa uma instância em cada AZ: se uma zona cair, o Rangô segue com metade da capacidade. O `$Default`, entre aspas simples para o shell não expandir, faz o ASG usar a versão marcada como padrão no template.

O máximo de 6 tem a ver com o banco. Cada instância abre até dez conexões (dois workers do Uvicorn com cinco cada), e seis instâncias somam sessenta. A fórmula do `max_connections` do capítulo 12 dá pouco mais de cem para uma `db.t4g.micro`, e uma parte disso fica com os workers, com você no `psql` e com o próprio RDS. Um ASG com máximo de 20 derrubaria o banco com `FATAL: sorry, too many clients already` exatamente no pico. O teto do grupo protege o banco e a fatura.

A grace period de 90 segundos dá folga para uma instância que nasce pronta. Pelo console, o padrão é 300 segundos. Pela CLI e pelos SDKs, o padrão é zero, e a seção de armadilhas mostra o que isso causa.

O PassRole da role `rango-ec2` já está liberado no seu permission set desde o capítulo 9. O ASG só aceita um Launch Template com instance profile se quem cria o grupo puder passar aquela role ao EC2, e o statement `PassarSoARoleDoServidor` cobre exatamente isso.

### O sintoma do Security Group esquecido

Espere um minuto e consulte a saúde dos alvos:

```bash
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query "TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]" \
  --output text
```

```text
i-0a1b2c3d4e5f60718	unhealthy	Target.Timeout
i-0f9e8d7c6b5a40321	unhealthy	Target.Timeout
```

Timeout, como no capítulo 10: o `rango-web` descarta em silêncio o pacote do ALB. Espere mais um pouco e olhe o histórico do grupo:

```bash
aws autoscaling describe-scaling-activities --auto-scaling-group-name rango-api \
  --max-items 4 --query "Activities[].Description" --output text
```

Passada a grace period, o ASG confia no veredito do target group, conclui que as duas instâncias estão doentes e as substitui por outras duas, que vão falhar pelo mesmo motivo. Um erro de rede vira um ciclo de criar e destruir máquinas. Corrija com a regra que faltava, tendo o grupo do ALB como origem:

```bash
aws ec2 authorize-security-group-ingress --group-id "$SG_WEB" \
  --protocol tcp --port 80 --source-group "$SG_ALB"
```

Em menos de um minuto:

```text
i-0c4d5e6f7a8b90123	healthy	None
i-0d7e8f9a0b1c23456	healthy	None
```

As duas instâncias atendem só a quem está no grupo `rango-alb`. É a mesma regra que o `rango-db` usa para aceitar só a API, um andar acima.

### O primeiro curl

Do seu computador, chame o ALB algumas vezes e olhe o cabeçalho que o middleware do capítulo 4 coloca em cada resposta:

```bash
for i in 1 2 3 4 5 6; do
  curl -s -o /dev/null -D - "http://$ALB_DNS/restaurantes" | grep -i x-rango-instancia
done
```

```text
X-Rango-Instancia: ip-10-20-10-37.ec2.internal
X-Rango-Instancia: ip-10-20-11-142.ec2.internal
X-Rango-Instancia: ip-10-20-10-37.ec2.internal
X-Rango-Instancia: ip-10-20-11-142.ec2.internal
X-Rango-Instancia: ip-10-20-10-37.ec2.internal
X-Rango-Instancia: ip-10-20-11-142.ec2.internal
```

Round robin, uma instância em cada AZ. Um `GET /pedidos/6f1c2a9e-3b4d-4e8f-9a1b-2c3d4e5f6a7b` pelo ALB devolve o pedido da Ana, gravado no capítulo 12, de qualquer uma das duas.

### Tirar uma instância da roda

Num terminal, deixe um laço mostrando o código de status e a instância de cada resposta:

```bash
while true; do
  printf '%s ' "$(date +%T)"
  curl -s -o /dev/null -w '%{http_code} %header{x-rango-instancia}\n' \
    --max-time 5 "http://$ALB_DNS/restaurantes"
  sleep 0.5
done
```

O `%header{}` exige `curl` 7.84 ou mais novo. Em outro terminal, peça ao ASG para encerrar uma das instâncias sem reduzir a capacidade desejada:

```bash
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id i-0c4d5e6f7a8b90123 \
  --no-should-decrement-desired-capacity
```

O laço continua com `200` o tempo todo. O ASG primeiro tira a instância do target group, ela entra em `draining`, e só depois é encerrada. Em seguida, o ASG percebe que tem uma instância a menos do que o desejado e cria outra. Um minuto e pouco depois, um hostname novo aparece no laço.

Compare com o failover do banco no capítulo 12, em que o laço mostrou alguns `500`. A diferença está no draining: o ALB sabe que a instância vai sair antes de ela sair.

### A política de escala

A política precisa saber de qual ALB e de qual target group contar as requisições. Esse par vai num campo chamado `ResourceLabel`, montado com o final dos dois ARNs:

```bash
LABEL="${ALB_ARN#*:loadbalancer/}/${TG_ARN##*:}"
echo "$LABEL"
```

```text
app/rango-alb/50dc6c495c0c9188/targetgroup/rango-api/943f017f100becff
```

O alvo vem da conta do capítulo 4. Cada worker atende umas 12 requisições por segundo, e dois workers dão umas 24 por segundo, ou cerca de 1.400 por minuto por instância. Um alvo de 600 por minuto mantém cada máquina abaixo da metade da capacidade, com espaço para absorver o crescimento enquanto as instâncias novas sobem.

```bash
cat > infra/asg/politica-requisicoes.json <<EOF
{
  "TargetValue": 600,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ALBRequestCountPerTarget",
    "ResourceLabel": "$LABEL"
  }
}
EOF

aws autoscaling put-scaling-policy \
  --auto-scaling-group-name rango-api \
  --policy-name requisicoes-por-instancia \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration file://infra/asg/politica-requisicoes.json
```

### A noite da TV, em quinze minutos

Crie `carga/tv.js`, um teste de carga do k6, a ferramenta citada no capítulo 4:

```javascript
import http from "k6/http";

export const options = {
  vus: 30,
  duration: "15m",
};

export default function () {
  http.get(`http://${__ENV.ALB}/restaurantes`);
}
```

Trinta usuários virtuais pedindo a lista sem parar. Do Brasil até `us-east-1`, isso dá na casa de 200 requisições por segundo, perto do pico do programa de TV do capítulo 4. Rode:

```bash
k6 run -e ALB="$ALB_DNS" carga/tv.js
```

Em outro terminal, acompanhe a frota a cada minuto:

```bash
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names rango-api \
  --query "AutoScalingGroups[0].[DesiredCapacity,length(Instances)]" --output text
```

Nos primeiros minutos, nada muda: o alarme da target tracking precisa ver alguns minutos de métrica acima do alvo. Depois, o histórico conta a decisão:

```bash
aws autoscaling describe-scaling-activities --auto-scaling-group-name rango-api \
  --max-items 1 --query "Activities[0].Cause" --output text
```

```text
At 2026-10-15T18:21:40Z a monitor alarm TargetTracking-rango-api-AlarmHigh-7f3a2b1c in state ALARM triggered policy requisicoes-por-instancia changing the desired capacity from 2 to 6. At 2026-10-15T18:21:52Z instances were launched in response to a difference between desired and running capacity, increasing the capacity from 2 to 6.
```

Cerca de 12.000 requisições por minuto divididas por um alvo de 600 dariam 20 instâncias, e o máximo de 6 cortou o pedido. Quando o k6 terminar, o ASG remove instâncias aos poucos até voltar a 2, bem mais devagar do que subiu.

### Agendado para sábado

O especial de sábado tem hora marcada. A API de ações agendadas trabalha em UTC, e Brasília está em UTC−3, então 20h30 de sábado, 17 de outubro, são 23h30 UTC. Você provavelmente vai ler isto em outro dia, e uma data que já passou faz o comando falhar. Por isso, o shell calcula o próximo sábado:

```bash
SABADO=$(date -u -d 'next saturday' +%Y-%m-%d)
INICIO="${SABADO}T23:30:00Z"
FIM=$(date -u -d "$SABADO 23:30 UTC + 4 hours" +%Y-%m-%dT%H:%M:%SZ)
echo "$INICIO $FIM"

aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name rango-api \
  --scheduled-action-name especial-tv-inicio \
  --start-time "$INICIO" \
  --min-size 4 --desired-capacity 4

aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name rango-api \
  --scheduled-action-name especial-tv-fim \
  --start-time "$FIM" \
  --min-size 2
```

O `-d` é do `date` do GNU, o do Linux e do CloudShell. No macOS, rode este trecho no CloudShell ou instale o `coreutils` (`brew install coreutils`) e troque `date` por `gdate`. As datas que aparecem nas saídas deste capítulo são as da história; no seu terminal, aparecem as suas.

Às 20h30, o mínimo sobe para 4, e a target tracking continua podendo ir até 6. À meia-noite e meia, o mínimo volta a 2, e a política remove o excesso conforme o tráfego cai.

### Desmontar

O ALB, o ASG, o banco e o cache cobram por hora. O Launch Template, os Security Groups e a AMI ficam, porque o capítulo 14 reaproveita tudo: o template e os grupos não cobram nada, e o snapshot da AMI cobra centavos por mês. Apague o grupo primeiro, porque ele levaria as instâncias de volta se você apagasse só elas:

```bash
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name rango-api --force-delete

aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN"
aws elbv2 delete-target-group --target-group-arn "$TG_ARN"

aws elasticache delete-serverless-cache --serverless-cache-name rango-cache

aws rds modify-db-instance --db-instance-identifier rango-db \
  --no-deletion-protection --apply-immediately
aws rds delete-db-instance --db-instance-identifier rango-db \
  --final-db-snapshot-identifier rango-db-final-cap13
aws rds wait db-instance-deleted --db-instance-identifier rango-db
aws rds delete-db-snapshot --db-snapshot-identifier rango-db-final-cap12
```

O `--force-delete` encerra as instâncias junto com o grupo, e apagar o ASG apaga também a política, os alarmes que ela criou e as ações agendadas. O plano de sábado vai junto, e tudo bem: o capítulo 14 recria o grupo e as duas ações antes do especial. Confira que não sobrou instância:

```bash
aws ec2 describe-instances \
  --filters Name=tag:Projeto,Values=rango Name=instance-state-name,Values=pending,running \
  --query "Reservations[].Instances[].InstanceId" --output text
```

## Armadilhas e casos reais

> **Armadilha:** Grace period zero pela CLI. Num caso hipotético, mas comum, um time cria o ASG pela CLI sem `--health-check-grace-period`, com `--health-check-type ELB` e um user data que leva quatro minutos instalando pacotes. O padrão pela CLI é zero, então o ASG passa a ouvir o target group assim que a instância nasce. Ela falha no health check porque o Nginx nem foi instalado, é marcada como doente e substituída. A substituta tem o mesmo destino. O grupo fica girando máquinas por horas, cada uma cobrando no mínimo 60 segundos. A AWS recomenda configurar também o `--default-instance-warmup`, como fizemos.

> **Armadilha:** O ALB cobra parado. Em `us-east-1`, o ALB custa US$ 0,0225 por hora (hora parcial conta como cheia), cerca de US$ 16 por mês, mais US$ 0,008 por LCU-hora. A LCU mede o uso em quatro dimensões (25 conexões novas por segundo, 3.000 conexões ativas por minuto, 1 GB por hora processado, 1.000 avaliações de regra por segundo, com as 10 primeiras regras grátis), e só a dimensão de maior uso na hora entra na conta. Cada nó do ALB também tem um IPv4 público, a US$ 0,005 por hora: com duas AZs, mais uns US$ 7 por mês. Um ALB esquecido com zero tráfego passa de US$ 23 por mês. O free tier antigo cobria 750 horas e 15 LCUs por mês; nas contas criadas a partir de 15 de julho de 2025, como a `rango-estudos`, o ALB consome os créditos do Free plan. Valores de referência, consultados em outubro de 2026.
> **Armadilha:** Instância burstable no ASG. As instâncias do Rangô usam `CpuCredits=standard` desde o capítulo 9, para nunca gerar cobrança extra. Num pico longo, os créditos acabam, a CPU cai para a linha de base, e a instância fica lenta sem ficar doente: o `/health` continua respondendo em milissegundos, enquanto as rotas reais demoram segundos. A política por requisições não percebe. Para produção com tráfego constante, uma família `m` ou `c` evita a surpresa.

> **Armadilha:** O máximo do ASG é a sua última proteção de custo e de banco. Um bot fazendo milhões de requisições também aumenta o `ALBRequestCountPerTarget`, e a target tracking não diferencia cliente de ataque. Com um máximo alto, o bot escala a sua fatura e esgota as conexões do RDS. O WAF, no capítulo 23, filtra o tráfego antes que ele chegue à política.

> **Armadilha:** AZ sem instância. O cross-zone load balancing do ALB fica sempre ligado no nível do balanceador, e por isso um nó numa AZ sem instâncias repassa as requisições para a outra. O target group pode desligar essa opção, com o atributo `load_balancing.cross_zone.enabled`. Se você fizer isso e uma AZ ficar sem alvos, quem cair no nó daquela AZ recebe `503`. As sticky sessions também deixam de funcionar com o cross-zone desligado.
> **Na vida real:** Na véspera de Natal de 2012, às 12h24 no horário do Pacífico, um processo de manutenção rodou por engano contra os dados de estado do Elastic Load Balancing em produção, na região `us-east-1`. Esses dados dizem ao plano de controle do ELB como cada balanceador está configurado, inclusive para quais instâncias mandar tráfego. No pior momento, 6,8% dos balanceadores da região foram afetados, e os demais continuaram funcionando sem poder ser alterados ou escalados. A Netflix ficou fora do ar em vários dispositivos durante a noite de Natal nos Estados Unidos. O resumo publicado pela AWS conta a recuperação: parte dos balanceadores foi restaurada à mão, e o restante voltou com uma restauração dos dados de estado para o ponto logo antes das 12h24. É point-in-time recovery, o mesmo do capítulo 12, aplicado à infraestrutura da própria AWS.
## Resumo

- O Elastic Load Balancing tem o ALB (camada 7, HTTP) e o NLB (camada 4, TCP e UDP). O ALB é um conjunto de nós por AZ, acessado por um nome DNS.
- Listener escuta a porta, regras escolhem a ação, target group guarda os alvos e o health check.
- Health check padrão: 30 segundos de intervalo, 5 de timeout, 5 sucessos para ficar saudável. Sem alvos saudáveis, o ALB faz fail open.
- Deregistration delay (padrão de 300 segundos) deixa as requisições em andamento terminarem antes de um alvo sair.
- Launch Template é a receita versionada da instância. Launch configurations não podem mais ser criadas em contas novas.
- O ASG mantém a capacidade desejada entre o mínimo e o máximo, substitui instâncias doentes e registra as novas no target group. Com `--health-check-type ELB`, ele também ouve o target group.
- Grace period: 300 segundos pelo console, zero pela CLI. Defina sempre, junto com o default instance warmup.
- Target tracking com `ALBRequestCountPerTarget` mantém as requisições por instância perto de um alvo. Ações agendadas escalam antes de um pico com hora marcada.
- O Rangô ganhou uma golden AMI (`rango-api-20261015`), o Launch Template `rango-api`, o ALB `rango-alb` nas subnets públicas e o ASG `rango-api` com 2 a 6 instâncias nas privadas. Sobreviveu à remoção de uma instância sem nenhum erro e escalou sozinho num teste de carga.

## Um endereço que ninguém vai digitar

Olhe de novo o endereço que o Rangô tem agora: `http://rango-alb-1234567890.us-east-1.elb.amazonaws.com`. Ele aguenta a TV, mas o apresentador não vai ler isso no ar. E ainda tem o `http://` na frente: os pedidos e as presigned URLs das fotos, que funcionam como senha, passando em texto puro, com o navegador avisando "não seguro" para quem abrir o link.

O React continua rodando no seu computador, apontando para a API por um `VITE_API_URL`. Quando ele for para a nuvem, a sócia em Recife vai carregar cada arquivo JavaScript de um servidor na Virgínia. O capítulo 2 explicou DNS, certificados e CDN na teoria. No próximo capítulo, o Rangô ganha o domínio `rango.com.br` no Amazon Route 53, um certificado gratuito do AWS Certificate Manager no ALB e o React servido pelo Amazon CloudFront, perto de quem está pedindo comida.

## Referências

- Health checks dos target groups do ALB: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html
- Atributos dos target groups (deregistration delay, algoritmos, slow start, cross-zone, sticky sessions): https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-target-group-attributes.html
- Cotas do Application Load Balancer: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-limits.html
- Preços do Elastic Load Balancing: https://aws.amazon.com/elasticloadbalancing/pricing/
- Cobrança de IPv4 público (AWS News Blog): https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/
- Health check grace period do EC2 Auto Scaling: https://docs.aws.amazon.com/autoscaling/ec2/userguide/health-check-grace-period.html
- Target tracking no EC2 Auto Scaling: https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html
- API `PutScalingPolicy` (warmup): https://docs.aws.amazon.com/autoscaling/ec2/APIReference/API_PutScalingPolicy.html
- Launch configurations (fim da criação): https://docs.aws.amazon.com/autoscaling/latest/userguide/LaunchConfiguration.html
- IAM role para aplicações em instâncias do ASG (PassRole): https://docs.aws.amazon.com/autoscaling/ec2/userguide/us-iam-role.html
- Resumo do evento do ELB de 24 de dezembro de 2012: https://aws.amazon.com/message/680587/
- psycopg_pool, verificação de conexões: https://www.psycopg.org/psycopg3/docs/advanced/pool.html
