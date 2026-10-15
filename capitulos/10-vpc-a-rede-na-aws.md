# VPC: a rede na AWS

No capítulo anterior, o Rangô rodou numa instância EC2 de verdade, com Valkey, Uvicorn e workers no systemd e o Nginx na frente, e você entrou nela pelo Session Manager sem abrir a porta 22. Tudo isso aconteceu na VPC default, uma rede pronta em que toda subnet é pública. No fim, a instância foi destruída, e a role `rango-ec2` e o script `infra/ec2/user-data.sh` ficaram guardados. A ponte deixou um atalho perigoso no ar: instalar o PostgreSQL na mesma máquina e abrir a porta 5432 para o mundo, "só até terminar o teste".

## A porta 5432 aberta para o mundo

Suponha que você tenha seguido o atalho. É uma situação hipotética, mas acontece todos os dias. Numa terça à noite, você instala o PostgreSQL na instância, cria uma senha razoável para o usuário `postgres`, acrescenta ao `rango-web` a regra da porta 5432 com origem `0.0.0.0/0` e conecta pelo DBeaver do notebook. Funciona. Você vai dormir.

Na manhã seguinte, o log do Postgres tem isto:

```text
2026-10-14 02:13:47.112 UTC [48213] FATAL:  password authentication failed for user "postgres"
2026-10-14 02:13:47.894 UTC [48214] FATAL:  password authentication failed for user "postgres"
2026-10-14 02:13:48.401 UTC [48215] FATAL:  no pg_hba.conf entry for host "198.51.100.77", user "admin", database "postgres", SSL off
2026-10-14 02:13:49.020 UTC [48216] FATAL:  password authentication failed for user "postgres"
```

São milhares de linhas, vindas de dezenas de IPs que você nunca viu. Ninguém mirou no Rangô. Robôs varrem a faixa inteira de IPs públicos da AWS o tempo todo, procurando portas conhecidas: 22 para SSH, 3306 para MySQL, 5432 para Postgres, 6379 para Redis, 27017 para MongoDB, 9200 para Elasticsearch. Mecanismos de busca como o Shodan catalogam o que respondem. Uma porta aberta numa instância nova costuma ser encontrada em minutos ou poucas horas.

Desta vez a senha aguentou. Basta um usuário de teste com senha fraca, uma extensão com falha conhecida ou um Postgres que ficou dois anos sem atualização para a história terminar mal.

> **Na vida real:** Em julho de 2020, um ataque que ficou conhecido como "Meow" começou a apagar bancos Elasticsearch e MongoDB expostos na internet sem autenticação. O robô não pedia resgate nem deixava recado: só destruía os dados e escrevia a palavra "meow" no lugar. Em poucos dias, o BleepingComputer contou quase 4 mil bancos apagados. Um dos primeiros casos públicos foi encontrado pelo pesquisador Bob Diachenko, num banco ligado ao serviço UFO VPN.

O problema de fundo vai além da regra do Security Group. Na VPC default, toda instância nasce numa subnet pública, com IP público. O Security Group é a única coisa entre o banco e a internet, e uma regra errada desfaz tudo. Não existe na sua conta nenhum lugar onde uma máquina fique fora do alcance da internet *por construção*, de forma que nem uma regra errada a exponha. É esse lugar que você vai construir agora.

## Uma rede só sua dentro da AWS

A **Amazon VPC** (*Virtual Private Cloud*) é uma rede privada isolada dentro de uma região da AWS. Você escolhe a faixa de IPs, divide em subnets, decide as rotas e decide o que conversa com a internet. Fisicamente, as suas instâncias dividem hardware com as de milhares de outros clientes. Logicamente, a VPC garante que nenhum pacote de outra rede chegue nelas, a menos que você monte o caminho.

Lembra da rede da sua casa, do capítulo 1? Ela tem uma faixa privada (`192.168.0.0/24`), um roteador que é o gateway padrão e um NAT que deixa os aparelhos saírem para a internet sem que ninguém de fora consiga iniciar uma conexão com eles. A VPC tem as mesmas peças, com nomes diferentes e uma vantagem: cada peça é um recurso que você cria por API e paga (ou não) separadamente.

A VPC em si não custa nada. Subnets, route tables, Internet Gateway, Security Groups e Network ACLs também não. A conta começa a subir com o NAT Gateway, os IPv4 públicos, os endpoints de interface e o tráfego. Guarde essa lista, porque ela vai decidir o que fica e o que vai embora no fim do capítulo.

### Escolher a faixa antes de tudo

Toda VPC começa com um bloco CIDR IPv4. O tamanho permitido vai de `/16` (65.536 endereços) a `/28` (16 endereços). A AWS recomenda as faixas privadas da RFC 1918 que você conheceu no capítulo 1: `10.0.0.0/8`, `172.16.0.0/12` e `192.168.0.0/16`.

Essa escolha merece cinco minutos de conversa, porque o tamanho de um bloco CIDR não muda depois de criado. Você pode associar blocos secundários à VPC (até cinco por padrão), mas o primário fica para sempre. E o critério mais importante é outro: a faixa não pode colidir com as redes com que a VPC um dia vai conversar. Conexões entre VPCs (*peering*) e com a rede de um escritório exigem faixas sem sobreposição. Se o Rangô um dia tiver uma VPC de produção, outra de homologação e uma VPN para o escritório, as três precisam de faixas diferentes.

Para o Rangô, a escolha é `10.20.0.0/16`, e cada descartada tem um motivo:

- `10.0.0.0/16` é a faixa de todos os tutoriais. Quanto mais gente usa, maior a chance de colidir com a VPC de um parceiro ou com a rede de uma empresa que você adquirir.
- `172.31.0.0/16` é a faixa da VPC default em todas as regiões.
- `172.17.0.0/16` é a rede *bridge* padrão do Docker. A documentação da AWS pede para evitá-la, porque serviços como o SageMaker AI usam essa faixa e o conflito de IPs aparece em lugares inesperados. Você já viu esse tipo de colisão com a VPN no capítulo 1.

Um `/16` é muito mais do que o Rangô precisa, e é justamente essa sobra que permite fatiar a rede com folga.

### Subnets: a rede fatiada por zona

Uma **subnet** é um pedaço do CIDR da VPC que vive inteiro dentro de uma única zona de disponibilidade. Essa amarração tem uma consequência direta: para ter alta disponibilidade, você precisa de subnets em pelo menos duas AZs. O RDS, no capítulo 12, exige um grupo de subnets em duas AZs, e o Application Load Balancer, no capítulo 13, também.

O capítulo 1 adiantou que a AWS reserva cinco endereços em toda subnet. Numa subnet `10.20.10.0/24`, são estes:

- `10.20.10.0`: o endereço da rede.
- `10.20.10.1`: o roteador da VPC.
- `10.20.10.2`: o servidor DNS da AWS (o resolver da VPC, que na prática responde em qualquer endereço base da VPC mais dois).
- `10.20.10.3`: reservado para uso futuro.
- `10.20.10.255`: o último endereço, reservado porque a VPC não usa broadcast.

Sobram 251 endereços utilizáveis por `/24`, mais do que suficiente para o Rangô por um bom tempo.

O plano tem duas camadas, cada uma em duas AZs. A numeração deixa buracos de propósito, para caber uma terceira AZ ou uma camada nova sem bagunçar a contagem:

| Subnet | CIDR | AZ | Para quê |
|--------|------|----|----------|
| `rango-publica-a` | `10.20.0.0/24` | us-east-1a | API, NAT, futuro load balancer |
| `rango-publica-b` | `10.20.1.0/24` | us-east-1b | idem, na outra AZ |
| `rango-privada-a` | `10.20.10.0/24` | us-east-1a | banco, workers, endpoints |
| `rango-privada-b` | `10.20.11.0/24` | us-east-1b | idem, na outra AZ |

Repare que nada na criação de uma subnet diz se ela é pública ou privada. Essa diferença mora em outro lugar.

### Route tables: quem decide o caminho

Cada subnet está associada a uma **route table**, uma tabela que diz para onde vai cada pacote conforme o destino. É o mesmo roteamento por *longest prefix match* do capítulo 1, aquele que lembra a escolha de rota do FastAPI: vence a regra mais específica.

Toda route table de uma VPC nasce com uma rota que você não pode apagar:

```text
Destino          Alvo
10.20.0.0/16     local
```

Ela garante que qualquer máquina da VPC alcance qualquer outra. A partir daí, você acrescenta rotas. Uma subnet sem associação explícita usa a *main route table* da VPC, que no início tem só a rota `local`.

### Internet Gateway: a porta da rua

O **Internet Gateway** é o componente que liga a VPC à internet. Você cria, anexa à VPC (uma VPC aceita um só) e ele passa a fazer duas coisas: encaminhar o tráfego entre a VPC e a internet e traduzir, um para um, o IP público de cada instância para o IP privado dela. É o NAT de um para um que você viu no capítulo 9, quando o `198.51.100.23` não aparecia no `ip addr` da instância.

Ele não cobra por hora e não tem limite de banda que você precise dimensionar. Anexar um Internet Gateway, porém, não muda nada sozinho. Nenhum pacote vai para ele até que uma route table aponte para lá.

### O que torna uma subnet pública

Agora dá para responder à pergunta que ficou aberta. Uma subnet é **pública** quando a route table dela tem uma rota padrão para o Internet Gateway:

```text
Destino          Alvo
10.20.0.0/16     local
0.0.0.0/0        igw-0a1b2c3d4e5f67890
```

Uma subnet **privada** é aquela que não tem essa rota. É só isso, e o efeito é forte. Uma instância numa subnet privada pode até ganhar um Security Group que libera a porta 5432 para `0.0.0.0/0`, e mesmo assim nenhum pacote da internet chega até ela, porque simplesmente não existe caminho. Ela também não tem IP público, e a resposta de qualquer coisa que ela tentar enviar para fora morre na rota `local`.

Essa é a proteção por construção que faltava. O Security Group continua sendo a regra fina; a subnet privada é a parede.

Para a instância numa subnet pública ser alcançável, ela ainda precisa de um IPv4 público. A subnet tem um atributo que atribui um IP público automaticamente a toda instância que nasce nela. Cada um desses IPs custa US$ 0,005 por hora desde fevereiro de 2024, como você viu nos capítulos anteriores.

### NAT Gateway: sair sem ser encontrado

A subnet privada resolve a entrada, e cria um problema na saída. O banco do Rangô precisa baixar pacotes com o `dnf`. O SSM Agent precisa falar com o Systems Manager pela porta 443, senão você não entra na máquina. Um worker numa subnet privada vai precisar chamar o gateway de pagamento. Sem rota para fora, nada disso funciona.

A resposta é o mesmo truque do roteador de casa: um NAT que deixa sair e não deixa entrar. O **NAT Gateway** fica numa subnet pública, com um Elastic IP. A route table da subnet privada ganha a rota `0.0.0.0/0` apontando para ele. Quando o banco abre uma conexão para fora, o NAT Gateway troca o IP de origem pelo dele, guarda a conversão na tabela (o dicionário do capítulo 1) e devolve a resposta. Uma conexão iniciada de fora não encontra nenhuma entrada na tabela e é descartada.

O NAT Gateway é gerenciado: a AWS cuida da disponibilidade dentro da AZ e da escala até dezenas de Gbps. E ele cobra de dois jeitos ao mesmo tempo. Em `us-east-1`, com preços de referência consultados em outubro de 2026:

- US$ 0,045 por hora em que existe, com ou sem tráfego. São cerca de US$ 32,85 por mês.
- US$ 0,045 por GB processado, em qualquer direção, independentemente da origem ou do destino.
- O Elastic IP dele, US$ 0,005 por hora, cerca de US$ 3,65 por mês.

Em `sa-east-1`, os valores são mais altos. Consulte a página de preços da VPC para a sua região antes de decidir.

Agora vem a parte que pega as pessoas. Um NAT Gateway vive numa AZ só. Se a AZ dele cair, as subnets privadas de todas as AZs que dependem dele ficam sem saída. O desenho recomendado para produção é um NAT Gateway por AZ, cada subnet privada apontando para o da própria zona. Com três AZs, são cerca de US$ 98 por mês só de horas, antes de passar um único byte. Para um projeto que fatura pouco, é muitas vezes a maior linha da fatura.

A alternativa de economizar com um único NAT para todas as AZs tem outro custo: o tráfego de uma subnet privada na AZ `b` atravessa até o NAT na AZ `a`, e tráfego entre AZs cobra cerca de US$ 0,01 por GB em cada direção.

Desde novembro de 2025, existe uma terceira opção, o **NAT Gateway regional**. Um único gateway atende várias AZs, cresce e encolhe sozinho conforme surgem recursos em novas zonas e nem precisa de subnet pública. A cobrança é por hora para cada AZ ativa, mais o mesmo valor por GB, então ela simplifica a operação sem necessariamente baratear. Um artigo do AWS re:Post observa que, quando aparece um recurso numa AZ nova, a expansão pode levar até cerca de uma hora, e nesse intervalo o tráfego sai por outra AZ. Neste capítulo, você vai usar o NAT Gateway zonal, que é o modelo que a maior parte da documentação e dos exemplos ainda assume.

### Security Groups e Network ACLs

Você conheceu o Security Group no capítulo 9 como um middleware de autorização na rede: só tem regras de permissão, é *stateful* (a resposta de uma conexão permitida volta sozinha) e fica preso à interface de rede da instância. Na VPC própria, ele ganha um recurso que vai mudar a forma como você escreve regras: a origem pode ser outro Security Group.

Em vez de "libere a porta 5432 para `10.20.0.0/24`", você escreve "libere a porta 5432 para quem estiver no grupo `rango-web`". A regra acompanha as instâncias. Quando o Auto Scaling do capítulo 13 criar uma API nova com outro IP, ela entra no grupo e o banco a aceita, sem ninguém editar faixa nenhuma. É a mesma ideia de checar `request.user.groups` em vez de uma lista de IDs de usuário.

A VPC tem uma segunda camada de filtro, as **Network ACLs** (NACLs). Elas funcionam no nível da subnet e se comportam de outro jeito:

| | Security Group | Network ACL |
|---|---|---|
| Onde age | Interface de rede da instância | Subnet inteira |
| Regras | Só *allow* | *Allow* e *deny* |
| Estado | Stateful | Stateless |
| Avaliação | Todas as regras juntas | Em ordem numérica, a primeira que casar vence |
| Origem | CIDR, prefix list ou outro SG | Só CIDR |
| Padrão | Novo grupo: nada entra, tudo sai | NACL default da VPC: tudo entra, tudo sai |

O detalhe que mais confunde é a palavra *stateless*. A NACL não lembra conexões. Se ela libera a entrada na porta 443, a resposta sai para a porta efêmera do cliente, um número alto e aleatório, e precisa de uma regra de saída própria, em geral para as portas `1024-65535`. Esquecer essa regra produz o timeout mais difícil de diagnosticar da VPC, porque o Security Group está certo e o pacote chega.

Para o Rangô, a recomendação é deixar a NACL default como está, liberando tudo, e fazer o controle no Security Group. A NACL serve bem a um caso específico: bloquear uma faixa de IPs que está atacando, algo que o Security Group não sabe fazer, porque não tem regra de negação. Uma regra de número baixo com `deny` para `203.0.113.0/24` resolve na hora para a subnet inteira. Para filtrar ataques HTTP de forma mais inteligente, o capítulo 23 vai apresentar o AWS WAF.

### VPC endpoints: falar com a AWS sem passar pela internet

Há uma pegadinha no desenho com NAT. O SSM Agent da instância privada fala com `ssm.us-east-1.amazonaws.com`. Um worker que lê fotos do S3 fala com `s3.us-east-1.amazonaws.com`. São serviços da própria AWS, na mesma região, e mesmo assim o tráfego sai pelo NAT Gateway, como se fosse para a internet, e paga US$ 0,045 por GB no caminho.

Os **VPC endpoints** criam um caminho privado da VPC até os serviços da AWS. Existem dois tipos, com custos bem diferentes:

- **Gateway endpoints**, só para S3 e DynamoDB. Viram uma rota na route table, apontando o prefixo do serviço para o endpoint. Não cobram nada, nem por hora nem por GB.
- **Interface endpoints**, para quase todos os outros serviços (SSM, Secrets Manager, ECR, CloudWatch e dezenas mais). Cada um cria uma interface de rede com IP privado em cada subnet que você escolher, e o DNS privado faz o nome do serviço resolver para esse IP. Cobram por hora por AZ (cerca de US$ 0,01) e por GB processado (US$ 0,01 nos primeiros petabytes), com preços de referência de outubro de 2026.

O gateway endpoint do S3 é a decisão mais fácil do capítulo: não custa nada e tira do NAT um tráfego que pode ser enorme. Os endpoints de interface pedem conta. Para o Session Manager funcionar sem nenhuma saída para a internet, a instância precisa de três: `ssm`, `ssmmessages` e `ec2messages`. Em duas AZs, são seis horas de endpoint por hora, cerca de US$ 44 por mês, mais caro que um NAT Gateway. Endpoints de interface compensam quando o volume de dados é alto ou quando a regra é que a subnet não pode ter saída nenhuma para a internet, como em ambientes regulados.

## Mão na massa: a rede do Rangô

O plano é este: criar a `rango-vpc` com quatro subnets, o Internet Gateway e duas route tables; subir a API numa subnet pública e um PostgreSQL 17 numa privada; dar ao banco uma saída temporária por NAT Gateway para instalar os pacotes; e, por fim, trocar o NAT por endpoints, deixando o banco sem nenhum caminho para a internet.

```text
                        Internet
                           |
                   [ rango-igw ]
                           |
 +--------------------- rango-vpc 10.20.0.0/16 -------------------------+
 |                                                                      |
 |  us-east-1a                          us-east-1b                      |
 |  +-----------------------------+     +-----------------------------+ |
 |  | rango-publica-a 10.20.0.0/24|     | rango-publica-b 10.20.1.0/24| |
 |  |  rango-api-01  [NAT]        |     |                             | |
 |  +-----------------------------+     +-----------------------------+ |
 |  +-----------------------------+     +-----------------------------+ |
 |  | rango-privada-a 10.20.10.0/24     | rango-privada-b 10.20.11.0/24 |
 |  |  rango-db-01  [endpoints]   |     |                             | |
 |  +-----------------------------+     +-----------------------------+ |
 |                                                                      |
 |  rango-rt-publica:  local + 0.0.0.0/0 -> igw                         |
 |  rango-rt-privada:  local + S3 -> gateway endpoint                   |
 +----------------------------------------------------------------------+
```

### Pré-requisitos

- AWS CLI v2 com o perfil `rango-dev` dos capítulos anteriores, com login feito.
- Session Manager plugin instalado (capítulo 9).
- A role `rango-ec2` e o statement `PassarSoARoleDoServidor` no permission set, também do capítulo 9.
- O arquivo `infra/ec2/user-data.sh` no repositório.

Os comandos usam variáveis de shell para guardar IDs, então rode tudo no mesmo terminal. Se a sessão cair, recupere os IDs com `describe-*` filtrando pela tag `Name`.

```bash
export AWS_PROFILE=rango-dev
export AWS_REGION=us-east-1
aws sso login
```

### A VPC e as subnets

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.20.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=rango-vpc},{Key=Projeto,Value=rango}]' \
  --query Vpc.VpcId --output text)

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" \
  --enable-dns-hostnames '{"Value":true}'
```

O resolver DNS da VPC já vem ligado. O segundo comando liga os nomes DNS das instâncias, que os endpoints de interface com DNS privado exigem. Sem ele, a criação dos endpoints falha mais adiante.

Para as quatro subnets, uma função curta evita repetir o mesmo comando:

```bash
criar_subnet() {
  aws ec2 create-subnet --vpc-id "$VPC_ID" \
    --cidr-block "$2" --availability-zone "$3" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$1},{Key=Projeto,Value=rango}]" \
    --query Subnet.SubnetId --output text
}

PUB_A=$(criar_subnet rango-publica-a 10.20.0.0/24 us-east-1a)
PUB_B=$(criar_subnet rango-publica-b 10.20.1.0/24 us-east-1b)
PRIV_A=$(criar_subnet rango-privada-a 10.20.10.0/24 us-east-1a)
PRIV_B=$(criar_subnet rango-privada-b 10.20.11.0/24 us-east-1b)
```

Confira o que existe:

```bash
aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
  --query "Subnets[].[Tags[?Key=='Name']|[0].Value,CidrBlock,AvailabilityZone,AvailableIpAddressCount]" \
  --output table
```

```text
-----------------------------------------------------------
|                     DescribeSubnets                     |
+------------------+----------------+-------------+-------+
|  rango-publica-a |  10.20.0.0/24  |  us-east-1a |  251  |
|  rango-publica-b |  10.20.1.0/24  |  us-east-1b |  251  |
|  rango-privada-a |  10.20.10.0/24 |  us-east-1a |  251  |
|  rango-privada-b |  10.20.11.0/24 |  us-east-1b |  251  |
+------------------+----------------+-------------+-------+
```

Os 251 da última coluna são os cinco reservados em ação. A ordem das linhas pode variar.

### O Internet Gateway e as rotas

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=rango-igw},{Key=Projeto,Value=rango}]' \
  --query InternetGateway.InternetGatewayId --output text)

aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
```

Agora a route table pública, com a rota padrão para o Internet Gateway, associada às duas subnets públicas:

```bash
RT_PUB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=rango-rt-publica},{Key=Projeto,Value=rango}]' \
  --query RouteTable.RouteTableId --output text)

aws ec2 create-route --route-table-id "$RT_PUB" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"

for SUBNET in "$PUB_A" "$PUB_B"; do
  aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$SUBNET"
  aws ec2 modify-subnet-attribute --subnet-id "$SUBNET" --map-public-ip-on-launch
done
```

O `--map-public-ip-on-launch` faz toda instância criada nessas subnets ganhar um IPv4 público. As privadas ficam sem esse atributo.

E a route table privada, por enquanto só com a rota `local`:

```bash
RT_PRIV=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=rango-rt-privada},{Key=Projeto,Value=rango}]' \
  --query RouteTable.RouteTableId --output text)

for SUBNET in "$PRIV_A" "$PRIV_B"; do
  aws ec2 associate-route-table --route-table-id "$RT_PRIV" --subnet-id "$SUBNET"
done
```

Por que criar uma route table privada, se a main route table da VPC também só tem a rota `local`? Porque a associação explícita deixa a intenção registrada. Se alguém um dia acrescentar uma rota para o Internet Gateway na main route table, as subnets privadas continuam privadas.

Já que a route table privada existe, acrescente o gateway endpoint do S3. Ele não cobra e vai servir às fotos dos pratos no próximo capítulo:

```bash
aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" \
  --vpc-endpoint-type Gateway \
  --service-name com.amazonaws.us-east-1.s3 \
  --route-table-ids "$RT_PRIV" \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=rango-s3},{Key=Projeto,Value=rango}]' \
  --query VpcEndpoint.VpcEndpointId --output text
```

### Os Security Groups

Três grupos: o da API, o do banco e o dos endpoints.

```bash
criar_sg() {
  aws ec2 create-security-group --vpc-id "$VPC_ID" \
    --group-name "$1" --description "$2" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$1},{Key=Projeto,Value=rango}]" \
    --query GroupId --output text
}

SG_WEB=$(criar_sg rango-web "HTTP publico da API do Rango")
SG_DB=$(criar_sg rango-db "Postgres do Rango, so a partir da API")
SG_ENDP=$(criar_sg rango-endpoints "HTTPS da VPC para os VPC endpoints")

aws ec2 authorize-security-group-ingress --group-id "$SG_WEB" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress --group-id "$SG_DB" \
  --protocol tcp --port 5432 --source-group "$SG_WEB"

aws ec2 authorize-security-group-ingress --group-id "$SG_ENDP" \
  --protocol tcp --port 443 --cidr 10.20.0.0/16
```

As descrições continuam sem acento, pelo mesmo `InvalidParameterValue` do capítulo 9. Repare na regra do banco: nenhum CIDR, só o grupo `rango-web` como origem. O `rango-web` é um grupo novo, com outro ID, porque Security Groups pertencem a uma VPC e não atravessam para outra.

### A API na subnet pública

O comando é o do capítulo 9 com dois acréscimos: `--subnet-id` e o grupo novo.

```bash
API_ID=$(aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --instance-type t3.micro \
  --credit-specification CpuCredits=standard \
  --subnet-id "$PUB_A" \
  --security-group-ids "$SG_WEB" \
  --iam-instance-profile Name=rango-ec2 \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":10,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
  --user-data file://infra/ec2/user-data.sh \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=rango-api-01},{Key=Projeto,Value=rango}]' \
    'ResourceType=volume,Tags=[{Key=Projeto,Value=rango}]' \
  --query "Instances[0].InstanceId" --output text)
```

Se quiser o Rangô completo rodando nela, repita a seção "Trazendo o código" do capítulo 9; nada muda ali. Para este capítulo, basta a máquina.

### O NAT Gateway, por uma hora

O banco precisa de saída para instalar o PostgreSQL e para o SSM Agent se registrar. Crie o NAT Gateway antes da instância, na subnet pública `a`:

```bash
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=rango-nat-a},{Key=Projeto,Value=rango}]' \
  --query AllocationId --output text)

NAT_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUB_A" --allocation-id "$EIP_ALLOC" \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=rango-nat-a},{Key=Projeto,Value=rango}]' \
  --query NatGateway.NatGatewayId --output text)

aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID"

aws ec2 create-route --route-table-id "$RT_PRIV" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID"
```

A partir do `create-nat-gateway`, o relógio está correndo. O `wait` costuma levar de um a dois minutos.

### O PostgreSQL na subnet privada

Crie `infra/ec2/user-data-db.sh`:

```bash
#!/bin/bash
set -euxo pipefail

dnf install -y postgresql17-server
postgresql-setup --initdb
systemctl enable --now postgresql
```

O Amazon Linux 2023 tem o PostgreSQL 17 no repositório oficial, a mesma versão do `postgres:17-alpine` que o Compose usava no capítulo 6. Suba a instância na subnet privada:

```bash
DB_ID=$(aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --instance-type t3.micro \
  --credit-specification CpuCredits=standard \
  --subnet-id "$PRIV_A" \
  --security-group-ids "$SG_DB" \
  --iam-instance-profile Name=rango-ec2 \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":10,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
  --user-data file://infra/ec2/user-data-db.sh \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=rango-db-01},{Key=Projeto,Value=rango}]' \
    'ResourceType=volume,Tags=[{Key=Projeto,Value=rango}]' \
  --query "Instances[0].InstanceId" --output text)

aws ec2 wait instance-running --instance-ids "$API_ID" "$DB_ID"

aws ec2 describe-instances --instance-ids "$API_ID" "$DB_ID" \
  --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,PublicIpAddress,PrivateIpAddress]" \
  --output text
```

```text
rango-api-01	198.51.100.41	10.20.0.183
rango-db-01	None	10.20.10.57
```

O banco não tem IP público. Não existe endereço na internet que leve até ele, e nenhuma regra de Security Group muda isso.

Espere o SSM Agent ficar `Online`, como no capítulo 9, e entre no banco:

```bash
aws ssm start-session --target "$DB_ID"
```

Dentro da sessão, confira por onde a instância sai para a internet:

```bash
curl -s https://checkip.amazonaws.com
```

```text
203.0.113.80
```

Esse endereço é o Elastic IP do NAT Gateway. Para o mundo, todas as máquinas das subnets privadas aparecem com esse endereço, como os aparelhos da sua casa aparecem com o IP do roteador.

Agora configure o Postgres para aceitar conexões da VPC. Ainda como `ssm-user`:

```bash
sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses = '*';"
sudo -u postgres psql -c "CREATE ROLE rango LOGIN;"
sudo -u postgres psql -c "CREATE DATABASE rango OWNER rango;"
sudo -u postgres psql -c "\password rango"
```

O `\password` pede a senha duas vezes, no terminal, e grava só o hash. A senha não passa pelo histórico do shell nem por nenhum arquivo. Guarde-a no seu gerenciador de senhas por enquanto. O capítulo 16 tira as senhas dos arquivos e as leva para cofres gerenciados: o Parameter Store fica com a configuração, e o Secrets Manager, com a senha do banco, que passa a girar sozinha.

O `listen_addresses = '*'` parece assustador depois da cena do início do capítulo, mas aqui o `*` quer dizer "todas as interfaces da máquina", e a única interface tem o IP `10.20.10.57`, inalcançável de fora da VPC. Mesmo assim, restrinja também no `pg_hba.conf`, a camada de autorização do próprio Postgres:

```bash
echo "host    rango    rango    10.20.0.0/16    scram-sha-256" \
  | sudo tee -a /var/lib/pgsql/data/pg_hba.conf
sudo systemctl restart postgresql
```

Agora são três camadas, cada uma com uma função: a subnet privada impede que a internet chegue; o Security Group `rango-db` restringe a quem está no `rango-web`; o `pg_hba.conf` exige usuário, banco e senha.

### O teste que importa

Abra outra sessão, desta vez na API, e instale só o cliente do Postgres:

```bash
aws ssm start-session --target "$API_ID"
```

```bash
sudo dnf install -y postgresql17
psql "host=10.20.10.57 dbname=rango user=rango" -c "SELECT version();"
```

```text
Password for user rango:
                   version
--------------------------------------------------
 PostgreSQL 17.6 on x86_64-amazon-linux-gnu, ...
(1 row)
```

A versão exata do patch vai variar. O importante é que a API, no grupo `rango-web`, chega ao banco. Agora veja o que acontece se ela sair do grupo. No seu terminal, troque temporariamente o Security Group da API por outro qualquer da VPC, como o `rango-endpoints`:

```bash
aws ec2 modify-instance-attribute --instance-id "$API_ID" --groups "$SG_ENDP"
```

Na sessão da API, o mesmo `psql` agora fica parado até desistir:

```text
psql: error: connection to server at "10.20.10.57", port 5432 failed: Connection timed out
	Is the server running on that host and accepting TCP/IP connections?
```

Um *timeout*: o pacote foi descartado em silêncio pelo Security Group do banco, como você aprendeu a distinguir no capítulo 1. Devolva o grupo certo:

```bash
aws ec2 modify-instance-attribute --instance-id "$API_ID" --groups "$SG_WEB"
```

### Trocando o NAT por endpoints

O banco já tem o que precisa instalado. A partir daqui, a única saída que ele usa é a do Session Manager. Em vez de pagar um NAT Gateway por mês para isso, crie os três endpoints de interface, só na subnet privada `a`, onde o banco está:

```bash
for SERVICO in ssm ssmmessages ec2messages; do
  aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" \
    --vpc-endpoint-type Interface \
    --service-name "com.amazonaws.us-east-1.$SERVICO" \
    --subnet-ids "$PRIV_A" \
    --security-group-ids "$SG_ENDP" \
    --private-dns-enabled \
    --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=rango-$SERVICO},{Key=Projeto,Value=rango}]" \
    --query VpcEndpoint.VpcEndpointId --output text
done
```

Quando os três estiverem `available` (confira com `aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values="$VPC_ID" --query "VpcEndpoints[].[ServiceName,State]" --output table`), remova a rota do NAT e destrua o gateway:

```bash
aws ec2 delete-route --route-table-id "$RT_PRIV" --destination-cidr-block 0.0.0.0/0
aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID"
aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_ID"
aws ec2 release-address --allocation-id "$EIP_ALLOC"
```

O Elastic IP só pode ser liberado depois que o NAT Gateway termina de ser apagado; por isso o `wait` no meio. Esquecer o `release-address` deixa um IP cobrando US$ 3,65 por mês sem fazer nada.

Abra uma sessão nova no banco. Ela abre normalmente, agora pelos endpoints. O SSM Agent detecta a mudança sozinho, mas pode levar alguns minutos; se a instância aparecer `ConnectionLost`, um reboot acelera. Dentro da sessão, tente a internet:

```bash
curl -s -m 5 https://checkip.amazonaws.com || echo "sem saida"
```

```text
sem saida
```

Dentro da VPC, o nome do Systems Manager agora resolve para um IP privado:

```bash
getent hosts ssm.us-east-1.amazonaws.com
```

```text
10.20.10.92     ssm.us-east-1.amazonaws.com
```

O banco do Rangô não recebe conexões da internet e também não consegue abrir nenhuma. O que ele alcança é a API, o próprio S3 pelo gateway endpoint e o Systems Manager pelos endpoints de interface.

O preço dessa pureza aparece no primeiro `dnf upgrade`: sem NAT, não há atualização. Você teria de recriar o NAT por uma hora a cada janela de manutenção, ou manter um. Esse trabalho de cuidar de um banco numa EC2, com atualizações, backups e discos, é o assunto do capítulo 12.

### Quanto isso custa e o que destruir

Com preços de referência em `us-east-1`, outubro de 2026:

| Recurso | Custo aproximado | Destino |
|---------|------------------|---------|
| VPC, subnets, route tables, IGW, SGs | Zero | Ficam |
| Gateway endpoint do S3 | Zero | Fica |
| NAT Gateway + Elastic IP (uma hora) | ~US$ 0,05 | Já destruídos |
| 3 endpoints de interface em 1 AZ | ~US$ 0,03/h (~US$ 22/mês) | Destruir |
| 2 instâncias `t3.micro` + 2 volumes de 10 GiB | Créditos ou free tier | Destruir |
| IPv4 público da API | US$ 0,005/h | Vai com a instância |

A rede fica, porque não cobra nada e o RDS do capítulo 12 vai morar nas subnets privadas dela. O que cobra por hora vai embora:

```bash
aws ec2 terminate-instances --instance-ids "$API_ID" "$DB_ID"
aws ec2 wait instance-terminated --instance-ids "$API_ID" "$DB_ID"

for ENDP in $(aws ec2 describe-vpc-endpoints \
    --filters Name=vpc-id,Values="$VPC_ID" Name=vpc-endpoint-type,Values=Interface \
    --query "VpcEndpoints[].VpcEndpointId" --output text); do
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$ENDP"
done
```

Por fim, confira no console da VPC, em **NAT gateways** e em **Elastic IPs**, que nada sobrou. Um NAT apagado aparece como `Deleted` por um tempo e não cobra.

## Armadilhas e casos reais

> **Armadilha:** O NAT Gateway cobra por hora mesmo sem tráfego, e ninguém olha para ele depois de criado. Um ambiente de homologação com um NAT por AZ em três AZs custa perto de US$ 100 por mês só de existir. Em contas de estudo, crie o NAT quando precisar e apague ao terminar. Quando o capítulo 15 trouxer o AWS CDK, preste atenção: o construto `Vpc` cria, por padrão, um NAT Gateway por AZ. O parâmetro `nat_gateways` reduz esse número.

> **Armadilha:** Tráfego para o S3 pelo NAT paga US$ 0,045 por GB. Numa situação hipotética, um worker numa subnet privada que reprocessa 5 TB de fotos por mês gera cerca de US$ 225 só de processamento no NAT. O gateway endpoint do S3 leva esse número a zero e se cria com um único comando. Não há motivo para uma VPC com subnets privadas ficar sem ele.

> **Armadilha:** Uma faixa CIDR escolhida às pressas é para sempre. `10.0.0.0/16` em todas as VPCs da empresa parece inofensivo até o dia de conectar duas delas, quando o peering é recusado por sobreposição e a única saída é migrar uma rede inteira. Anote as faixas de cada VPC numa planilha ou no README da infraestrutura, e nunca repita uma.

> **Armadilha:** Esquecer as portas efêmeras numa NACL personalizada. Uma NACL nova nega tudo, nos dois sentidos, até receber regras. Liberar a entrada na 443 sem liberar a saída para `1024-65535` gera timeouts que parecem defeito do Security Group. Se você ainda não precisa de NACL, não mexa nela.

> **Armadilha:** Instância "privada" numa subnet pública. Uma instância sem IP público numa subnet cuja route table aponta para o Internet Gateway fica inalcançável hoje, mas basta alguém associar um Elastic IP para ela aparecer na internet. Quem define se uma máquina é privada é a route table da subnet dela.

> **Na vida real:** As cotas padrão por região surpreendem quem cria ambientes demais: 5 VPCs, 5 Elastic IPs e 5 NAT Gateways por AZ. Por VPC, são 200 subnets e 60 regras de entrada por Security Group. Todas podem ser aumentadas pelo Service Quotas, mas o pedido leva tempo. Descobrir o limite de Elastic IPs no meio de um deploy é uma forma desagradável de aprender.

## Resumo

- A VPC é uma rede privada isolada numa região. Ela, as subnets, as route tables, o Internet Gateway, os Security Groups e as NACLs não cobram nada.
- O CIDR da VPC vai de `/16` a `/28`, não muda de tamanho e não deve se sobrepor a outras redes com que ela vá conversar. O Rangô usa `10.20.0.0/16`, longe de `10.0.0.0/16`, `172.31.0.0/16` e `172.17.0.0/16`.
- Cada subnet vive numa AZ e perde cinco endereços para a AWS. Alta disponibilidade exige subnets em pelo menos duas AZs.
- Uma subnet é pública quando a route table dela tem `0.0.0.0/0` para o Internet Gateway. Sem essa rota, ela é privada, e nada da internet chega, qualquer que seja o Security Group.
- O NAT Gateway dá saída às subnets privadas sem permitir entrada. Cobra por hora e por GB, vive numa AZ e, em produção, costuma ser um por AZ. O NAT Gateway regional, de novembro de 2025, cobre várias AZs com um único recurso.
- Security Groups são stateful, só permitem e podem usar outro grupo como origem. NACLs são stateless, aceitam negação, valem para a subnet inteira e exigem regras para as portas efêmeras.
- Gateway endpoints (S3, DynamoDB) são gratuitos. Endpoints de interface cobram por hora por AZ e por GB, e o Session Manager sem internet precisa de três.
- O Rangô ganhou a `rango-vpc`, com duas subnets públicas e duas privadas, o banco ficou atrás de três camadas (subnet, Security Group e `pg_hba.conf`), e só a rede, que é gratuita, continua de pé.

## As fotos que não cabem no disco

Com a rede pronta, o Rangô voltou a crescer. Os restaurantes querem mostrar os pratos, e a primeira versão do upload salva as fotos em `/opt/rango/fotos`, no disco da instância. A Cantina da Nona sozinha mandou 340 fotos tiradas no celular, de 4 MB cada. O volume de 10 GiB começa a encher, e em breve o `df -h` vai mostrar 100%.

Aumentar o disco adia o problema. Mas o capítulo 4 já avisou: quando a API tiver três instâncias atrás de um load balancer, uma foto enviada para a primeira não existe na segunda. E toda foto que o React exibe passa pelo Uvicorn, ocupando um processo Python para servir bytes estáticos. No próximo capítulo, as fotos saem do servidor e vão para o Amazon S3, com buckets, classes de armazenamento e uploads que vão direto do navegador para a AWS sem passar pela API. Você também vai ver por que tantas empresas acabaram nas manchetes por causa de um bucket esquecido aberto.

## Referências

- Amazon VPC, guia do usuário: https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html
- Blocos CIDR de VPC (tamanhos, faixas recomendadas e restrições): https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html
- Cotas da Amazon VPC: https://docs.aws.amazon.com/vpc/latest/userguide/amazon-vpc-limits.html
- Network ACLs: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html
- Preços da Amazon VPC (NAT Gateway, IPv4 público, tráfego): https://aws.amazon.com/vpc/pricing/
- Preços do AWS PrivateLink (endpoints de interface): https://aws.amazon.com/privatelink/pricing/
- Lançamento do NAT Gateway regional (novembro de 2025): https://aws.amazon.com/about-aws/whats-new/2025/11/aws-nat-gateway-regional-availability
- AWS CLI, `create-nat-gateway`: https://docs.aws.amazon.com/cli/latest/reference/ec2/create-nat-gateway.html
- AWS re:Post, NAT Gateway regional: https://www.repost.aws/articles/AR77CnVH2zR6KjoD4SvgNVAQ/understanding-amazon-vpc-regional-nat-gateway
- AWS re:Post, endpoints de VPC para o Systems Manager: https://www.repost.aws/knowledge-center/systems-manager-vpc-connectivity
- Cobrança de IPv4 público: https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/
- AWS CDK v2, `VpcProps` (NAT por AZ): https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_ec2/VpcProps.html
- PostgreSQL 17 no Amazon Linux 2023 (pacote `postgresql17`): https://computingforgeeks.com/how-to-install-postgresql-17-on-amazon-linux/
- PostgreSQL, `pg_hba.conf`: https://www.postgresql.org/docs/17/auth-pg-hba-conf.html
- Ataque "Meow" (BleepingComputer): https://www.bleepingcomputer.com/news/security/new-meow-attack-has-deleted-almost-4-000-unsecured-databases/
