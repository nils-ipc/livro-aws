# EC2: seu primeiro servidor

No capítulo anterior, você parou de usar o root e passou a entrar na AWS com o usuário `dev-rango`, pelo IAM Identity Center, com credenciais temporárias nos perfis `rango-dev` e `rango-admin`. No fim, criou a role `rango-ec2`, com a policy `AmazonSSMManagedInstanceCore`, e o instance profile que a embrulha. Ela ficou esperando um servidor. Agora ele vai existir.

## O notebook que precisa dormir

Até aqui, o Rangô inteiro roda no Docker Compose do seu notebook: API, Redis, workers, Nginx. Funciona bem enquanto a tampa está aberta. A sua sócia em Recife quer mostrar o app para o dono da Cantina da Nona numa terça às 22h, e nesse horário o seu notebook está fechado na mochila.

Mesmo com o notebook aberto, a conta não fecha. Lembra do capítulo 1? A sua conexão de casa provavelmente está atrás de CGNAT, o IP que o mundo vê é compartilhado com outros clientes do provedor, e nenhuma conexão de fora chega até a sua máquina sem um pedido seu antes. O roteador reinicia, o IP muda, o Windows decide instalar atualizações às 3h.

O que o Rangô precisa é simples de descrever: um computador ligado o tempo todo, num lugar com energia e rede redundantes, com um IP público que aceite conexões de qualquer lugar. Você poderia comprar um servidor e alugar espaço num data center. Poderia contratar uma VPS de um provedor pequeno. Ou poderia pedir um à AWS por uma chamada de API e começar a usá-lo em menos de dois minutos. Este capítulo segue o terceiro caminho, e vai fazer tudo à mão, de propósito, para você sentir o peso de cada passo.

## O que a AWS aluga quando você pede um servidor

O **Amazon EC2** (Elastic Compute Cloud) aluga máquinas virtuais. Cada máquina alugada se chama **instância**. No capítulo 3 você viu que um hypervisor fatia uma máquina física em várias VMs. A AWS faz exatamente isso, com um hypervisor próprio (o Nitro) e hardware dedicado para rede e disco, de modo que quase toda a CPU da máquina física fica para os clientes.

A cobrança das instâncias Linux é por segundo, com mínimo de 60 segundos, enquanto a instância está no estado *running*. Uma instância parada (*stopped*) não cobra CPU nem memória, mas o disco dela continua cobrando, como você vai ver adiante.

Para criar uma instância, você responde a poucas perguntas: que tamanho de máquina, que sistema operacional, como você vai entrar nela, quem pode falar com ela pela rede, o que ela faz ao ligar e quanto disco ela tem. Cada uma dessas perguntas corresponde a um conceito do EC2.

### Tipos e famílias de instância

O tamanho da máquina é o **tipo de instância**. O nome segue um padrão que parece críptico até você aprender a ler. Veja `t3.micro`:

- `t` é a **família**: o perfil de uso para o qual a máquina foi pensada.
- `3` é a **geração**: números maiores são hardware mais novo, em geral mais barato pelo mesmo desempenho.
- `micro` é o **tamanho**: quantas vCPUs e quanta memória.

Entre a geração e o ponto podem aparecer letras de atributos. As mais comuns são `g` (processador Graviton, da própria AWS, arquitetura Arm), `i` (Intel), `a` (AMD) e `d` (disco local NVMe). Assim, `t4g.small` é a família T, quarta geração, Graviton, tamanho small. `m7i-flex.large` é a família M, sétima geração, Intel, na variante flex.

As famílias que você vai encontrar com mais frequência:

| Família | Para que serve | Proporção memória por vCPU |
|---------|----------------|----------------------------|
| T | uso intermitente, com picos curtos (sites pequenos, ambientes de teste) | variável |
| M | uso geral, equilibrado | 4 GiB |
| C | CPU intensa (processamento, codificação de vídeo) | 2 GiB |
| R | muita memória (bancos de dados, caches) | 8 GiB |

A família T merece atenção, porque é a mais usada por quem está começando e a que mais surpreende. Ela é *burstable*: a instância tem direito a uma fração da CPU (a linha de base) e acumula **créditos de CPU** enquanto fica abaixo dessa linha. Quando a carga sobe, ela gasta os créditos e pode usar 100% da vCPU por um tempo. É como um plano de celular com franquia que acumula.

O que acontece quando os créditos acabam depende do modo. No modo *standard*, a CPU volta à linha de base, e a sua API fica lenta. No modo *unlimited*, a instância continua usando CPU acima da linha de base e a AWS cobra pelo excedente. As instâncias T3 sobem em modo unlimited por padrão. Para um servidor de estudo, prefira standard: lentidão você nota, cobrança extra você só descobre na fatura.

Lembra do erro `exec format error` do capítulo 3, quando uma imagem feita para amd64 rodou num Mac arm64? A mesma questão aparece aqui. Instâncias Graviton (`t4g`, `m7g` e similares) são Arm e costumam sair mais baratas pelo mesmo desempenho. Para o Rangô em Python puro, a diferença é invisível, porque as dependências têm *wheels* para as duas arquiteturas. Para começar, vamos de x86_64, que é a arquitetura do seu notebook (salvo se você usa um Mac com Apple Silicon) e evita uma variável a mais no primeiro deploy.

### O free tier no EC2

O que entra no free tier depende de quando a conta foi criada. Contas criadas antes de 15 de julho de 2025 têm o modelo antigo, de 12 meses, em que `t2.micro` e `t3.micro` são elegíveis. Contas criadas a partir dessa data, como a `rango-estudos` do capítulo 7, funcionam com créditos: US$ 100 no cadastro e até US$ 100 a mais ao completar algumas atividades, por até seis meses. Nelas, os tipos elegíveis são `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, `c7i-flex.large` e `m7i-flex.large`. Você pode conferir a lista na sua conta pela CLI, como vai fazer daqui a pouco.

O Rangô vai rodar numa `t3.micro`: 2 vCPUs, 1 GiB de memória. É pouco, mas suficiente para a API, dois workers e o cache, e é elegível nos dois modelos.

### AMI: o sistema operacional de fábrica

Uma instância nasce de uma **AMI** (Amazon Machine Image): um molde com o sistema operacional instalado e o disco inicial pronto. Pense numa imagem Docker, só que de uma máquina inteira, com kernel e tudo. A AWS publica AMIs próprias, fabricantes de sistemas publicam as deles (Ubuntu, Debian, Red Hat) e você pode criar as suas a partir de uma instância configurada.

Vamos usar o **Amazon Linux 2023** (AL2023), a distribuição da própria AWS. Ela usa `dnf` como gerenciador de pacotes, tem suporte previsto até junho de 2029, e o agente de que vamos precisar para entrar na máquina já vem instalado. A versão anterior, o Amazon Linux 2, chegou ao fim do suporte em 30 de junho de 2026. Muitos tutoriais na internet ainda usam o AL2 e comandos como `amazon-linux-extras`, que não existem no AL2023. Se um tutorial manda rodar `yum install` e `amazon-linux-extras`, ele é do sistema antigo.

Cada AMI tem um ID, como `ami-0abcd1234ef567890`, e esse ID muda a cada nova versão. A AWS marca cada AMI do AL2023 como obsoleta 90 dias depois do lançamento. Por isso, nunca escreva um ID de AMI fixo num script. A AWS mantém um parâmetro público no Systems Manager Parameter Store que sempre aponta para a AMI mais recente:

```text
/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
```

Para Graviton, troque o final por `arm64`. Na hora de criar a instância, você passa `resolve:ssm:` seguido desse caminho, e a AWS resolve o ID na hora. É o equivalente a depender de `python:3.12-slim` em vez de um digest fixo, com a diferença de que aqui você quer mesmo a versão mais nova.

> **Na vida real:** Muita gente escolhe Ubuntu no EC2 porque o Ubuntu 24.04 já vem com Python 3.12. O AL2023 traz o 3.9 como `python3` padrão e oferece o 3.12 como pacote separado (`python3.12`), que você vai instalar logo mais.

### Como você entra na máquina

A pergunta parece trivial e é a que mais causa incidentes. O jeito tradicional é SSH com um **key pair**: a AWS guarda a chave pública, coloca-a no servidor na criação, e você baixa um arquivo `.pem` com a chave privada. Para entrar, você abre a porta 22 no firewall e roda `ssh -i rango.pem ec2-user@IP`.

Funciona, e tem três problemas. A porta 22 aberta para a internet recebe tentativas de login de robôs minutos depois de a instância subir. O `.pem` é uma credencial de longa duração que mora num arquivo, e você já viu no capítulo 8 o que acontece com credenciais de longa duração em arquivos. E, se três pessoas usam a mesma chave, ninguém sabe quem entrou e fez o quê.

A alternativa é o **Session Manager**, parte do AWS Systems Manager. Um agente instalado na instância (o SSM Agent) abre uma conexão de saída, por HTTPS na porta 443, até os endpoints do Systems Manager. Quando você pede uma sessão, a AWS confere as suas permissões no IAM e encaminha o terminal por essa conexão. Nenhuma porta de entrada fica aberta, não existe chave para perder, e cada sessão fica registrada com o nome de quem a abriu.

Para funcionar, três coisas precisam existir:

1. O SSM Agent rodando na instância (vem na AMI do AL2023).
2. Um instance profile com uma role que tenha a policy `AmazonSSMManagedInstanceCore`. É a `rango-ec2` do capítulo 8.
3. Saída HTTPS da instância até os endpoints do Systems Manager, seja pela internet, seja por VPC endpoints (capítulo 10).

Do seu lado, você precisa do Session Manager plugin instalado junto da AWS CLI. O livro não usa key pair em lugar nenhum.

### Security Group: o primeiro contato

Quem pode falar com a instância pela rede é decidido pelo **Security Group**, um firewall virtual ligado à placa de rede da instância. Pense nele como um middleware de autorização que roda antes da sua aplicação, só que no nível de pacotes: ele olha protocolo, porta e origem, e decide se a conexão entra.

Três características explicam quase todo o comportamento dele:

- Só existem regras de permissão. Tudo o que nenhuma regra libera fica bloqueado, como o implicit deny do IAM.
- Ele é *stateful*: se uma conexão de entrada foi permitida, a resposta sai sem precisar de regra de saída. E se a instância abre uma conexão de saída, a resposta volta sem regra de entrada.
- A origem de uma regra pode ser uma faixa CIDR (`0.0.0.0/0` é a internet inteira, `198.51.100.7/32` é um único IP) ou outro Security Group.

Um Security Group recém-criado não aceita nenhuma entrada e permite toda a saída. Se você criar uma instância sem dizer qual grupo usar, ela entra no Security Group *default* da VPC, que só aceita tráfego de instâncias do próprio grupo. Na prática, nada de fora consegue chegar. O capítulo 10 volta a esse assunto com a rede completa, e lá você vai comparar o Security Group com as Network ACLs.

### User data: o script do primeiro boot

Ao criar a instância, você pode entregar um script chamado **user data**. Na primeira inicialização, o *cloud-init*, um programa que vem na AMI, executa esse script como root. É o lugar natural para instalar pacotes e criar usuários, coisas que você faria em todo servidor novo.

Dois detalhes evitam muita confusão. O user data roda só no primeiro boot: se você parar a instância, editar o script e ligá-la de novo, nada é reexecutado. E o conteúdo fica legível de dentro da instância pelo *Instance Metadata Service* (IMDS), um endereço HTTP local que qualquer processo da máquina consegue consultar. Qualquer senha colocada ali pode ser lida por qualquer processo da máquina. Segredos vão para um cofre gerenciado, assunto do capítulo 16: o Parameter Store para a configuração e o Secrets Manager para a senha do banco, que precisa girar. O limite de tamanho é 16 KB, o que é suficiente para um script de instalação.

### EBS: um disco que mora na rede

O disco da instância é um volume **EBS** (Elastic Block Store). Para o sistema operacional ele se comporta como um disco comum, mas fisicamente está em outro lugar do data center, ligado à instância pela rede. Isso tem consequências práticas:

- O volume sobrevive quando a instância é parada. Você desliga a máquina, liga de novo, e os arquivos estão lá.
- O volume pertence a uma zona de disponibilidade. Uma instância em `us-east-1a` não monta um volume de `us-east-1b`.
- Você paga pelo tamanho provisionado, esteja a instância ligada ou não.
- Você pode tirar *snapshots*, cópias de um momento guardadas pela AWS, e criar volumes novos a partir delas.

O tipo padrão hoje é o `gp3`. Ele custa cerca de US$ 0,08 por GB-mês e inclui 3.000 IOPS e 125 MiB/s de vazão sem custo adicional (us-east-1, consulta de outubro de 2026; confira a página de preços do EBS). Um disco de 10 GiB sai por uns US$ 0,80 por mês.

Uma opção do volume decide o que acontece quando a instância é destruída (*terminated*): `DeleteOnTermination`. Com `true`, o volume vai junto com a instância. Com `false`, ele fica órfão, cobrando todo mês, até alguém lembrar dele. Vamos declarar o valor explicitamente na criação, para não depender do padrão.

## Mão na massa: o Rangô no EC2

O plano é este: criar um Security Group que libere só a porta 80, escrever o script de user data, subir a instância com a role `rango-ec2`, entrar pelo Session Manager e instalar o Rangô à mão, com systemd e Nginx, como no capítulo 3. Desta vez a máquina fica num data center, com IP público.

### Pré-requisitos

- AWS CLI v2 com o perfil `rango-dev` do capítulo 8, região `us-east-1`.
- Session Manager plugin instalado. A página da documentação tem instaladores para Windows, macOS e Linux. Confira com:

```bash
session-manager-plugin --version
```

- O repositório do Rangô no GitHub, com o backend em `backend/`.

Faça login e confira quem você é antes de criar qualquer coisa:

```bash
export AWS_PROFILE=rango-dev
aws sso login
aws sts get-caller-identity --query Arn --output text
```

```text
arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_PowerUserAccess_0a1b2c3d4e5f6a7b/dev-rango
```

Agora confira os tipos de instância elegíveis no free tier da sua conta:

```bash
aws ec2 describe-instance-types \
  --filters Name=free-tier-eligible,Values=true \
  --query "InstanceTypes[*].[InstanceType]" \
  --output text | sort
```

Se a `t3.micro` aparece na lista, siga em frente.

### O Security Group

Toda conta vem com uma **VPC default** em cada região, uma rede pronta com uma subnet pública por zona de disponibilidade. Ela existe para que você consiga criar uma instância sem antes desenhar uma rede. Vamos usá-la neste capítulo e substituí-la no próximo.

```bash
VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=is-default,Values=true \
  --query "Vpcs[0].VpcId" --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name rango-web \
  --description "HTTP publico da API do Rango" \
  --vpc-id "$VPC_ID" \
  --query GroupId --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

echo "$SG_ID"
```

Repare na descrição sem acento. O campo de descrição do Security Group aceita só um conjunto restrito de caracteres ASCII, e um "Rangô" ali faz o comando falhar com `InvalidParameterValue`.

Note também o que ficou de fora: nenhuma regra para a porta 22. O grupo aceita HTTP de qualquer lugar e mais nada. A saída continua liberada, e é por ela que o SSM Agent, o `dnf` e o `git` vão falar com o mundo.

### O script de user data

Na raiz do repositório, crie `infra/ec2/user-data.sh`:

```bash
#!/bin/bash
set -euxo pipefail

dnf install -y nginx git python3.12 python3.12-pip valkey
systemctl enable --now valkey nginx

useradd --system --create-home --home-dir /opt/rango \
  --shell /sbin/nologin rango
install -d -o root -g rango -m 750 /etc/rango
```

O script instala o Nginx, o git, o Python 3.12 e o **Valkey**, o fork do Redis que você conheceu no capítulo 4. No AL2023, o Valkey é o substituto do antigo pacote `redis6`, e fala o mesmo protocolo: o cliente `redis` do Python conecta sem mudança. A configuração padrão dele escuta só em `127.0.0.1`, o que basta, porque só a API e os workers da própria máquina falam com ele.

O `set -euxo pipefail` faz o script parar no primeiro erro e registrar cada comando executado. Sem ele, um `dnf` que falha passa em silêncio e você só descobre na hora de rodar o Python.

### Subindo a instância (e tropeçando no IAM)

Com o grupo e o script prontos, crie a instância:

```bash
aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --instance-type t3.micro \
  --credit-specification CpuCredits=standard \
  --iam-instance-profile Name=rango-ec2 \
  --security-group-ids "$SG_ID" \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":10,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
  --user-data file://infra/ec2/user-data.sh \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=rango-api-01},{Key=Projeto,Value=rango}]' \
    'ResourceType=volume,Tags=[{Key=Projeto,Value=rango}]' \
  --query "Instances[0].InstanceId" --output text
```

Cada opção responde a uma pergunta da seção anterior. Não há `--key-name`, então nenhum key pair. O `HttpTokens=required` exige a versão 2 do serviço de metadados, que você vai entender na seção de armadilhas. O volume raiz tem 10 GiB, é `gp3`, criptografado e morre junto com a instância. A tag `Name` é o nome que aparece no console.

E o resultado:

```text
An error occurred (UnauthorizedOperation) when calling the RunInstances operation:
You are not authorized to perform this operation. User: arn:aws:sts::123456789012:
assumed-role/AWSReservedSSO_PowerUserAccess_0a1b2c3d4e5f6a7b/dev-rango is not
authorized to perform: iam:PassRole on resource: arn:aws:iam::123456789012:role/rango-ec2
because no identity-based policy allows the iam:PassRole action. Encoded authorization
failure message: ...
```

(A mensagem real termina com um bloco codificado longo, omitido aqui.)

Você já viu esse filme no capítulo 8. O `PowerUserAccess` libera quase tudo no EC2, mas nada no IAM, e entregar uma role a uma instância exige `iam:PassRole`. A AWS trata isso como uma ação de IAM, porque quem pode passar uma role pode, na prática, agir como ela. A armadilha do capítulo anterior dizia para nunca liberar `PassRole` com `"Resource": "*"`. Agora é a hora de aplicar.

Entre no portal do Identity Center com o perfil de administrador, abra o permission set `PowerUserAccess`, vá em **Inline policy** e acrescente um segundo statement ao lado do `SoRegioesDoRango`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SoRegioesDoRango",
      "Effect": "Deny",
      "Action": "ec2:*",
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": ["us-east-1", "sa-east-1"]
        }
      }
    },
    {
      "Sid": "PassarSoARoleDoServidor",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::123456789012:role/rango-ec2",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    }
  ]
}
```

O `Resource` limita a uma única role, e a condição `iam:PassedToService` garante que ela só pode ser entregue ao EC2. Troque `123456789012` pelo ID da sua conta. Salve, espere o Identity Center reaplicar o permission set e faça login de novo (`aws sso login`), porque a sessão antiga ainda carrega as permissões antigas. Rode o `run-instances` outra vez:

```text
i-0a1b2c3d4e5f67890
```

Guarde o ID numa variável e espere a instância ficar pronta:

```bash
INSTANCE_ID=i-0a1b2c3d4e5f67890
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].[State.Name,Placement.AvailabilityZone,PublicIpAddress,PrivateIpAddress]" \
  --output text
```

```text
running	us-east-1c	198.51.100.23	172.31.23.104
```

Repare nos dois endereços. O `172.31.23.104` é privado, da faixa `172.16.0.0/12` do capítulo 1, e é o endereço que a instância enxerga em si mesma. O `198.51.100.23` é o público, e quem faz a tradução entre os dois é a rede da AWS, num NAT de um para um. Se você rodar `ip addr` dentro da instância, o IP público não aparece em lugar nenhum.

Uma instância *running* ainda pode estar no meio do boot. O SSM Agent precisa subir e se registrar antes de aceitar sessões. Confira:

```bash
aws ssm describe-instance-information \
  --filters Key=InstanceIds,Values="$INSTANCE_ID" \
  --query "InstanceInformationList[0].PingStatus" --output text
```

Quando a resposta for `Online`, a instância está pronta para receber você. Se depois de uns cinco minutos ela ainda não aparecer, as causas costumam ser duas: o instance profile não foi associado, ou a instância não consegue sair para a internet na porta 443.

### Entrando sem abrir a porta 22

```bash
aws ssm start-session --target "$INSTANCE_ID"
```

```text
Starting session with SessionId: dev-rango-0f1e2d3c4b5a69788
sh-5.2$
```

Você está dentro, e o Security Group não tem nenhuma regra de SSH. A sessão abre como o usuário `ssm-user`, num `sh`. Vire root e confira se o user data terminou:

```bash
sudo -i
cloud-init status --wait
```

```text
status: done
```

Se aparecer `status: error`, o script de user data falhou em algum comando. Com o `set -x`, cada comando executado ficou registrado no log do cloud-init, e o último antes do erro é o culpado.

Confira também que os serviços do script estão de pé:

```bash
systemctl is-active nginx valkey
valkey-cli ping
python3.12 --version
```

```text
active
active
PONG
Python 3.12.12
```

A versão exata do patch do Python vai variar conforme a data da AMI.

### Trazendo o código

O código está no GitHub. Para o servidor ler o repositório sem que você coloque um token pessoal na máquina, use uma **deploy key**: uma chave SSH que dá acesso de leitura a um único repositório. A chave privada vai ser gerada dentro do servidor e nunca sai dele.

```bash
cd /opt/rango
sudo -u rango mkdir -p -m 700 /opt/rango/.ssh
sudo -u rango ssh-keygen -t ed25519 -N "" \
  -f /opt/rango/.ssh/id_ed25519 -C "rango-api-01"
cat /opt/rango/.ssh/id_ed25519.pub
```

O `cd /opt/rango` existe por um motivo prosaico: o git aborta quando o diretório atual é ilegível para o usuário que o executa, e o `/root` é ilegível para o `rango`.

Copie a linha que começa com `ssh-ed25519`. No GitHub, abra o repositório, vá em **Settings > Deploy keys > Add deploy key**, cole a chave e deixe **Allow write access** desmarcado. Depois clone:

```bash
sudo -u rango git clone git@github.com:SEU-USUARIO/rango.git /opt/rango/codigo
```

Na primeira conexão o SSH mostra a impressão digital do servidor do GitHub e pede confirmação. Compare com as impressões digitais publicadas na documentação do GitHub antes de responder `yes`.

Agora o ambiente virtual e as dependências:

```bash
sudo -u rango python3.12 -m venv /opt/rango/venv
sudo -u rango /opt/rango/venv/bin/pip install \
  -r /opt/rango/codigo/backend/requirements.txt
```

Com 1 GiB de memória, a instalação leva um ou dois minutos.
### Configuração e serviços

A configuração da API vai num arquivo de ambiente, legível só pelo root e pelo grupo `rango`, como no capítulo 3:

```bash
cat > /etc/rango/api.env <<'EOF'
REDIS_URL=redis://127.0.0.1:6379/0
CORS_ORIGINS=http://localhost:5173
EOF
chown root:rango /etc/rango/api.env
chmod 640 /etc/rango/api.env
```

O `CORS_ORIGINS` aponta para o front local por enquanto. O React ganha casa própria, com domínio e HTTPS, no capítulo 14.

A unit do systemd é quase a mesma do capítulo 3. A diferença está nos caminhos e na dependência do Valkey. Crie `/etc/systemd/system/rango-api.service`:

```ini
[Unit]
Description=API do Rango (Uvicorn)
After=network-online.target valkey.service
Wants=network-online.target valkey.service

[Service]
User=rango
Group=rango
WorkingDirectory=/opt/rango/codigo/backend
EnvironmentFile=/etc/rango/api.env
ExecStart=/opt/rango/venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 2 --proxy-headers
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Dois processos do Uvicorn, um por vCPU, por causa do GIL que você viu no capítulo 4.

Os workers de pedidos do capítulo 5 são dois processos iguais que mudam só o grupo de consumo. O systemd tem um recurso para isso: a *template unit*. Um arquivo com `@` no nome vira um molde, e o que vier depois do `@` na hora de ativar entra no lugar de `%i`. Crie `/etc/systemd/system/rango-worker@.service`:

```ini
[Unit]
Description=Worker do Rango (grupo %i)
After=network-online.target valkey.service
Wants=network-online.target valkey.service

[Service]
User=rango
Group=rango
WorkingDirectory=/opt/rango/codigo/backend
EnvironmentFile=/etc/rango/api.env
ExecStart=/opt/rango/venv/bin/python -m app.worker %i
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

É o mesmo raciocínio de uma função com parâmetro em vez de duas funções copiadas. Ative tudo:

```bash
systemctl daemon-reload
systemctl enable --now rango-api rango-worker@restaurante rango-worker@email
systemctl is-active rango-api rango-worker@restaurante rango-worker@email
curl -s http://127.0.0.1:8000/health
```

Se algum serviço não estiver `active`, o `journalctl -u rango-api -n 50` mostra os logs em JSON do capítulo 6, com o traceback do Python.

### O Nginx na frente

Falta o proxy reverso. Crie `/etc/nginx/conf.d/rango.conf`:

```nginx
upstream rango_api {
    server 127.0.0.1:8000;
}

server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://rango_api;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 2s;
    }
}
```

O `default_server` faz este bloco atender requisições que chegam pelo IP, sem nome de host conhecido, que é como vamos acessar por enquanto. Teste e recarregue:

```bash
nginx -t && systemctl reload nginx
```

Se o `nginx -t` reclamar de `duplicate default server for 0.0.0.0:80`, é porque o `/etc/nginx/nginx.conf` da sua versão já declara um servidor padrão. Remova o `default_server` de lá e teste de novo.

### O teste que importa

Saia da sessão (`exit` duas vezes) e, do seu notebook, chame a API pelo IP público:

```bash
curl -i http://198.51.100.23/restaurantes
```

```text
HTTP/1.1 200 OK
Server: nginx/1.28.0
Content-Type: application/json
X-Rango-Instancia: ip-172-31-23-104.ec2.internal
X-Request-ID: 6f3c1a2e-...

[{"nome":"Cantina da Nona","taxa_entrega":6.9,"taxa_entrega_fmt":"R$ 6,90"},...]
```

(A versão do Nginx e os campos exatos do JSON podem variar.)

O header `X-Rango-Instancia` do capítulo 4 agora mostra o hostname da instância, que a AWS monta a partir do IP privado. A primeira chamada leva uns 300 ms, por causa do `sleep` que simula o Postgres; a segunda vem do cache no Valkey e responde bem mais rápido. Abra `http://198.51.100.23/docs` no navegador do celular, fora do Wi-Fi de casa, e a documentação interativa do FastAPI aparece. A sua sócia em Recife pode fazer o mesmo, com o seu notebook fechado.

Agora o teste que separa um servidor de um processo esquecido num terminal. Entre de novo e reinicie a máquina:

```bash
aws ssm start-session --target "$INSTANCE_ID"
sudo reboot
```

A sessão cai. Espere um minuto e rode o `curl` de novo do notebook. A API responde, porque o systemd subiu o Valkey, o Uvicorn, os workers e o Nginx na ordem certa, sem ninguém logado. No capítulo 3, fechar o SSH matava o Uvicorn com SIGHUP. Aqui, ninguém precisa estar conectado para o Rangô estar no ar.

### Quanto isso custa e como desligar

Com preços aproximados de referência em `us-east-1`, consultados em outubro de 2026, a conta fica assim:

- A instância `t3.micro` cobra por segundo enquanto está ligada. O preço por hora muda com a região e o tempo; consulte a página de preços sob demanda do EC2.
- O volume `gp3` de 10 GiB custa cerca de US$ 0,80 por mês, ligado ou desligado.
- O IPv4 público custa US$ 0,005 por hora, o que dá uns US$ 3,65 por mês se ficar ligado o mês inteiro.

Numa conta do plano gratuito, tudo isso sai dos créditos. Numa conta antiga dentro dos 12 meses, a instância e 750 horas de IPv4 público entram na franquia. De qualquer forma, o alarme de cobrança do capítulo 7 está de olho.

O código de criação está todo no repositório (`infra/ec2/user-data.sh` e os comandos acima), e o servidor vai mudar de rede no próximo capítulo. Por isso, a recomendação é destruir tudo ao terminar os testes:

```bash
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
aws ec2 delete-security-group --group-id "$SG_ID"
```

O volume vai junto, por causa do `DeleteOnTermination`. Remova também a deploy key no GitHub. A role `rango-ec2` e o statement de `PassRole` ficam, porque vão servir de novo.

Se preferir manter o servidor por uns dias, `aws ec2 stop-instances` interrompe a cobrança da instância e libera o IPv4 público. Ao ligar de novo, ela volta com outro IP.

## Armadilhas e casos reais

> **Armadilha:** A porta 22 aberta para `0.0.0.0/0` é a regra mais comum em Security Groups de tutoriais, e também a mais varrida por robôs. Se em algum momento você realmente precisar de SSH, restrinja a origem ao seu IP com `/32` (o `checkip.amazonaws.com` do capítulo 1 diz qual é) e remova a regra ao terminar. Com o Session Manager, essa regra simplesmente deixa de existir.

> **Armadilha:** O IP público muda quando a instância é parada e ligada de novo. Quem colocou o IP num registro DNS ou num `VITE_API_URL` descobre isso no dia seguinte. Um **Elastic IP** é um IPv4 público reservado para a conta, que você associa a uma instância e que sobrevive a stop e start. Ele custa os mesmos US$ 0,005 por hora, associado ou não. Um Elastic IP esquecido sem instância continua cobrando todo mês. Para o Rangô, a solução definitiva é um load balancer com um nome DNS, nos capítulos 13 e 14.

> **Armadilha:** "Free tier" no tipo de instância não quer dizer servidor grátis. O IPv4 público cobra à parte (com franquia só no modelo antigo), o modo unlimited da família T cobra pelo excedente de CPU (US$ 0,05 por vCPU-hora nas T3 Linux, us-east-1, outubro de 2026), e um volume grande ou com IOPS extras cobra pelo que passar do incluso. O painel de free tier do console atualiza só três vezes por dia; ele não mostra o consumo em tempo real.

> **Armadilha:** Editar o user data e reiniciar não reinstala nada, porque o script só roda no primeiro boot. Se você mudou o script, crie uma instância nova a partir dele. Isso tem um efeito colateral bom: força você a manter o script funcionando, em vez de acumular ajustes feitos à mão numa máquina que ninguém sabe recriar.

> **Armadilha:** Uma `t3.micro` tem 1 GiB de memória e nenhuma partição de swap no AL2023. Um `pip install` pesado, um terceiro worker ou um vazamento de memória fazem o kernel matar processos com o OOM killer, e o `journalctl` mostra só que o serviço morreu. Se a memória apertar, suba para `t3.small`: pare a instância, troque o tipo com `aws ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" --instance-type Value=t3.small` e ligue de novo. É a escala vertical do capítulo 4, com um minuto de indisponibilidade.

> **Na vida real:** Em julho de 2019, o Capital One revelou um vazamento de dados de cerca de 100 milhões de clientes nos Estados Unidos e 6 milhões no Canadá. A invasora usou um firewall de aplicação mal configurado, rodando numa instância EC2, para fazer o servidor chamar o serviço de metadados em nome dela, uma técnica chamada SSRF (*server-side request forgery*). O serviço de metadados respondeu com as credenciais temporárias da role da instância, e com elas a invasora leu dados de buckets S3. Na versão 1 do serviço de metadados, uma simples requisição GET bastava para obter as credenciais. Em novembro de 2019, a AWS lançou o IMDSv2, que exige antes um PUT para obter um token de sessão, algo que a maioria das falhas de SSRF não consegue fazer. É por isso que o `run-instances` deste capítulo leva `HttpTokens=required`. O custo dessa escolha: bibliotecas muito antigas que só sabem falar IMDSv1 deixam de achar as credenciais. As versões atuais do boto3 e da AWS CLI usam o v2.
## Resumo

- Uma instância EC2 é uma máquina virtual cobrada por segundo enquanto está ligada. O nome do tipo (`t3.micro`) diz família, geração, atributos e tamanho.
- A família T é burstable, com créditos de CPU. O modo unlimited, padrão nas T3, cobra pelo excedente; o standard só desacelera.
- O free tier depende da data de criação da conta: créditos no modelo novo, 12 meses no antigo.
- A AMI é o molde do sistema. Use o Amazon Linux 2023 pelo parâmetro público do SSM, nunca por um ID fixo. O AL2 chegou ao fim do suporte em 30 de junho de 2026.
- O Session Manager substitui o SSH com key pair: sem porta de entrada, sem chave para perder, com autorização pelo IAM. Exige SSM Agent, a policy `AmazonSSMManagedInstanceCore` e saída HTTPS.
- Passar uma role a uma instância exige `iam:PassRole`, que deve ser restrito à role certa e ao serviço certo.
- O Security Group só tem regras de permissão e é stateful. O `rango-web` libera só a porta 80.
- O user data roda uma vez, como root, no primeiro boot, e não deve conter segredos.
- O EBS é um disco de rede preso a uma zona de disponibilidade, cobrado pelo tamanho mesmo com a instância parada. `DeleteOnTermination` decide se ele morre junto.
- O Rangô rodou no EC2 com Valkey, Uvicorn e workers no systemd e o Nginx na frente, sobreviveu a um reboot e foi destruído no fim, com o script guardado em `infra/ec2/user-data.sh`.

## O próximo passo, e o perigo que vem com ele

Os pedidos do Rangô ainda moram no Redis, um arranjo provisório desde o capítulo 5. O próximo passo óbvio é trazer o PostgreSQL para o servidor. O atalho também é óbvio: instalar o Postgres na mesma instância e, para conferir os dados do notebook com o seu cliente SQL favorito, acrescentar ao `rango-web` uma regra para a porta 5432 com origem `0.0.0.0/0`. "Só até terminar o teste."

Antes disso, repare onde a instância está. A VPC default coloca tudo numa subnet pública, com IP público, alcançável por qualquer um. Não existe hoje nenhum lugar na sua conta onde um banco possa ficar fora do alcance da internet. Os robôs que varrem a porta 22 também varrem a 5432, e você já viu no capítulo 1 o que eles fizeram com milhares de bancos MongoDB abertos. No próximo capítulo, você vai desenhar a rede do Rangô do zero: uma VPC própria, subnets públicas e privadas, rotas, Internet Gateway e NAT Gateway, este último com um custo que pega muita gente de surpresa.

## Referências

- Amazon EC2, tipos de instância: https://aws.amazon.com/ec2/instance-types/
- Amazon EC2, preços sob demanda e créditos de CPU: https://aws.amazon.com/ec2/pricing/on-demand/
- Free tier no EC2 (contas antes e depois de 15/07/2025): https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html
- Amazon Linux 2023 no EC2 (parâmetros SSM, AMIs, kernel): https://docs.aws.amazon.com/linux/al2023/ug/ec2.html
- Amazon Linux 2, perguntas frequentes e fim do suporte: https://aws.amazon.com/amazon-linux-2/faqs/
- Transição de Redis 6 para Valkey no AL2023: https://docs.aws.amazon.com/linux/al2023/ug/redis6-to-valkey-al2023.html
- SSM Agent no Amazon Linux 2 e 2023: https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-al2.html
- Session Manager no EC2: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/session-manager.html
- Instalação do Session Manager plugin: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
- User data no EC2: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html
- Instance metadata e IMDSv2: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html
- Preços do Amazon EBS: https://aws.amazon.com/ebs/pricing/
- Cobrança de IPv4 público: https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/
- Free tier com 750 horas de IPv4 público: https://aws.amazon.com/about-aws/whats-new/2024/02/aws-free-tier-750-hours-free-public-ipv4-addresses/
- Lançamento do IMDSv2 (novembro de 2019): https://aws.amazon.com/blogs/security/defense-in-depth-open-firewalls-reverse-proxies-ssrf-vulnerabilities-ec2-instance-metadata-service/
- Capital One, comunicado sobre o incidente de 2019: https://www.capitalone.com/digital/facts2019/
- GitHub, deploy keys: https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys
- GitHub, impressões digitais das chaves SSH: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
