# S3: armazenamento de objetos

No capítulo anterior, o Rangô ganhou uma rede própria, a `rango-vpc`, com subnets públicas para o que precisa receber tráfego da internet e subnets privadas para o banco. Testamos o desenho com uma API e um Postgres em instâncias separadas, destruímos as máquinas e o NAT Gateway, e deixamos de pé só o que é gratuito. Entre essas peças ficou um gateway endpoint do S3 na route table privada, criado de propósito para este capítulo.

## Trezentas e quarenta fotos num disco de 10 GiB

A primeira versão do upload de fotos era a mais óbvia possível. O formulário do painel do restaurante enviava o arquivo num `multipart/form-data`, a rota do FastAPI recebia o `UploadFile` e gravava em `/opt/rango/fotos/cantina-da-nona/lasanha.jpg`. Uma rota estática devolvia a imagem quando o React pedia. Funcionou no primeiro dia, com três fotos de teste.

Aí a Cantina da Nona mandou 340 fotos tiradas no celular, de 4 MB cada. São cerca de 1,3 GB de um único restaurante, num volume EBS de 10 GiB que já carrega o sistema operacional, o Python, o código e os logs. Mais seis restaurantes com o mesmo entusiasmo e o `df -h` mostra 100%. Quando o disco enche, a foto deixa de ser o problema principal: o Valkey não consegue gravar, o journald para de registrar e o Nginx começa a devolver erro 500 sem deixar pista no log.

Aumentar o volume adiaria o problema, e os outros são piores:

- Quando a API tiver três instâncias atrás de um load balancer (o capítulo 4 já avisou), a foto enviada para a instância A não existe nas instâncias B e C. Dois terços das vezes, o prato aparece sem imagem.
- Cada foto exibida ocupa um processo Python servindo bytes que não mudam. Com dois workers do Uvicorn, uma página com 20 pratos disputa os mesmos processos que estão tentando confirmar pedidos.
- O upload também passa pela API. Um dono de restaurante num 4G fraco leva 40 segundos para enviar 4 MB, e durante esses 40 segundos uma conexão fica presa no seu servidor.
- Se a instância for destruída, as fotos vão junto, a menos que alguém se lembre de fazer snapshot do volume.

O disco local da instância é o lugar errado para guardar arquivos que os usuários enviam. Precisamos de um armazenamento que fique fora de qualquer servidor, que todas as instâncias enxerguem igual, que cresça sem ninguém redimensionar nada e que o navegador consiga acessar sem passar pelo Python.

## Um dicionário gigante acessado por HTTP

O Amazon S3 (Simple Storage Service) foi um dos primeiros serviços da AWS, lançado em 2006, e resolve exatamente isso. A forma mais fácil de entendê-lo é esquecer a ideia de disco e pensar num dicionário Python muito grande, acessado por HTTP:

```python
# O modelo mental do S3
bucket = {
    "fotos/cantina-da-nona/lasanha.jpg": b"\xff\xd8\xff\xe0...",
    "fotos/sabor-do-sertao/baiao.jpg": b"\xff\xd8\xff\xe0...",
}
```

O *bucket* é o dicionário. Cada entrada é um **objeto**: os bytes do arquivo mais alguns metadados (tipo de conteúdo, tamanho, data, cabeçalhos que você definir). A chave do dicionário se chama, sem surpresa, **key**. Você grava com `PUT`, lê com `GET`, apaga com `DELETE` e lista as chaves com um prefixo. Quase não há mais operações do que isso.

Repare que a key tem barras, mas o S3 não tem pastas. `fotos/cantina-da-nona/lasanha.jpg` é uma string única. O console mostra "pastas" porque agrupa as chaves pelo caractere `/`, por conveniência. Na prática, isso significa que não existe "renomear pasta": mudar um prefixo é copiar cada objeto para uma chave nova e apagar a antiga. Também não existe editar um pedaço do arquivo. Você substitui o objeto inteiro ou não mexe nele.

Essa simplicidade tem contrapartidas que interessam ao Rangô:

- **Capacidade**: o bucket não tem limite de tamanho nem de número de objetos. Você não provisiona espaço e paga pelo que está guardado, por GB por mês.
- **Durabilidade**: na classe padrão, cada objeto é gravado em dispositivos de pelo menos três zonas de disponibilidade da região. A AWS projeta essa classe para 99,999999999% de durabilidade (os famosos "onze noves") em um ano. Perder um arquivo por falha de hardware deixa de ser uma preocupação sua. Apagá-lo por engano continua sendo, e voltamos a isso no versionamento.
- **Acesso por HTTP**: qualquer cliente que fale HTTPS e saiba assinar uma requisição consegue ler e gravar. Isso inclui a CLI, o boto3 e, com a autorização certa, o navegador do seu usuário.
- **Consistência**: desde dezembro de 2020, o S3 tem consistência forte de leitura após escrita. Se o `PUT` retornou 200, o próximo `GET` de qualquer lugar já devolve a versão nova.

O nome do bucket tem uma regra que pega todo mundo na primeira vez: ele é único no mundo inteiro, entre todas as contas da AWS. Se alguém já criou `fotos`, você não cria. Por isso o livro usa `rango-fotos-pratos`, o nome que apareceu na policy do capítulo 8, e você vai precisar acrescentar um sufixo seu, como o número da conta. O nome também vira parte da URL (`https://rango-fotos-pratos.s3.amazonaws.com/...`), então não coloque nele nada que você não queira ver num log de terceiros.

Cada conta pode ter até 10.000 buckets de uso geral por padrão, valor que subiu de 100 em novembro de 2024 e pode chegar a 1 milhão pelo Service Quotas. Os primeiros 2.000 são gratuitos. Para o Rangô, um bucket basta.

### Quanto custa guardar as fotos

Pelos valores de referência que encontramos em outubro de 2026 para `us-east-1` (vindos de levantamentos de terceiros, porque a tabela oficial não abriu na consulta), a classe padrão custa cerca de US$ 0,023 por GB por mês. As 340 fotos da Cantina da Nona ocupam 1,3 GB, ou uns 3 centavos de dólar por mês. As requisições também são cobradas: cerca de US$ 0,005 por mil `PUT` e US$ 0,0004 por mil `GET`. Confira os números atuais na página de preços do S3 ou no AWS Pricing Calculator antes de fazer qualquer projeção.

O item que costuma surpreender é a transferência para a internet. Os primeiros 100 GB por mês são gratuitos, somando todos os serviços e regiões da conta. Depois disso, cada GB que sai da AWS para o navegador de alguém é cobrado. Uma foto de 4 MB vista 50 mil vezes por mês já são 200 GB. O capítulo 14 coloca o CloudFront na frente do bucket, e o capítulo 24 volta ao assunto de tráfego de saída.

## Classes de armazenamento: a despensa e o depósito

Nem todo objeto é lido com a mesma frequência. A foto do prato do dia é lida milhares de vezes. A foto de um prato que saiu do cardápio há dois anos talvez nunca mais seja aberta. O S3 permite pagar menos pelo armazenamento de quem é pouco lido, em troca de cobrar mais quando alguém lê. Pense numa cozinha: o que se usa todo dia fica na bancada, o que se usa uma vez por mês vai para a despensa, e a louça de Natal vai para o depósito no fundo do quintal.

| Classe | Para quê | Duração mínima cobrada | Leitura |
|--------|----------|------------------------|---------|
| S3 Standard | Dados lidos com frequência | Nenhuma | Imediata, sem taxa por GB lido |
| S3 Intelligent-Tiering | Padrão de acesso desconhecido | Nenhuma | Imediata nos níveis frequentes; taxa mensal de monitoramento por objeto |
| S3 Standard-IA | Lido raramente, mas precisa estar disponível na hora | 30 dias | Imediata, com taxa por GB lido |
| S3 One Zone-IA | Igual ao anterior, em uma só AZ | 30 dias | Imediata, com taxa por GB lido |
| S3 Glacier Instant Retrieval | Arquivo lido poucas vezes por ano | 90 dias | Imediata, taxa por GB maior |
| S3 Glacier Flexible Retrieval | Arquivo que pode esperar minutos ou horas | 90 dias | Exige restauração antes |
| S3 Glacier Deep Archive | Retenção longa, quase nunca lida | 180 dias | Restauração em horas |

Duas letras miúdas dessa tabela mudam a conta. A primeira é a duração mínima: se você mover um objeto para Glacier Instant Retrieval e apagá-lo no dia 10, paga os 90 dias do mesmo jeito. A segunda é o tamanho mínimo: Standard-IA, One Zone-IA e Glacier Instant Retrieval cobram cada objeto como se tivesse pelo menos 128 KB. Uma miniatura de 20 KB nessas classes custa como uma de 128 KB. Nas duas classes de arquivo com restauração, cada objeto ainda carrega uns 40 KB extras de metadados cobrados.

Como ordem de grandeza (valores de terceiros, outubro de 2026), Standard-IA fica em torno de US$ 0,0125 por GB por mês e Deep Archive perto de US$ 0,001: o depósito sai mais de vinte vezes mais barato que a bancada.

One Zone-IA guarda o objeto numa só AZ, então use apenas para dados que você consegue gerar de novo, como miniaturas. Intelligent-Tiering serve para quando você não sabe o padrão de acesso: o S3 move cada objeto sozinho entre níveis, sem cobrar pela leitura, mas cobra uma taxa mensal de monitoramento por objeto.

Para o Rangô de hoje, tudo fica em Standard. O volume é pequeno e as fotos são lidas o tempo todo. As outras classes vão importar quando os backups do Postgres começarem a ocupar terabytes.

## Lifecycle: regras que trabalham enquanto você dorme

Mover objetos de classe à mão não escala. O S3 tem *lifecycle rules*: regras declarativas no bucket que dizem o que fazer com os objetos conforme a idade deles. Lembra um job agendado de limpeza que você não escreve nem monitora. Cada regra tem um filtro (prefixo, tags ou tamanho) e ações, como mudar `backups/` para Glacier Flexible Retrieval após 30 dias ou apagar `tmp/` após 1 dia.

Há duas restrições que evitam frustração. Um objeto precisa ter pelo menos 30 dias para ser transicionado para Standard-IA ou One Zone-IA. E, desde setembro de 2024, as regras novas, por padrão, não transicionam objetos menores que 128 KB para nenhuma classe, porque o custo da requisição de transição seria maior que a economia. Se você quiser mudar isso, existe o filtro `ObjectSizeGreaterThan` (e o `ObjectSizeLessThan`). Regras criadas antes de setembro de 2024 mantêm o comportamento antigo até serem editadas.

## Versionamento: o `git log` do bucket

Lembra que um `PUT` na mesma key substitui o objeto? Com o bucket no modo padrão, substituir é apagar. Um bug que grava a foto da lasanha na key da foto do baião destrói o baião para sempre. Um `aws s3 rm --recursive` digitado no terminal errado leva tudo.

O versionamento muda esse comportamento. Com ele ligado, cada `PUT` cria uma nova versão do objeto e guarda as anteriores, cada uma com um `VersionId`. Um `DELETE` comum não apaga nada: ele coloca um **delete marker** por cima, uma espécie de lápide que faz o objeto parecer inexistente. Remover o delete marker traz o objeto de volta. Para apagar de verdade, você precisa pedir a exclusão de uma versão específica.

Se você pensou em `git`, acertou: cada versão é um commit, o delete marker é um commit que remove o arquivo, e restaurar é fazer checkout de uma versão anterior. A diferença é que o S3 cobra armazenamento por todas essas versões. Sobrescrever uma foto de 4 MB dez vezes deixa 40 MB guardados.

Daí a combinação clássica: versionamento ligado mais uma lifecycle rule que apaga versões antigas (as *noncurrent versions*) depois de alguns dias. Você ganha uma janela para desfazer erros sem pagar para sempre por eles.

Uma vez ligado, o versionamento não pode ser desligado, apenas suspenso.

## Quem pode ler o bucket

Até aqui falamos de onde os bytes ficam. A parte que derrubou empresas inteiras é outra: quem tem permissão para lê-los.

O capítulo 8 mostrou que a AWS avalia permissões juntando dois tipos de policy. A **identity-based policy** fica presa a quem pede (um usuário, uma role). A **resource-based policy** fica presa ao recurso. No S3, essa segunda é a **bucket policy**: um JSON no próprio bucket, com o mesmo formato que você já conhece, mais o campo `Principal` dizendo a quem a regra se aplica. Na mesma conta, um `Allow` em qualquer uma das duas basta, e um `Deny` explícito em qualquer uma das duas vence.

O problema histórico está no `Principal`. Uma bucket policy com `"Principal": "*"` e `"Action": "s3:GetObject"` significa "qualquer pessoa na internet pode ler qualquer objeto". Muitas vezes é alguém tentando fazer uma imagem aparecer no front e copiando a primeira resposta que encontrou. Havia ainda as ACLs, permissões por objeto anteriores ao IAM, com "AllUsers: READ" a um clique de distância no console. Dezenas de empresas foram parar nas manchetes por um bucket aberto para "facilitar" uma integração e nunca mais fechado.

A AWS respondeu em camadas. A primeira foi o **S3 Block Public Access**, uma trava acima de todas as policies e ACLs, com quatro configurações:

| Configuração | O que faz |
|--------------|-----------|
| `BlockPublicAcls` | Rejeita qualquer requisição que tente criar uma ACL pública |
| `IgnorePublicAcls` | Ignora ACLs públicas que já existam |
| `BlockPublicPolicy` | Rejeita bucket policies que concedam acesso público |
| `RestrictPublicBuckets` | Se uma policy pública já existir, restringe o acesso a principals da AWS e da própria conta |

O Block Public Access pode ser ligado em cada bucket e também na conta inteira. Ligado na conta, nenhum bucket fica público, nem que alguém escreva `"Principal": "*"` por engano.

A segunda camada veio como padrão. Desde abril de 2023, todo bucket novo nasce com as quatro configurações do Block Public Access ligadas e com as ACLs desabilitadas (a configuração *Object Ownership* fica em `BucketOwnerEnforced`: tudo que entra no bucket pertence à conta dona dele, e qualquer tentativa de definir uma ACL falha). Isso vale para buckets criados pelo console, pela CLI, pelo SDK ou pelo CloudFormation, em todas as regiões. Buckets antigos não mudaram, então uma conta com histórico pode ter buckets criados em 2019 com ACLs ativas.

Uma terceira proteção, menos ligada à exposição, também virou padrão: desde 5 de janeiro de 2023, todo objeto novo é criptografado em repouso com SSE-S3 (AES-256, com chaves gerenciadas pela AWS), sem custo. Criptografia em repouso protege contra um disco roubado do data center. Ela não protege contra uma policy aberta: o S3 descriptografa com prazer para quem tem permissão de leitura. As chaves gerenciadas por você, com o KMS, ficam para o capítulo 16.

O bucket do Rangô nasce fechado, e vai continuar assim. Só que, fechado, o React não consegue mostrar nem enviar fotos, e mandar tudo pela API seria voltar ao começo do capítulo. Existe uma terceira saída.

## Presigned URLs: um ingresso com hora marcada

Uma *presigned URL* é uma URL do S3 que já carrega a assinatura de uma requisição específica. Quem gera é alguém com permissão (a API do Rangô, usando a role dela). Quem usa pode ser qualquer pessoa, sem credencial nenhuma. A URL diz exatamente o que pode ser feito (método, bucket, key, às vezes o `Content-Type`), até quando, e em nome de quem.

A analogia é um ingresso de show com assento marcado e horário. A bilheteria (a API) confere se você pode entrar e emite o ingresso. Na porta (o S3), ninguém pergunta seu nome, só confere o ingresso. Se você tentar entrar em outra sessão ou sentar em outro lugar, a assinatura não bate e a porta fecha.

O fluxo de upload direto do navegador fica assim:

```text
  React                       API (FastAPI)                    S3
    |                              |                            |
    | 1. POST /fotos/upload-url    |                            |
    |    {content_type}            |                            |
    |----------------------------->|                            |
    |                              | 2. confere permissão,      |
    |                              |    escolhe a key,          |
    |                              |    assina localmente       |
    | 3. {url, chave}              |    (sem chamar o S3)       |
    |<-----------------------------|                            |
    |                                                           |
    | 4. PUT url  (4 MB, direto para a AWS)                     |
    |---------------------------------------------------------->|
    | 5. 200 OK                                                 |
    |<----------------------------------------------------------|
    |                              |                            |
    | 6. POST /fotos {chave}       |                            |
    |----------------------------->| 7. HEAD na key: existe?    |
    |                              |    tamanho ok?             |
    |                              |--------------------------->|
```

Repare no passo 2: gerar a URL é um cálculo local com a credencial da API, sem chamada ao S3. Os 4 MB vão do celular direto para a AWS, e o Uvicorn só cuida de duas requisições pequenas de JSON.

Agora as letras miúdas, todas importantes:

**Validade.** Uma URL assinada com credenciais de um usuário IAM pode valer até 7 dias. Só que o Rangô não usa usuário IAM (o capítulo 8 cuidou disso), e aqui mora a surpresa: uma URL assinada com credenciais temporárias expira quando a credencial expira, mesmo que você tenha pedido mais tempo. Na EC2, as credenciais da role (o instance profile) costumam durar umas 6 horas. Numa sessão com `AssumeRole`, o padrão é 1 hora. No ECS, as credenciais são trocadas a cada 1 a 6 horas. Na sua máquina, com o SSO do capítulo 8, a URL morre junto com a sessão. Peça sempre expirações curtas, e você nem chega perto desse limite.

**Reuso.** A URL pode ser usada quantas vezes alguém quiser até expirar. Um `PUT` repetido na mesma key substitui o objeto. Por isso a key é sempre gerada pela API com um UUID, e nunca escolhida pelo navegador.

**Portador.** A presigned URL funciona como um bearer token. Quem tiver a URL tem o acesso, então ela não deve ir para logs, analytics ou mensagens de erro detalhadas.

O boto3 também oferece a presigned POST (`generate_presigned_post`), pensada para formulários HTML. No Rangô vamos de presigned PUT, mais simples com `fetch`, e conferimos o tamanho depois do upload.

## Mão na massa: as fotos do Rangô no S3

Pré-requisitos: AWS CLI v2 com o profile `rango-dev` do capítulo 8 (e o `rango-admin` para um passo de IAM), o projeto do Rangô com o Compose do capítulo 6 e uma foto qualquer chamada `lasanha.jpg` na pasta atual. Todos os comandos usam `us-east-1`.

```bash
export AWS_PROFILE=rango-dev
aws sso login --sso-session rango
```

### Criar o bucket

O nome precisa ser único no mundo, então usamos o número da conta como sufixo:

```bash
CONTA=$(aws sts get-caller-identity --query Account --output text)
BUCKET="rango-fotos-pratos-$CONTA"
echo "$BUCKET"

aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
```

```json
{
    "Location": "/rango-fotos-pratos-123456789012"
}
```

Em `us-east-1`, o `create-bucket` não leva `--create-bucket-configuration`. Em outras regiões, como `sa-east-1`, é preciso acrescentar `--create-bucket-configuration LocationConstraint=sa-east-1`. O bucket fica em `us-east-1`, junto da nossa VPC e do gateway endpoint.

### Conferir o que veio ligado

Antes de mexer em qualquer coisa, confirme os padrões de segurança:

```bash
aws s3api get-public-access-block --bucket "$BUCKET"
aws s3api get-bucket-ownership-controls --bucket "$BUCKET"
aws s3api get-bucket-encryption --bucket "$BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault'
```

```json
{
    "PublicAccessBlockConfiguration": {
        "BlockPublicAcls": true,
        "IgnorePublicAcls": true,
        "BlockPublicPolicy": true,
        "RestrictPublicBuckets": true
    }
}
{
    "OwnershipControls": {
        "Rules": [
            {
                "ObjectOwnership": "BucketOwnerEnforced"
            }
        ]
    }
}
{
    "SSEAlgorithm": "AES256"
}
```

As quatro travas estão ligadas, as ACLs estão desabilitadas e a criptografia SSE-S3 está ativa. Agora suba uma foto e tente lê-la como um estranho leria:

```bash
aws s3 cp lasanha.jpg "s3://$BUCKET/teste/lasanha.jpg"
curl -s "https://$BUCKET.s3.amazonaws.com/teste/lasanha.jpg"
```

```text
<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>AccessDenied</Code><Message>Access Denied</Message>...</Error>
```

Esse `AccessDenied` é o comportamento que queremos. O `curl` não assinou nada, então é um anônimo pedindo, e o bucket recusa. Para ver a diferença, gere uma URL assinada de leitura pela CLI:

```bash
URL=$(aws s3 presign "s3://$BUCKET/teste/lasanha.jpg" --expires-in 120)
curl -s -o /dev/null -w "%{http_code}\n" "$URL"
```

```text
200
```

Abra a mesma URL no navegador e a foto aparece. Espere dois minutos, recarregue, e o S3 responde com `AccessDenied` e a mensagem `Request has expired`.

### A bucket policy

O bucket já é privado. A policy que vamos colocar só acrescenta proibições, com dois `Deny`. O primeiro recusa qualquer acesso que não use HTTPS. O segundo usa a condição `s3:signatureAge`, a idade da assinatura em milissegundos, para recusar uploads assinados há mais de 10 minutos. Mesmo que um bug na API gere uma URL de upload com validade de um dia, ela para de funcionar em 10 minutos. Salve como `infra/s3/rango-fotos-policy.json`, trocando o nome do bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SoHttps",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::rango-fotos-pratos-123456789012",
        "arn:aws:s3:::rango-fotos-pratos-123456789012/*"
      ],
      "Condition": {
        "Bool": { "aws:SecureTransport": "false" }
      }
    },
    {
      "Sid": "UploadComAssinaturaRecente",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::rango-fotos-pratos-123456789012/*",
      "Condition": {
        "NumericGreaterThan": { "s3:signatureAge": "600000" }
      }
    }
  ]
}
```

```bash
aws s3api put-bucket-policy --bucket "$BUCKET" \
  --policy file://infra/s3/rango-fotos-policy.json
```

O `"Principal": "*"` aqui é seguro porque o efeito é `Deny`: a regra vale para todo mundo, inclusive você, e só tira permissões. O Block Public Access só barra policies que concedem acesso público. Restringimos a idade da assinatura apenas no `PutObject` porque as URLs de leitura que a API vai gerar valem uma hora, e o navegador precisa delas durante todo esse tempo.

### Versionamento e lifecycle

Ligue o versionamento:

```bash
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
```

Agora veja o delete marker em ação. Sobrescreva a foto de teste, apague-a e liste as versões:

```bash
aws s3 cp lasanha.jpg "s3://$BUCKET/teste/lasanha.jpg"
aws s3 rm "s3://$BUCKET/teste/lasanha.jpg"
aws s3api list-object-versions --bucket "$BUCKET" --prefix teste/ \
  --query '{Versoes: Versions[].{Id: VersionId, Atual: IsLatest}, Marcadores: DeleteMarkers[].{Id: VersionId, Atual: IsLatest}}'
```

```json
{
    "Versoes": [
        {
            "Id": "Rb5t0jEXAMPLEqv3N8d1Wc2x",
            "Atual": false
        },
        {
            "Id": "null",
            "Atual": false
        }
    ],
    "Marcadores": [
        {
            "Id": "kQ7mXEXAMPLEzT4pLa9sVb0e",
            "Atual": true
        }
    ]
}
```

A versão com `Id` `null` é a primeira foto, enviada antes de o versionamento ser ligado. A outra é a cópia que acabamos de subir. O marcador é o `rm`. A foto parece apagada (um `aws s3 ls` não mostra nada), mas as duas versões continuam lá. Para desfazer o `rm`, apague o marcador:

```bash
aws s3api delete-object --bucket "$BUCKET" --key teste/lasanha.jpg \
  --version-id kQ7mXEXAMPLEzT4pLa9sVb0e
aws s3 ls "s3://$BUCKET/teste/"
```

A foto voltou. Agora a lifecycle rule, para que esse histórico não cresça para sempre. Salve como `infra/s3/rango-fotos-lifecycle.json`:

```json
{
  "Rules": [
    {
      "ID": "limpar-historico",
      "Filter": { "Prefix": "" },
      "Status": "Enabled",
      "NoncurrentVersionExpiration": { "NoncurrentDays": 30 },
      "Expiration": { "ExpiredObjectDeleteMarker": true },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
```

```bash
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration file://infra/s3/rango-fotos-lifecycle.json
```

A regra faz três coisas. Versões antigas somem 30 dias depois de deixarem de ser a atual, o que dá um mês para perceber e desfazer um erro. Delete markers que ficaram sozinhos, sem nenhuma versão embaixo, são removidos. E uploads em partes (*multipart uploads*) que começaram e nunca terminaram são abortados em 7 dias. Esse último item merece atenção: um único `PUT` aceita objetos de até 5 GB, e arquivos maiores são enviados em partes. Se o envio for interrompido, as partes já recebidas ficam guardadas, invisíveis no `aws s3 ls`, e cobradas todo mês.

### CORS: o navegador também precisa de permissão

A API do Rangô já tem CORS configurado desde o capítulo 1. O bucket é outra origem, e o navegador vai fazer uma requisição *preflight* (`OPTIONS`) antes do `PUT`. Sem uma configuração de CORS no bucket, o upload falha no console do navegador com a mensagem `has been blocked by CORS policy`, mesmo com a URL assinada correta. Salve como `infra/s3/rango-fotos-cors.json`:

```json
{
  "CORSRules": [
    {
      "AllowedOrigins": ["https://rango.test:5173"],
      "AllowedMethods": ["PUT"],
      "AllowedHeaders": ["content-type"],
      "MaxAgeSeconds": 3000
    }
  ]
}
```

```bash
aws s3api put-bucket-cors --bucket "$BUCKET" \
  --cors-configuration file://infra/s3/rango-fotos-cors.json
```

Só `PUT` e só a origem do front local. As fotos vão ser exibidas com a tag `<img>`, que não precisa de CORS para mostrar uma imagem. Quando o front tiver domínio próprio, no capítulo 14, a origem entra nesta lista.

### Permissão para a role do servidor

Quando a API rodar na EC2, quem assina as URLs é a role `rango-ec2` do capítulo 8. Ela precisa das ações que a API usa, e só no prefixo `fotos/`. Salve como `iam/rango-ec2-fotos.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "FotosDosPratos",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::rango-fotos-pratos-123456789012/fotos/*"
    }
  ]
}
```

Criar policies é tarefa de IAM, e o `PowerUserAccess` do profile `rango-dev` não inclui IAM. Use o profile de administrador só para este comando:

```bash
aws iam put-role-policy --profile rango-admin \
  --role-name rango-ec2 --policy-name RangoFotos \
  --policy-document file://iam/rango-ec2-fotos.json
```

Não incluímos `s3:ListBucket`. A API sempre sabe qual key quer, porque guarda as keys no Redis, e não precisa listar o bucket. Uma consequência curiosa: sem `ListBucket`, um `HEAD` numa key inexistente devolve 403 em vez de 404, para não revelar se o objeto existe. O código abaixo trata os dois casos do mesmo jeito.

Uma presigned URL só funciona se quem a assinou tiver a permissão. Se a role não tiver `s3:PutObject`, a API gera a URL sem reclamar (é só um cálculo), e o erro aparece no navegador como `403 AccessDenied`.

### A API: gerar, registrar e listar

Acrescente `boto3` ao `backend/requirements.txt` e crie `backend/app/fotos.py`:

```python
import os
import uuid

import boto3
import redis
from botocore.config import Config
from botocore.exceptions import ClientError
from fastapi import APIRouter, HTTPException, Path
from pydantic import BaseModel

BUCKET = os.environ["FOTOS_BUCKET"]
TIPOS_ACEITOS = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}
TAMANHO_MAXIMO = 10 * 1024 * 1024  # 10 MB

s3 = boto3.client(
    "s3",
    region_name=os.environ.get("AWS_REGION", "us-east-1"),
    config=Config(
        signature_version="s3v4",
        # Não acrescenta checksums opcionais à URL assinada; o navegador não os enviaria
        request_checksum_calculation="when_required",
    ),
)
r = redis.Redis.from_url(os.environ["REDIS_URL"], decode_responses=True)

router = APIRouter()
Restaurante = Path(pattern=r"^[a-z0-9-]{1,60}$")


class PedidoDeUpload(BaseModel):
    content_type: str


class FotoEnviada(BaseModel):
    chave: str


@router.post("/restaurantes/{restaurante}/fotos/upload-url")
def gerar_url_de_upload(pedido: PedidoDeUpload, restaurante: str = Restaurante):
    extensao = TIPOS_ACEITOS.get(pedido.content_type)
    if extensao is None:
        raise HTTPException(status_code=415, detail="Envie JPEG, PNG ou WebP")
    chave = f"fotos/{restaurante}/{uuid.uuid4()}.{extensao}"
    url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": BUCKET, "Key": chave, "ContentType": pedido.content_type},
        ExpiresIn=300,
    )
    return {"url": url, "chave": chave}


@router.post("/restaurantes/{restaurante}/fotos", status_code=201)
def registrar_foto(foto: FotoEnviada, restaurante: str = Restaurante):
    if not foto.chave.startswith(f"fotos/{restaurante}/"):
        raise HTTPException(status_code=400, detail="Chave de outro restaurante")
    try:
        info = s3.head_object(Bucket=BUCKET, Key=foto.chave)
    except ClientError:
        raise HTTPException(status_code=404, detail="Foto não encontrada no bucket")
    if info["ContentLength"] > TAMANHO_MAXIMO:
        s3.delete_object(Bucket=BUCKET, Key=foto.chave)
        raise HTTPException(status_code=413, detail="Foto maior que 10 MB")
    r.sadd(f"fotos:{restaurante}", foto.chave)
    return {"chave": foto.chave}


@router.get("/restaurantes/{restaurante}/fotos")
def listar_fotos(restaurante: str = Restaurante):
    return [
        s3.generate_presigned_url(
            "get_object", Params={"Bucket": BUCKET, "Key": chave}, ExpiresIn=3600
        )
        for chave in sorted(r.smembers(f"fotos:{restaurante}"))
    ]
```

E registre o router no `backend/app/main.py`:

```python
from app.fotos import router as fotos_router

app.include_router(fotos_router)
```

Alguns detalhes desse código merecem comentário.

O `ContentType` entra na assinatura. O navegador precisa enviar exatamente esse `Content-Type` no `PUT`, ou o S3 recusa. Isso impede que alguém peça uma URL para `image/jpeg` e suba um HTML no lugar, que depois seria servido com o tipo errado.

O padrão no parâmetro `restaurante` evita keys estranhas. Falta conferir se quem pede é dono do restaurante, checagem que entra quando o Rangô tiver login de restaurante: gerar uma presigned URL é conceder uma permissão.

A configuração `request_checksum_calculation="when_required"` evita que as versões recentes do boto3, que calculam checksums de integridade por padrão, coloquem na assinatura algo que o `fetch` não vai enviar.

Por fim, as keys ficam no Redis (`fotos:{restaurante}`), como os pedidos do capítulo 5. É o mesmo arranjo provisório. No próximo capítulo, os pedidos ganham um banco de verdade; o registro das fotos continua no Redis até o capítulo 24, quando a API passa a perguntar ao próprio bucket.

### O React: enviar direto para a AWS

Crie `frontend/src/EnviarFoto.tsx`:

```tsx
import { useState, type ChangeEvent } from "react";

const API = import.meta.env.VITE_API_URL ?? "http://localhost:8000";

export function EnviarFoto({ restaurante }: { restaurante: string }) {
  const [status, setStatus] = useState("");

  async function enviar(evento: ChangeEvent<HTMLInputElement>) {
    const arquivo = evento.target.files?.[0];
    if (!arquivo) return;

    setStatus("Pedindo autorização...");
    const pedido = await fetch(`${API}/restaurantes/${restaurante}/fotos/upload-url`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ content_type: arquivo.type }),
    });
    if (!pedido.ok) {
      setStatus("Formato não aceito. Use JPEG, PNG ou WebP.");
      return;
    }
    const { url, chave } = await pedido.json();

    setStatus("Enviando a foto...");
    const upload = await fetch(url, {
      method: "PUT",
      headers: { "Content-Type": arquivo.type },
      body: arquivo,
    });
    if (!upload.ok) {
      setStatus(`O envio falhou (HTTP ${upload.status}).`);
      return;
    }

    const registro = await fetch(`${API}/restaurantes/${restaurante}/fotos`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chave }),
    });
    setStatus(registro.ok ? "Foto publicada." : "A foto foi recusada.");
  }

  return (
    <label>
      Foto do prato{" "}
      <input type="file" accept="image/jpeg,image/png,image/webp" onChange={enviar} />
      <span>{status}</span>
    </label>
  );
}
```

O `body: arquivo` envia o `File` em binário, sem `FormData`, com o mesmo `Content-Type` usado na assinatura.

### Rodar no Compose com as suas credenciais

Na EC2, o boto3 encontraria as credenciais da role sozinho. No Compose local, o container não tem credencial, então emprestamos a sessão SSO da sua máquina, montando o `~/.aws` como somente leitura. No `compose.yaml`, acrescente ao serviço `api` (e ao `api-canario`, se ele estiver ligado):

```yaml
    image: rango-api:0.6.0
    environment:
      CORS_ORIGINS: "https://rango.test:5173"
      REDIS_URL: "redis://redis:6379/0"
      FOTOS_BUCKET: "rango-fotos-pratos-123456789012"
      AWS_REGION: "us-east-1"
      AWS_PROFILE: "rango-dev"   # só em desenvolvimento
    volumes:
      - ~/.aws:/home/rango/.aws:ro
```

O caminho `/home/rango` vem do `useradd --create-home rango` do Dockerfile. Esse volume serve só para a sua máquina; em produção, credencial vem da role, nunca de arquivo. Depois:

```bash
docker build -t rango-api:0.6.0 backend
docker compose up -d --scale api=3
```

Coloque o `<EnviarFoto restaurante="cantina-da-nona" />` em alguma tela do `App.tsx`, abra `https://rango.test:5173` e envie a foto. Na aba Network do navegador você vai ver quatro requisições: o `POST` para a API, o `OPTIONS` e o `PUT` para `rango-fotos-pratos-...s3.amazonaws.com`, e o `POST` de registro. O `PUT` de 4 MB nunca passou pelo Nginx nem pelo Uvicorn. Confira pelo terminal:

```bash
aws s3 ls "s3://$BUCKET/fotos/cantina-da-nona/"
curl -s https://api.rango.test:8443/restaurantes/cantina-da-nona/fotos
```

### Ver o erro antes do acerto

Vale a pena quebrar o upload de propósito, para reconhecer a mensagem quando ela aparecer sem querer. Peça uma URL para `image/jpeg` e envie dizendo que é PNG:

```bash
RESPOSTA=$(curl -s -X POST https://api.rango.test:8443/restaurantes/cantina-da-nona/fotos/upload-url \
  -H "Content-Type: application/json" -d '{"content_type": "image/jpeg"}')
URL=$(echo "$RESPOSTA" | python3 -c 'import json, sys; print(json.load(sys.stdin)["url"])')

curl -s -X PUT -H "Content-Type: image/png" --upload-file lasanha.jpg "$URL"
```

```text
<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated
does not match the signature you provided. Check your key and signing method.</Message>...
```

Troque para `image/jpeg` e o mesmo comando devolve 200. `SignatureDoesNotMatch` quase sempre significa que a requisição usada é diferente da que foi assinada: outro método, outro cabeçalho, um proxy que mexeu em algo no caminho, ou o relógio da máquina que assinou fora de sincronia. Outro erro que você vai encontrar é `ExpiredToken`: a URL ainda estava no prazo, mas a credencial temporária que a assinou expirou. No desenvolvimento local, isso acontece quando a sessão SSO acaba; um `aws sso login` resolve.

### O que fica ligado

O bucket fica, porque é a casa das fotos do Rangô daqui em diante. O custo de algumas dezenas de MB é uma fração de centavo por mês. Apague a foto de teste e as versões dela, e derrube o Compose:

```bash
aws s3 rm "s3://$BUCKET/teste/lasanha.jpg"
docker compose down
```

O `rm` só cria um delete marker, e a lifecycle rule limpa o resto em 30 dias. Para apagar o bucket inteiro um dia, esvazie-o antes pela opção *Empty* do console: num bucket versionado, `aws s3 rm --recursive` deixa as versões antigas para trás.

## Armadilhas e casos reais

> **Na vida real:** Em junho de 2017, Chris Vickery, pesquisador da UpGuard, encontrou um bucket do S3 aberto com dados de clientes da Verizon. O bucket pertencia à NICE Systems, fornecedora do call center da operadora, e continha nomes, endereços e PINs usados para confirmar a identidade do cliente por telefone. A UpGuard falou em 14 milhões de clientes; a Verizon, em cerca de 6 milhões. Bastava conhecer a URL para baixar os arquivos, e o bucket ficou aberto por mais de uma semana depois do aviso.

O vazamento da Capital One, citado no capítulo 9, foi de outro tipo: nenhum bucket estava público, e o atacante usou credenciais de uma role com acesso a buckets demais. Por isso a `RangoFotos` dá acesso só ao prefixo `fotos/`.

> **Armadilha:** O Block Public Access do bucket pode ser desligado com um clique, e o console avisa, mas deixa. Ligue também o Block Public Access na conta (`aws s3control put-public-access-block --account-id ... --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true`). Quando o Rangô precisar de um bucket realmente público, a resposta vai ser CloudFront com OAC, no capítulo 14, que serve o conteúdo sem abrir o bucket.

> **Armadilha:** Key escolhida pelo cliente. Se o React mandasse `fotos/cantina-da-nona/lasanha.jpg` e a API assinasse essa key, qualquer pessoa poderia sobrescrever a foto de outro prato, já que um `PUT` na mesma key substitui o objeto. A API sempre gera a key, com UUID.

> **Armadilha:** Presigned URL em log. O middleware de log do capítulo 6 registra o path das requisições, e a resposta de `/fotos/upload-url` contém uma URL que funciona como senha por alguns minutos. Não registre corpos de resposta, e não mande essas URLs para ferramentas de analytics do front.

> **Armadilha:** Versões acumulando. Uma rotina que regrava todas as fotos toda noite multiplica o armazenamento por 30 em um mês num bucket versionado sem lifecycle, e o `aws s3 ls` continua mostrando o tamanho de sempre, porque só lista as versões atuais.

> **Dica:** A EC2 nas subnets privadas da `rango-vpc` fala com o S3 pelo gateway endpoint que criamos no capítulo 10, sem NAT e sem custo por GB. O upload do navegador não passa por ali: ele vai pela internet direto para o S3. São dois caminhos diferentes para o mesmo bucket.

## Resumo

- O S3 guarda objetos (bytes mais metadados) em buckets, acessados por HTTP por key. Não há pastas, só prefixos, e não há edição parcial.
- Nomes de bucket são únicos no mundo. Não há limite de tamanho do bucket, e a classe padrão replica cada objeto em várias AZs.
- Classes mais frias custam menos para guardar e mais para ler, com duração mínima cobrada (30, 90 ou 180 dias) e tamanho mínimo de 128 KB em algumas delas.
- Lifecycle rules movem e apagam objetos por idade. Desde setembro de 2024, por padrão, não transicionam objetos menores que 128 KB.
- Versionamento transforma sobrescrita e exclusão em operações reversíveis. Com lifecycle, o histórico tem prazo.
- Bucket policy é a resource-based policy do S3. Block Public Access fica acima dela e, desde abril de 2023, vem ligado em todo bucket novo, com ACLs desabilitadas. Objetos novos são criptografados com SSE-S3 desde janeiro de 2023.
- Presigned URLs dão acesso temporário a uma operação específica sem abrir o bucket. Expiram junto com a credencial que as assinou e funcionam como senha enquanto valem.
- O Rangô ganhou o bucket `rango-fotos-pratos-<conta>`, privado, versionado, com lifecycle, CORS e uma policy que exige HTTPS e assinaturas recentes. O React envia fotos direto para o S3, e a API só assina e registra.

## O banco que ninguém quer acordar para cuidar

As fotos saíram do servidor. O próximo inquilino é bem mais delicado. No capítulo 10, o Postgres do Rangô rodou numa EC2 numa subnet privada, protegido por três camadas de rede. Só que alguém precisa rodar o `scripts/backup.sh` do capítulo 6 e guardar o dump em lugar seguro, aplicar o próximo patch do PostgreSQL 17 sem derrubar os pedidos e vigiar o disco do banco, que enche de madrugada do mesmo jeito que o das fotos encheu. E os pedidos continuam no Redis, esperando um banco de verdade. No próximo capítulo, o Amazon RDS assume essa rotina: backups automáticos com point-in-time recovery, uma réplica pronta em outra AZ e o banco do Rangô morando nas subnets privadas que construímos.

## Referências

- Amazon S3, guia do usuário: https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html
- Restrições e limites de buckets: https://docs.aws.amazon.com/AmazonS3/latest/dev/BucketRestrictions.html
- Até 1 milhão de buckets por conta (novembro de 2024): https://aws.amazon.com/about-aws/whats-new/2024/11/amazon-s3-up-1-million-buckets-per-aws-account/
- Preços do Amazon S3: https://aws.amazon.com/s3/pricing/
- Levantamento de preços do S3 por terceiros (valores de referência usados no capítulo): https://cloudburn.io/blog/amazon-s3-pricing
- Considerações sobre transições de lifecycle (30 dias, 128 KB): https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html
- Novos padrões de segurança em buckets (abril de 2023): https://aws.amazon.com/about-aws/whats-new/2023/04/amazon-s3-security-best-practices-buckets-default
- Anúncio das mudanças de abril de 2023: https://aws.amazon.com/blogs/aws/heads-up-amazon-s3-security-changes-are-coming-in-april-of-2023
- Block Public Access e ACLs desabilitadas em qualquer método de criação: https://aws.amazon.com/about-aws/whats-new/2022/12/amazon-s3-automatically-enable-block-public-access-disable-access-control-lists-buckets-april-2023
- Criptografia automática de objetos novos (janeiro de 2023): https://aws.amazon.com/about-aws/whats-new/2023/01/amazon-s3-automatically-encrypts-new-objects
- FAQ de criptografia padrão: https://docs.aws.amazon.com/AmazonS3/latest/userguide/default-encryption-faq.html
- Presigned URLs (validade, credenciais temporárias, `s3:signatureAge`, erros comuns): https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html
- boto3, `generate_presigned_url`: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/s3/client/generate_presigned_url.html
- Vazamento de dados de clientes da Verizon via bucket da NICE Systems (TechTarget): https://www.techtarget.com/searchsecurity/news/450422709/Misconfigured-AWS-S3-bucket-exposes-millions-of-Verizon-customers-data
- Vazamento da Capital One, controles a revisar (Rackspace): https://www.rackspace.com/pt-br/blog/capital-one-data-breach-two-security-controls-you-should-review
