# IAM: quem pode fazer o quê

No capítulo anterior, o Rangô ganhou uma conta na AWS: root protegido com MFA em dois dispositivos, alarme de cobrança acima de 10 dólares, um orçamento mensal e a AWS CLI instalada no seu notebook. A CLI, porém, terminou respondendo `Unable to locate credentials`. Ela ainda não sabe quem você é, e o atalho óbvio (criar uma chave de acesso no root e colar no `~/.aws/credentials`) foi justamente o que deixamos de fora. Agora vamos ver por quê, e qual é o caminho certo.

## Dez segundos no GitHub

Em dezembro de 2025, pesquisadores da Unit 42, o time de inteligência de ameaças da Palo Alto Networks, fizeram um teste controlado. Criaram uma chave de acesso de um usuário IAM e a enviaram para um repositório público no GitHub às 18:50:05 (UTC). Às 18:50:15, dez segundos depois, o CloudTrail (o registro de auditoria da AWS, que veremos no capítulo 23) já mostrava uma ação sobre aquele usuário: a AWS tinha anexado a ele uma política chamada `AWSCompromisedKeyQuarantineV3`. Às 18:50:17 apareceu um aviso no painel do AWS Health, às 18:50:26 chegou um e-mail e às 18:50:59 a conta tinha um caso aberto no suporte.

Dez segundos é rápido. Só que a AWS tem companhia nessa varredura. Robôs de atacantes leem o fluxo de commits públicos o tempo todo, atrás de strings no formato de uma chave da AWS. Em outubro de 2023, a mesma Unit 42 descreveu uma campanha que batizou de EleKtra-Leak: entre o fim de agosto e o início de outubro daquele ano, atacantes usaram chaves expostas no GitHub para criar 474 instâncias EC2 dedicadas a minerar Monero, uma criptomoeda. O tempo entre a chave aparecer num repositório e ser usada chegava a cinco minutos.

A empresa japonesa Classmethod publicou um relato parecido, do ponto de vista de quem sofreu. Uma chave com a política `PowerUserAccess` foi parar num repositório público. Em cerca de dez minutos, já havia instâncias minerando Monero na conta. O GuardDuty, serviço de detecção de ameaças da AWS, deu o alerta, e a resposta envolveu apagar a chave, revisar o CloudTrail em todas as regiões (o minerador não se limita à região onde você trabalha), apagar os recursos criados e trocar todas as outras credenciais.

Agora repare num detalhe do teste da Unit 42. A política de quarentena não desativa a chave. Ela só acrescenta uma negação explícita para uma lista de ações perigosas, como lançar instâncias EC2, criar usuários e chaves, anexar políticas e apagar objetos no S3. Qualquer ação fora dessa lista continua funcionando com a chave vazada. Se a chave vazada fosse a do root, nem essa rede de proteção existiria, porque nenhuma política consegue limitar o root.

Esse é o problema do capítulo. Uma credencial de longa duração é uma senha que não expira, que cabe numa linha de texto e que pode ser copiada para qualquer lugar. E cada lugar para onde ela é copiada (um `.env`, um script, um notebook do Jupyter, uma mensagem no Slack) é um lugar de onde ela pode vazar. Para resolver isso, precisamos entender como a AWS decide quem pode fazer o quê, e trocar a chave permanente por algo que expira sozinho.

## Toda chamada é uma pergunta

O capítulo 7 mostrou que o console, a CLI e o CDK são todos clientes da mesma API. Cada clique no console e cada comando `aws` vira uma requisição HTTP assinada para um endpoint da AWS. Antes de executar qualquer coisa, a AWS responde a duas perguntas sobre essa requisição.

A primeira é *quem está pedindo*. Isso é **autenticação**, e a AWS a resolve verificando a assinatura da requisição, feita com uma chave secreta que só o solicitante deveria ter. A segunda é *se esse alguém pode fazer isso*. Isso é **autorização**, e é aqui que entra o **AWS Identity and Access Management**, o IAM.

Você já escreveu autorização muitas vezes. Num backend Python, é o decorator que protege a view:

```python
@requer_permissao("pedidos:cancelar")
def cancelar_pedido(pedido_id: int, usuario: Usuario):
    ...
```

O IAM faz o mesmo papel para a AWS inteira. Toda requisição carrega três informações que ele avalia:

- **Principal**: quem está pedindo. Um usuário, uma role, um serviço da AWS.
- **Action**: o que está sendo pedido, no formato `servico:Operacao`, como `s3:GetObject` ou `ec2:RunInstances`.
- **Resource**: sobre o que, identificado por um ARN.

O **ARN** (*Amazon Resource Name*) é o identificador único de qualquer coisa na AWS. O formato geral é `arn:aws:servico:regiao:conta:recurso`. Alguns exemplos que vão aparecer no livro:

```text
arn:aws:iam::123456789012:role/rango-ec2
arn:aws:s3:::rango-fotos-pratos/cantina-da-nona/lasanha.jpg
arn:aws:ec2:us-east-1:123456789012:instance/i-0abc123def4567890
```

Os campos vazios (os `::`) são intencionais. O IAM é global, então seus ARNs não têm região. Os nomes de bucket do S3 são únicos no mundo inteiro, então o ARN de um objeto não precisa nem de região nem de conta.

O IAM em si não tem custo. Você paga pelos recursos que as identidades criam, nunca pelas identidades.

## O JSON por dentro

As regras do IAM são escritas em **policies** (políticas), documentos JSON que listam o que é permitido ou negado. Esta é uma policy que o Rangô vai precisar no capítulo 11, quando a API passar a guardar as fotos dos pratos no S3:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LerEGravarFotos",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::rango-fotos-pratos/*"
    },
    {
      "Sid": "ListarFotos",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::rango-fotos-pratos"
    }
  ]
}
```

Vamos linha por linha. O `Version` parece uma data de criação, mas é a versão da linguagem de políticas, e o valor certo é sempre `2012-10-17`. Uma versão mais antiga existe e não suporta recursos como variáveis de política, então nunca mude isso.

O `Statement` é uma lista de regras. Cada uma tem um `Sid` opcional (um rótulo para você se achar), um `Effect` que vale `Allow` ou `Deny`, uma ou mais `Action` e um ou mais `Resource`.

Repare que são duas regras, e não uma. `GetObject` e `PutObject` agem sobre objetos, então o recurso é `rango-fotos-pratos/*`, tudo que está dentro do bucket. Já `ListBucket` age sobre o bucket em si, cujo ARN não tem a barra nem o asterisco. Juntar as três ações num único statement com `rango-fotos-pratos/*` é um erro clássico: o upload funciona, a listagem dá `AccessDenied`, e você perde uma tarde.

Uma policy também pode ter um `Condition`, que restringe quando a regra vale. Esta aqui nega a criação de qualquer coisa no EC2 fora das duas regiões que o Rangô usa:

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
    }
  ]
}
```

Lembra do caso da Classmethod, em que foi preciso varrer todas as regiões atrás de mineradores? Com essa regra, quem tiver essa identidade não consegue subir uma instância em `ap-southeast-1` nem em nenhuma outra região além das duas.

### Como a AWS decide

Com várias policies anexadas à mesma identidade, a AWS segue uma ordem simples de lembrar:

1. Tudo começa negado. Se nenhuma policy fala da ação, a resposta é não. Isso se chama **negação implícita** (*implicit deny*).
2. Um `Allow` que case com a requisição muda a resposta para sim.
3. Um `Deny` explícito em qualquer policy vence qualquer `Allow`, em qualquer lugar. Não existe forma de um `Allow` derrubar um `Deny`.

A terceira regra é o que torna a policy de regiões útil. Você pode dar `AdministratorAccess` a alguém e, ao lado, anexar o `Deny` de regiões. O resultado é um administrador que não cria nada no EC2 em Singapura. A quarentena da AWS funciona do mesmo jeito: é um `Deny` explícito colado ao lado do que já existia.

Existem mais tipos de policy além das que ficam na identidade. As **resource-based policies** ficam no recurso, como a bucket policy do S3 que veremos no capítulo 11. Dentro da mesma conta, as policies da identidade e as do recurso somam: basta um `Allow` em qualquer uma delas. Entre contas diferentes, os dois lados precisam permitir. Há ainda tipos que só servem para limitar, nunca para conceder, como as *permissions boundaries* e as SCPs do AWS Organizations (capítulo 23). Para esses, vale a interseção: a ação precisa estar liberada em todos eles.

> **Dica:** Na dúvida sobre o que uma policy permite, a pergunta certa é "existe algum `Deny` explícito?" e só depois "existe algum `Allow`?". Ler na ordem contrária é como depurar um `if` começando pelo `else`.

## Usuários, grupos e roles

As policies precisam ser anexadas a alguém. O IAM tem três tipos de identidade, e a diferença entre elas é a parte que mais importa neste capítulo.

Um **usuário IAM** representa uma pessoa ou uma aplicação, com credenciais permanentes: uma senha para o console, uma ou mais chaves de acesso para a API, ou as duas coisas. Foi a chave de um usuário IAM que vazou nos três casos que abriram o capítulo.

Um **grupo** é um conjunto de usuários que compartilham as mesmas policies. Você anexa a policy ao grupo `devs`, e todos os usuários dentro dele herdam aquelas permissões. Grupos não fazem login e não aparecem como principal numa requisição, e um grupo não pode conter outro grupo.

Uma **role** é uma identidade sem credenciais próprias. Ela tem permissões, como um usuário, mas ninguém tem uma senha ou uma chave dela. Quem precisa das permissões *assume* a role e recebe credenciais temporárias, que expiram sozinhas. Se o usuário IAM é um funcionário com crachá permanente, a role é o crachá de visitante entregue na portaria, válido por algumas horas e devolvido na saída.

Uma role tem dois documentos. A **permissions policy** diz o que ela pode fazer, como qualquer outra policy. A **trust policy** diz quem pode assumi-la. Esta é a trust policy da role que você vai criar no fim do capítulo, para o servidor EC2 do capítulo 9:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

Ela diz que o serviço EC2 pode assumir a role. Na prática, uma instância criada com essa role recebe credenciais temporárias automaticamente, renovadas pela própria AWS, e o código Python que roda nela usa essas credenciais sem que nenhuma chave apareça em arquivo, variável de ambiente ou imagem Docker.

### Credenciais que vencem

Quem entrega as credenciais temporárias é o **AWS STS** (*Security Token Service*). Uma credencial temporária tem três partes: um access key ID, uma secret access key e um session token. A sessão de uma role dura, por padrão, uma hora, e pode ir de 15 minutos até o máximo configurado na role (entre 1 e 12 horas).

Há um jeito rápido de saber, só de olhar, se uma credencial é permanente ou temporária. O access key ID de uma chave permanente começa com `AKIA`. O de uma credencial temporária começa com `ASIA`. Se você encontrar um `AKIA` num repositório, num log ou num ticket, alguém tem trabalho a fazer.

A diferença prática é enorme. Uma chave `AKIA` que vazou vale até alguém apagá-la, o que pode levar meses se ninguém perceber. Uma credencial `ASIA` vazada vale, no pior caso, algumas horas. Ela ainda é um problema, mas um problema com prazo de validade.

## Menor privilégio sem paralisia

O **princípio do menor privilégio** diz que cada identidade deve ter só as permissões de que precisa para o seu trabalho, e nada além. Você já aplica isso no banco de dados: o usuário que a aplicação usa para conectar no Postgres não deveria ter permissão para `DROP DATABASE`.

O problema é que levar o princípio ao pé da letra desde o primeiro dia trava o trabalho. Escrever a policy perfeita para um sistema que ainda não existe é impossível, e cada `AccessDenied` interrompe você por dez minutos. Na prática, o caminho que funciona tem algumas etapas:

1. Começar com as **AWS managed policies**, prontas e mantidas pela AWS, como `PowerUserAccess` ou `ReadOnlyAccess`. São largas, mas conhecidas.
2. Separar a identidade do dia a dia da identidade que mexe em permissões. Quem só desenvolve não precisa criar roles.
3. Para as aplicações, escrever **customer managed policies** (criadas por você) com ações e recursos específicos, como a policy das fotos que vimos acima.
4. Com o tempo, usar o *last accessed* do console do IAM, que mostra quais serviços uma identidade usou de verdade, para cortar o que sobra.

O ponto 2 é o que você vai aplicar daqui a pouco no Rangô: um acesso de desenvolvimento para o dia a dia e um acesso de administrador para as poucas vezes em que for preciso mexer no IAM.

Existe ainda uma terceira forma de anexar permissões, as **inline policies**, escritas diretamente dentro de um usuário, grupo ou role, sem existir como objeto separado. Elas servem para regras que só valem para aquela identidade. Para todo o resto, prefira policies gerenciadas, que podem ser reutilizadas e versionadas.

## Por que nunca usar o root

O root é o superusuário `postgres` da conta, como dissemos no capítulo 7, com uma diferença importante: nenhuma policy consegue limitar o root. Nem um `Deny` explícito, nem a quarentena da AWS. Se a chave do root vaza, a única defesa é apagá-la antes de o atacante fazer estrago.

E o root quase nunca é necessário. A documentação da AWS mantém uma lista oficial das tarefas que só ele consegue executar, e ela é curta. As que um projeto como o Rangô pode encontrar algum dia são estas:

- Alterar o e-mail, a senha e as chaves de acesso do próprio root.
- Fechar a conta.
- Restaurar permissões quando o único administrador IAM se trancou para fora.
- Ativar o acesso de usuários IAM à cobrança (você fez isso no capítulo 7).
- Configurar o MFA Delete num bucket do S3.
- Editar ou apagar uma bucket policy que nega acesso a todos, inclusive aos administradores.

O resto da lista trata de casos raros, como registrar-se como vendedor no marketplace de instâncias reservadas. Mudar o nome da conta, os contatos alternativos ou as regiões habilitadas não exige root.

O root pode ter chaves de acesso, e o console ainda oferece o botão para criá-las. Não crie. O capítulo 7 deixou o root sem chaves, com MFA em dois dispositivos, e o e-mail e a senha guardados. Ele fica assim, esquecido no cofre, até o dia em que uma tarefa da lista aparecer.

> **Na vida real:** Empresas que usam AWS Organizations podem centralizar o acesso root. Com isso, as contas-membro deixam de ter credenciais root, e contas novas já nascem sem elas. Voltaremos a esse modelo de várias contas no capítulo 23.

## IAM Identity Center: um login para gente

Se usuário IAM tem credenciais permanentes, e role não tem credenciais próprias, como uma pessoa entra na AWS sem uma chave permanente? A resposta da AWS é o **AWS IAM Identity Center**, que já se chamou AWS SSO (o nome antigo sobrevive nos comandos da CLI, como `aws sso login`).

O Identity Center é um ponto único de login para pessoas. Ele funciona assim:

- As pessoas ficam num diretório. Pode ser o diretório do próprio Identity Center ou um provedor de identidade que a empresa já usa, como Google Workspace, Microsoft Entra ID ou Okta.
- Você cria **permission sets**, que são modelos de permissão (por exemplo, "PowerUserAccess" ou "AdministratorAccess").
- Você atribui a um usuário ou grupo um permission set numa conta. O Identity Center cria, dentro da conta, uma role com aquelas permissões, com nome começando por `AWSReservedSSO_`.
- A pessoa faz login num portal (o *AWS access portal*), com senha e MFA, e escolhe qual role quer assumir. Recebe credenciais temporárias.

Para o console, isso vira um link no portal. Para a CLI, vira o comando `aws sso login`, que abre o navegador, faz você aprovar o acesso e guarda um token em cache. A CLI troca esse token por credenciais temporárias da role sempre que precisar, sem que você toque numa chave.

Compare com o caminho do `aws configure`. Lá, você teria um `AKIA` gravado em texto puro no `~/.aws/credentials`, válido para sempre. Aqui, o que fica no disco é um token que expira, e as credenciais da role duram uma hora.

## Mão na massa: o Rangô sem nenhuma chave permanente

Vamos montar o acesso do Rangô do jeito certo. Você vai precisar da conta do capítulo 7, do navegador e da AWS CLI v2 na versão 2.22.0 ou mais recente (confira com `aws --version`). Nada do que faremos aqui gera cobrança.

### Ativando o Identity Center

Entre no console com o root uma última vez nesta configuração. Ativar o Identity Center é uma decisão de administração da conta, e ainda não existe nenhuma outra identidade com permissão para isso.

1. Confirme que a região selecionada no canto superior direito é `us-east-1`. O Identity Center vive numa região só, e é nela que você vai procurá-lo sempre.
2. Busque por **IAM Identity Center** e clique em **Enable**.
3. O console oferece ativar com o AWS Organizations, e essa é a opção recomendada. Aceite.

O passo 3 transforma a conta `rango-estudos` na conta de gerenciamento de uma organização com um único membro, ela mesma. Isso não muda nada no que você já criou e não tem custo. O modelo de várias contas fica para o capítulo 23; por enquanto, a organização existe só para o Identity Center funcionar.

Na página **Settings** do Identity Center, anote o **AWS access portal URL**. Ele tem o formato `https://d-xxxxxxxxxx.awsapps.com/start`, e você pode trocar o `d-xxxxxxxxxx` por um nome mais fácil de lembrar, como `rango`.

### Usuário, grupo e permission sets

Ainda no Identity Center, com o root:

1. Em **Groups**, crie dois grupos: `rango-admins` e `rango-devs`.
2. Em **Users**, crie um usuário para você. Nos exemplos, ele se chama `dev-rango`. Use um e-mail seu que não seja o do root, e coloque o usuário nos dois grupos.
3. Em **Permission sets**, crie dois permission sets do tipo *predefined*: `AdministratorAccess` e `PowerUserAccess`. A duração de sessão padrão, uma hora, serve.
4. Em **AWS accounts**, selecione a conta `rango-estudos` e clique em **Assign users or groups**. Atribua o grupo `rango-admins` com `AdministratorAccess`, e depois o grupo `rango-devs` com `PowerUserAccess`.

Atribuir permissões a grupos, e não ao usuário diretamente, é o mesmo hábito do Django com `Group` e `Permission`: quando a sócia do Rangô precisar de acesso, basta criar o usuário dela e colocá-lo em `rango-devs`.

O `PowerUserAccess` permite quase tudo, menos gerenciar o IAM e a organização. É o permission set que a documentação da AWS sugere para quem desenvolve, e é o que você vai usar no dia a dia.

Agora acrescente a guarda de regiões. Abra o permission set `PowerUserAccess`, vá em **Inline policy** e cole a policy `SoRegioesDoRango` da seção sobre o JSON. Salve. O Identity Center reaplica o permission set na conta automaticamente.

Abra o e-mail do convite que o Identity Center enviou para `dev-rango`, defina a senha e cadastre um dispositivo MFA quando for pedido. Use uma passkey ou um aplicativo autenticador, como fez no root. Teste o login no portal e confirme que aparecem as duas opções para a conta `rango-estudos`.

A partir daqui, o root sai de cena. Faça logout dele.

### A CLI com SSO

Com o usuário criado, configure a CLI:

```bash
aws configure sso
```

O assistente faz algumas perguntas. As respostas do exemplo estão depois dos dois-pontos:

```text
SSO session name (Recommended): rango
SSO start URL [None]: https://rango.awsapps.com/start
SSO region [None]: us-east-1
SSO registration scopes [sso:account:access]:
```

O *start URL* é o endereço do portal que você anotou. A *SSO region* é a região onde o Identity Center foi ativado. O escopo pode ficar no valor padrão: aperte Enter.

Em seguida, a CLI abre o navegador. Faça login como `dev-rango`, se ainda não estiver logado, e aprove o acesso. A tela de aprovação mostra um cliente chamado `botocore-client-` seguido do nome da sessão. Desde a versão 2.22.0, esse fluxo usa PKCE, um protocolo de autorização que exige que o navegador esteja na mesma máquina que a CLI.

De volta ao terminal, o assistente lista as roles disponíveis:

```text
The only AWS account available to you is: 123456789012
Using the account ID 123456789012
There are 2 roles available to you.
  AdministratorAccess
> PowerUserAccess
Using the role name "PowerUserAccess"
Default client Region [None]: us-east-1
CLI default output format (json if not specified) [None]: json
Profile name [PowerUserAccess-123456789012]: rango-dev
```

Escolha `PowerUserAccess` e dê ao perfil o nome `rango-dev`. Repita o `aws configure sso` uma segunda vez, informe o mesmo nome de sessão (`rango`), escolha `AdministratorAccess` e chame o perfil de `rango-admin`. O `~/.aws/config` fica assim:

```ini
[profile rango-dev]
sso_session = rango
sso_account_id = 123456789012
sso_role_name = PowerUserAccess
region = us-east-1
output = json

[profile rango-admin]
sso_session = rango
sso_account_id = 123456789012
sso_role_name = AdministratorAccess
region = us-east-1
output = json

[sso-session rango]
sso_start_url = https://rango.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

Leia o arquivo com atenção. Não há nenhuma chave nele. Há um endereço de portal, um número de conta e o nome de uma role. Você pode versionar esse arquivo num repositório interno sem expor nada, e por isso ele é seguro para dividir com a equipe.

A seção `sso-session` é compartilhada pelos dois perfis. Isso quer dizer que um único login serve para os dois. Faça o teste:

```bash
aws sso login --sso-session rango
aws sts get-caller-identity --profile rango-dev
```

```json
{
    "UserId": "AROAEXAMPLEID7EXAMPLE:dev-rango",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_PowerUserAccess_0a1b2c3d4e5f6a7b/dev-rango"
}
```

O mesmo comando que falhou no fim do capítulo 7 agora responde. O ARN conta a história inteira: você é `dev-rango`, e está usando uma sessão (`sts`, `assumed-role`) da role que o Identity Center criou a partir do permission set.

Para não precisar digitar `--profile` em todo comando, defina o perfil padrão no seu shell:

```bash
export AWS_PROFILE=rango-dev
```

O token da sessão SSO fica em `~/.aws/sso/cache`. Enquanto ele valer, a CLI renova as credenciais da role sozinha. Quando ele expirar, os comandos passam a falhar com uma mensagem pedindo novo login, e basta rodar `aws sso login` de novo. Para encerrar tudo antes disso, como ao sair de um computador emprestado:

```bash
aws sso logout
```

```text
Successfully signed out of all SSO profiles.
```

> **Dica:** Se você trabalha num servidor por SSH, ou num WSL que não consegue abrir o navegador do Windows, use `aws sso login --use-device-code`. A CLI mostra um endereço do tipo `https://device.sso.us-east-1.amazonaws.com/` e um código curto, como `QCFK-N451`. Você abre o endereço em qualquer navegador, digita o código e aprova.

### O erro que você quer ver

Na raiz do repositório do Rangô, crie a pasta `iam/` e salve a trust policy da seção sobre roles em `iam/rango-ec2-confianca.json`. Antes de criar a role do servidor com o perfil de administrador, tente com o perfil do dia a dia:

```bash
aws iam create-role \
  --role-name rango-ec2 \
  --assume-role-policy-document file://iam/rango-ec2-confianca.json \
  --profile rango-dev
```

```text
An error occurred (AccessDenied) when calling the CreateRole operation: User: arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_PowerUserAccess_0a1b2c3d4e5f6a7b/dev-rango is not authorized to perform: iam:CreateRole on resource: arn:aws:iam::123456789012:role/rango-ec2 because no identity-based policy allows the iam:CreateRole action
```

Esse erro é o sistema funcionando. A mensagem traz o principal, a ação, o recurso e o motivo ("nenhuma policy baseada em identidade permite"), as três peças da pergunta que o IAM responde em toda requisição. Quando você receber um `AccessDenied` no futuro, leia a mensagem inteira, porque ela costuma dizer exatamente o que falta. Se o motivo citar um `explicit deny`, o problema é outro: existe uma regra negando, e acrescentar um `Allow` não vai adiantar.

Tente também subir uma instância em Singapura com o perfil `rango-dev`. O `Deny` de regiões barra a operação antes de qualquer outra checagem:

```bash
aws ec2 run-instances \
  --image-id ami-12345678 \
  --instance-type t3.micro \
  --region ap-southeast-1 \
  --profile rango-dev
```

O erro vem com `UnauthorizedOperation` e uma mensagem codificada. A AMI do exemplo é fictícia, e não importa: a policy nega a chamada antes de a AWS sequer olhar para ela, então nada é criado.

### Uma role para o servidor do capítulo 9

No próximo capítulo, o Rangô vai rodar numa instância EC2. Para administrá-la sem abrir a porta 22 nem guardar chave SSH, usaremos o AWS Systems Manager Session Manager, e para isso a instância precisa de uma role com a managed policy `AmazonSSMManagedInstanceCore`. Vamos deixá-la pronta agora.

Agora, com o perfil de administrador:

```bash
aws iam create-role \
  --role-name rango-ec2 \
  --assume-role-policy-document file://iam/rango-ec2-confianca.json \
  --description "Role da EC2 do Rango" \
  --profile rango-admin

aws iam attach-role-policy \
  --role-name rango-ec2 \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  --profile rango-admin
```

Uma instância EC2 não recebe a role diretamente. Ela recebe um **instance profile**, uma espécie de envelope que carrega a role. Quando você cria a role pelo console, o instance profile é criado junto e sem aviso. Pela CLI, você mesmo cria:

```bash
aws iam create-instance-profile \
  --instance-profile-name rango-ec2 \
  --profile rango-admin

aws iam add-role-to-instance-profile \
  --instance-profile-name rango-ec2 \
  --role-name rango-ec2 \
  --profile rango-admin
```

Antes de existir qualquer servidor, você já consegue perguntar ao IAM o que essa role pode fazer. O simulador de políticas avalia as ações sem executá-las:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::123456789012:role/rango-ec2 \
  --action-names ssm:UpdateInstanceInformation s3:ListAllMyBuckets \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' \
  --output table \
  --profile rango-admin
```

```text
----------------------------------------------------
|              SimulatePrincipalPolicy             |
+--------------------------------+-----------------+
|  ssm:UpdateInstanceInformation |  allowed        |
|  s3:ListAllMyBuckets           |  implicitDeny   |
+--------------------------------+-----------------+
```

A primeira ação é uma das que o agente do Systems Manager usa para se registrar, e está liberada pela managed policy. A segunda não aparece em nenhuma policy da role, então cai na negação implícita. É o menor privilégio visto de perto: o servidor do Rangô vai conseguir ser administrado, e não vai conseguir listar os buckets da conta.

Para fechar, confira o estado do root pelo resumo da conta:

```bash
aws iam get-account-summary \
  --query 'SummaryMap.[AccountMFAEnabled,AccountAccessKeysPresent]' \
  --profile rango-admin
```

```json
[
    1,
    0
]
```

O `1` diz que o root tem MFA. O `0` diz que ele não tem chaves de acesso. São os dois números que você quer ver em toda conta.

### Python usa o mesmo caminho

O boto3, o SDK da AWS para Python, procura credenciais na mesma ordem que a CLI e entende os perfis SSO do `~/.aws/config`. Com uma versão recente do boto3 instalada no ambiente virtual do backend:

```python
import boto3

identidade = boto3.client("sts").get_caller_identity()
print(identidade["Arn"])
```

```bash
AWS_PROFILE=rango-dev python quem_sou_eu.py
```

```text
arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_PowerUserAccess_0a1b2c3d4e5f6a7b/dev-rango
```

Repare que o código não menciona perfil nem chave. No seu notebook, a credencial vem do perfil SSO. No servidor do capítulo 9, o mesmo código vai pegar as credenciais da role `rango-ec2`, sem mudar uma linha. É assim que o código do Rangô vai falar com a AWS daqui para a frente: sem `aws_access_key_id=` em lugar nenhum.

Nada do que criamos tem custo. A role `rango-ec2` e o instance profile ficam para o capítulo 9. Se quiser desfazer tudo, remova a role do instance profile, apague os dois e desative o Identity Center nas configurações dele.

## Armadilhas e casos reais

> **Armadilha:** Apagar o commit não apaga a chave. Se uma chave foi para um repositório, mesmo que por segundos e mesmo que o histórico tenha sido reescrito com `git push --force`, considere-a comprometida. Forks, clones e os robôs que leem o fluxo público já podem ter uma cópia. O único remédio é desativar e apagar a chave na AWS, e depois procurar no CloudTrail o que foi feito com ela.

> **Armadilha:** A quarentena da AWS dá uma falsa sensação de alívio. Como o teste da Unit 42 mostrou, a `AWSCompromisedKeyQuarantineV3` só nega uma lista de ações. A chave continua autenticando, e tudo fora da lista segue permitido. Se você receber o e-mail da AWS sobre uma chave exposta, apague a chave. Não espere a investigação terminar para fazer isso.

Um detalhe curioso do mesmo teste: no CloudTrail, o evento `AttachUserPolicy` que aplica a quarentena aparece como se tivesse sido feito pelo próprio usuário afetado, e não pela AWS. Quem investiga um incidente pela primeira vez pode achar que o atacante anexou a política, quando foi a AWS que fez isso.

> **Armadilha:** `iam:PassRole` com `"Resource": "*"` abre uma porta para escalada de privilégio. `PassRole` é a permissão de entregar uma role a um serviço, por exemplo ao criar uma instância EC2 com um instance profile. Se uma identidade pode criar instâncias e passar qualquer role, ela pode subir uma instância com a role de mais permissões da conta, entrar nela e agir como essa role. Ao dar `PassRole`, sempre restrinja o `Resource` às roles específicas, como `arn:aws:iam::123456789012:role/rango-ec2`.

> **Armadilha:** Variáveis de ambiente esquecidas passam na frente do perfil. Se o seu shell tem `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY` definidas (de um tutorial antigo, de um `.env` carregado sem querer), elas têm precedência sobre o `AWS_PROFILE`. Você acha que está usando o SSO e está usando uma chave antiga. Na dúvida, rode `aws sts get-caller-identity` antes de qualquer comando que cria ou apaga coisas.

> **Armadilha:** `"Action": "*"` e `"Resource": "*"` juntos numa policy de aplicação. É a forma mais rápida de fazer o erro de permissão sumir, e transforma qualquer falha no código (uma injeção, uma dependência comprometida) num acesso de administrador à conta. Se você se pegar escrevendo isso para "destravar" algo, pare e leia a mensagem do `AccessDenied`, que diz qual ação falta.

Há também limites que surpreendem quando as policies crescem. Por padrão, um usuário, grupo ou role aceita até 10 managed policies anexadas (o valor pode ser aumentado). Uma customer managed policy pode ter até 6.144 caracteres, sem contar espaços em branco, e esse limite não é ajustável. A trust policy de uma role tem limite padrão de 2.048 caracteres. São valores de referência consultados em outubro de 2026; confira a página de cotas do IAM antes de desenhar algo que dependa deles. Quem bate no limite de tamanho costuma estar listando ações uma a uma quando um curinga restrito, como `s3:Get*`, resolveria.

> **Na vida real:** O GitHub tem um programa de varredura de segredos em parceria com provedores como a AWS, e é parte do motivo de a quarentena chegar tão rápido. Repositórios privados ficam fora do fluxo público, e mesmo assim estão longe de ser cofres: um repositório privado que vira público, um colaborador externo ou um laptop roubado bastam. A regra continua sendo nenhuma chave permanente em repositório nenhum.

## Resumo

- O IAM responde a duas perguntas em toda requisição: quem está pedindo (autenticação) e se pode fazer aquilo (autorização), avaliando principal, ação e recurso.
- ARN é o identificador de qualquer recurso: `arn:aws:servico:regiao:conta:recurso`, com campos vazios onde não se aplicam.
- Policies são JSON com `Version` `2012-10-17` e uma lista de `Statement` com `Effect`, `Action`, `Resource` e, opcionalmente, `Condition`.
- Tudo começa negado; um `Allow` libera; um `Deny` explícito vence sempre.
- Usuários IAM têm credenciais permanentes (`AKIA`). Roles não têm credenciais próprias e entregam credenciais temporárias (`ASIA`) pelo STS, com trust policy e permissions policy.
- Menor privilégio na prática: managed policies no começo, acesso de dia a dia separado do de administração, policies específicas para aplicações.
- O root fica sem chaves, com MFA, e só sai do cofre para a lista curta de tarefas que exigem ele.
- O IAM Identity Center dá login com MFA para pessoas e entrega roles temporárias por meio de permission sets.
- A CLI usa `aws configure sso` e `aws sso login`; o `~/.aws/config` não guarda nenhuma chave.
- O Rangô tem agora os perfis `rango-dev` e `rango-admin` e a role `rango-ec2`, pronta para o primeiro servidor.

## Para onde vamos

Você tem uma conta protegida, um login sem chaves permanentes e uma role esperando um servidor que ainda não existe. O Rangô, por sua vez, continua rodando no Docker Compose do seu notebook. Se você fechar a tampa, ele sai do ar. A sócia em Recife ainda não consegue abrir o cardápio.

Precisamos de um computador ligado o tempo todo, com IP público, num data center da AWS. No próximo capítulo, você vai criar a primeira instância EC2, entregar a ela a role `rango-ec2`, entrar nela pelo Session Manager sem abrir a porta 22 e instalar o Rangô à mão, com Uvicorn e Nginx. Vai dar trabalho, e esse trabalho é parte da lição.

## Referências

- Configurar a AWS CLI com IAM Identity Center: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html
- Tarefas que exigem o root: https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-tasks.html
- Lógica de avaliação de políticas: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
- Cotas do IAM e do STS: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html
- Passkeys como MFA para root e usuários IAM: https://aws.amazon.com/blogs/aws/aws-adds-passkey-multi-factor-authentication-mfa-for-root-and-iam-users/
- Unit 42, teste de exposição de credenciais e a política de quarentena: https://unit42.paloaltonetworks.com/detecting-exposed-aws-iam-credentials/
- Campanha EleKtra-Leak: https://www.darkreading.com/cloud-security/elektra-leak-attackers-harvest-aws-cloud-keys-github-campaign
- Relato da Classmethod sobre chave exposta: https://dev.classmethod.jp/articles/risk-management-aws-access-key-accidentally-exposed
- Elementos de política JSON do IAM: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements.html
- O que é o IAM Identity Center: https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html
