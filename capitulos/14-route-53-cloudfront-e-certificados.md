# Route 53, CloudFront e certificados

No capítulo 13, o Rangô passou a rodar atrás do Application Load Balancer `rango-alb`, com um Auto Scaling Group de 2 a 6 instâncias criadas a partir da AMI `rango-api-20261015`, nas subnets privadas. Ele sobreviveu à remoção de uma instância sem erro e escalou sozinho no teste de carga. No fim, desmontamos o que cobra por hora e guardamos o Launch Template, os Security Groups, a AMI e o snapshot `rango-db-final-cap13`. Ficou a promessa: um nome de verdade, HTTPS e o React perto de quem pede comida.

## Um endereço para a TV

Quinta-feira, 15h. A produtora do especial de sábado manda uma mensagem: "Qual endereço a gente coloca na tela?". Você abre o terminal e copia o que tem: `http://rango-alb-1234567890.us-east-1.elb.amazonaws.com`. Ninguém vai digitar isso, e a produtora nem responde.

O nome é o problema mais visível. O segundo está no `http://`. Os pedidos, com endereço de entrega, e as presigned URLs das fotos, que funcionam como senha, atravessam a internet em texto puro. Qualquer pessoa no Wi-Fi da praça de alimentação do capítulo 2 consegue ler, e o navegador mostra "não seguro" ao lado do endereço.

O terceiro aparece quando o React sai do seu notebook. A primeira ideia é deixar o Nginx das instâncias servir os arquivos do `npm run build`, como no capítulo 3. Funciona, mas pense na sócia em Recife: cada arquivo vai até a Virgínia e volta. Num teste hipotético, mas com números típicos, a ida e volta (o RTT) entre Recife e `us-east-1` fica entre 120 e 150 milissegundos. Antes do primeiro byte do `index.html`, o navegador gasta uma ida e volta no TCP, outra no TLS 1.3 e mais uma na requisição: quase meio segundo. Depois vem o bundle JavaScript, com algumas centenas de kilobytes. O TCP começa enviando pouco e aumenta aos poucos (o mecanismo se chama *slow start*), e cada aumento custa mais uma ida e volta. Num celular em 4G, a tela branca passa de dois segundos sem que nenhum servidor esteja lento.

E essa carga cairia nas instâncias que atendem `POST /pedidos`, com arquivos iguais para todo mundo que só mudam no deploy, o caso ideal para cache.

O capítulo 2 explicou a teoria de DNS, certificados e CDN. Agora ela vira prática, com três serviços da AWS.

## Os três serviços

### Amazon Route 53

O Amazon Route 53 é o serviço de DNS da AWS. No vocabulário do capítulo 2, ele faz o papel de servidor autoritativo: guarda a zona do `rango.com.br` e responde aos resolvers do mundo inteiro quando alguém pergunta pelo endereço.

A zona, no Route 53, se chama **hosted zone**. Ao criar uma, a AWS atribui quatro servidores de nome a ela, espalhados por domínios de topo diferentes (algo como `ns-1234.awsdns-26.org` e `ns-567.awsdns-06.net`). Se um desses domínios de topo tiver problemas, os outros continuam respondendo. Esses quatro nomes são os que você entrega ao registrador.

O domínio continua registrado no Registro.br, como no capítulo 2. O registrador e o provedor de DNS são papéis separados: o Registro.br diz à hierarquia do `.br` quais servidores respondem pelo `rango.com.br`, e o Route 53 dá as respostas. Para trocar de provedor, basta trocar os quatro nomes no painel do registrador.

Uma hosted zone pode ser pública, visível na internet, ou privada, visível só dentro das VPCs que você associar a ela. A do Rangô é pública.

Os registros são os mesmos do capítulo 2 (A, AAAA, CNAME, MX, TXT), com uma adição que resolve um problema deixado lá atrás: o CNAME é proibido no apex da zona, o nome "pelado" `rango.com.br`. O apex precisa ter os registros SOA e NS, e o CNAME não pode coexistir com nenhum outro registro no mesmo nome. Isso seria contornável se o ALB e o CloudFront tivessem IP fixo, mas eles só têm nome DNS, com IPs que mudam.

A resposta da AWS é o **registro alias**. Você cria um registro do tipo A (ou AAAA) e, em vez de um IP, aponta para um recurso da AWS: um load balancer, uma distribuição do CloudFront, um bucket configurado como site. Quando um resolver pergunta pelo `rango.com.br`, o Route 53 consulta os IPs atuais do recurso e responde com eles, como se fosse um A comum. Para o mundo de fora, é um registro A. Por dentro, ele se comporta como um CNAME que o próprio Route 53 resolve antes de responder.

Pense numa property do Python. Quem lê `pedido.total` recebe um número, sem saber que por trás existe uma função calculando o valor a cada acesso. O alias é a property do DNS.

O alias tem duas vantagens além de funcionar no apex. Consultas a alias que apontam para recursos da AWS como ELB e CloudFront não são cobradas. E, num alias para load balancer, a opção `EvaluateTargetHealth` faz o Route 53 levar em conta a saúde do alvo, o que importa quando há mais de um destino.

Isso leva aos **health checks** e às **políticas de roteamento**. Verificadores do Route 53 em várias regiões chamam o seu endpoint a cada 30 segundos (ou 10, pagando mais), e ele é considerado saudável quando mais de 18% deles concordam. A política decide a resposta: a simples devolve sempre o mesmo valor; a ponderada divide por pesos, útil para um canary; a de latência escolhe a região mais próxima; a de failover troca para o secundário quando o health check do primário falha. É o DR do capítulo 6 feito no DNS, com o TTL definindo quanto os clientes demoram para perceber a troca.

O Rangô tem uma região só e usa a política simples. O health check entra como vigia externo, olhando a API como um cliente veria.

### AWS Certificate Manager

O AWS Certificate Manager (ACM) emite certificados TLS públicos e cuida da renovação. Para certificados usados em serviços integrados, como ALB e CloudFront, a emissão não custa nada.

O ACM faz o papel de CA e de Certbot ao mesmo tempo. Você pede um certificado para uma lista de nomes, prova que controla o domínio e recebe um ARN. A chave privada fica guardada na AWS, e você nunca a vê: não há arquivo `.pem` para vazar num commit nem para copiar entre servidores. O certificado é instalado no ALB ou na distribuição pelo ARN.

A prova de posse é a validação DV do capítulo 2. O ACM aceita três métodos: DNS, e-mail e, mais recentemente, HTTP. Use o DNS. O ACM informa um registro CNAME com nomes aleatórios, algo como `_3f1c9a.rango.com.br` apontando para `_8b2e7d.acm-validations.aws.`, e você o cria na zona. Enquanto esse registro existir, o ACM consegue revalidar sozinho e renovar o certificado sem ninguém fazer nada. A validação por HTTP não aceita certificados curinga, e a por e-mail depende de alguém clicar num link a cada renovação.

As regras de validade mudaram em 2026, seguindo o calendário do CA/Browser Forum do capítulo 2: a partir de 15 de março, no máximo 200 dias. Desde fevereiro de 2026, o ACM emite e renova certificados públicos com 198 dias, em vez de 395; os antigos valem até a próxima renovação. A renovação começa 45 dias antes do vencimento, mais ou menos a cada cinco meses. Com renovação automática, ninguém percebe a mudança.

Há uma regra que surpreende todo mundo uma vez: o CloudFront só aceita certificados do ACM emitidos na região `us-east-1`, seja qual for a região da sua aplicação. O CloudFront é global, e a configuração dele vive na Virgínia. Se a API do Rangô estivesse em `sa-east-1`, você precisaria de dois certificados: um em São Paulo para o ALB e outro em `us-east-1` para o CloudFront. Como tudo do Rangô está em `us-east-1`, um único certificado com `rango.com.br`, `www.rango.com.br` e `api.rango.com.br` serve aos dois. Esse é um dos motivos que o capítulo 7 listou para começar pela Virgínia.

### Amazon CloudFront

O Amazon CloudFront é a CDN da AWS, com centenas de pontos de presença pelo mundo, vários deles no Brasil. O que o capítulo 2 chamou de borda, a AWS chama de *edge location*.

A unidade de configuração é a **distribuição**. Ela recebe um nome como `d1a2b3c4d5e6f7.cloudfront.net`, aceita nomes alternativos (os seus domínios, com o certificado do ACM) e liga um ou mais comportamentos de cache a uma ou mais origens. Uma origem pode ser um bucket S3, um load balancer ou qualquer servidor HTTP. Um comportamento diz que caminhos ele atende (`/assets/*`, por exemplo), qual política de cache usar e o que fazer com HTTP sem criptografia.

Para o React, a origem natural é um bucket S3. O build do Vite gera um `index.html` e uma pasta `assets/` com arquivos cujo nome carrega um hash do conteúdo. São arquivos estáticos, e o S3 do capítulo 11 guarda arquivos estáticos por centavos. O CloudFront fica na frente: a sócia em Recife fala com uma borda no Brasil, a dezenas de milissegundos ou menos, e só a primeira requisição de cada arquivo em cada borda vai até o bucket na Virgínia. As seguintes saem do cache da borda. O handshake TLS também acontece na borda, perto dela.

Falta um detalhe de segurança. O bucket precisa ficar privado, com o Block Public Access do capítulo 11 ligado, e mesmo assim entregar arquivos ao CloudFront. A peça que resolve isso se chama **Origin Access Control (OAC)**. A distribuição assina cada requisição ao S3 com SigV4, a mesma assinatura que a AWS CLI usa, e a bucket policy libera `s3:GetObject` para o serviço `cloudfront.amazonaws.com`, com uma condição: o ARN de origem precisa ser o da sua distribuição. Qualquer outra distribuição, de qualquer outra conta, recebe `403`. Quem tentar o endereço direto do bucket também.

Tutoriais antigos usam OAI, o mecanismo anterior, que a AWS mantém como legado, ou o *static website hosting* do S3 com bucket público. O OAC só funciona com o endpoint REST do bucket (`bucket.s3.us-east-1.amazonaws.com`), e o bucket público é o que o capítulo 11 ensinou a evitar.

Sobre custo, o CloudFront tem hoje dois modelos. No pay-as-you-go, você paga por GB entregue e por requisição, com uma franquia mensal permanente de 1 TB de saída e 10 milhões de requisições. Uma distribuição parada não cobra nada. Existem também planos de preço fixo (Free, Pro, Business, Premium), sem cobrança de excedente, cada um cobrindo uma distribuição e um domínio apex, com WAF, DNS e certificado incluídos. O Free custa zero, com 1 milhão de requisições e 100 GB por mês. Os comandos deste capítulo usam o pay-as-you-go, que no volume do Rangô também não deve gerar cobrança. Preços e franquias de referência, `us-east-1`, consultados em outubro de 2026; confira a página oficial antes de decidir.

## Mão na massa: rango.com.br no ar

Pré-requisitos: tudo o que o capítulo 13 deixou (Launch Template `rango-api`, AMI `rango-api-20261015`, Security Groups `rango-web`, `rango-alb`, `rango-db` e `rango-cache`, snapshot `rango-db-final-cap13`, role `rango-ec2`, bucket `rango-fotos-pratos-<conta>`), o profile `rango-dev`, e o domínio `rango.com.br` registrado no Registro.br com acesso ao painel. Use o seu próprio domínio no lugar do `rango.com.br` em todos os comandos. Para o build do front, Node.js e o repositório do Rangô.

Sobre custo: a hosted zone cobra US$ 0,50 por mês, e o mês começa a contar na criação. O banco, o cache, o ALB e as instâncias voltam a cobrar por hora até a seção "Desmontar".

### A zona e a delegação

Comece pela zona, porque a delegação pode levar algum tempo para valer e o certificado depende dela:

```bash
export AWS_PROFILE=rango-dev
aws sso login --sso-session rango

ZONE_ID=$(aws route53 create-hosted-zone \
  --name rango.com.br \
  --caller-reference "rango-$(date +%s)" \
  --hosted-zone-config Comment="Zona publica do Rango" \
  --query "HostedZone.Id" --output text)
ZONE_ID=${ZONE_ID##*/}

aws route53 get-hosted-zone --id "$ZONE_ID" \
  --query "DelegationSet.NameServers" --output text
```

```text
ns-1234.awsdns-26.org  ns-567.awsdns-06.net  ns-1890.awsdns-44.co.uk  ns-89.awsdns-11.com
```

O ID volta no formato `/hostedzone/Z0123456789ABCDEFGHIJ`, e o `${ZONE_ID##*/}` corta tudo até a última barra. O `--caller-reference` precisa ser único a cada chamada: ele impede que uma retentativa da CLI crie duas zonas iguais. É o `Idempotency-Key` do capítulo 5, do lado da AWS.

A zona nasce com dois registros: o SOA e o NS com os quatro servidores. Os seus quatro nomes vão ser outros. Copie-os para o painel do Registro.br, na tela de servidores DNS do domínio. O Registro.br costuma conferir se os servidores informados respondem pela zona antes de aceitar a troca, e como a zona já existe no Route 53, a conferência passa.

Teste direto num servidor do `.br`, que mostra a delegação sem passar por nenhum cache:

```bash
dig @a.dns.br rango.com.br NS +norec
```

```text
;; AUTHORITY SECTION:
rango.com.br.		3600	IN	NS	ns-1234.awsdns-26.org.
rango.com.br.		3600	IN	NS	ns-567.awsdns-06.net.
...
```

Quando os quatro nomes da AWS aparecerem, a hierarquia já manda as perguntas para o Route 53. Os resolvers que guardaram a delegação antiga só vão perceber quando o TTL deles vencer, o fenômeno que o capítulo 2 explicou como "propagação".

### O certificado

Peça o certificado em `us-east-1`, com os três nomes:

```bash
CERT_ARN=$(aws acm request-certificate \
  --region us-east-1 \
  --domain-name rango.com.br \
  --subject-alternative-names www.rango.com.br api.rango.com.br \
  --validation-method DNS \
  --tags Key=Projeto,Value=rango \
  --query CertificateArn --output text)
```

Os três nomes viram SANs do mesmo certificado, com chave RSA 2048, o padrão do ACM.

Espere uns dez segundos e crie os registros de validação. Uma função pequena evita repetir o JSON de mudança do Route 53 a cada registro:

```bash
upsert() {
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":$1}]}" \
    --query "ChangeInfo.Status" --output text
}

aws acm describe-certificate --certificate-arn "$CERT_ARN" \
  --query "Certificate.DomainValidationOptions[].ResourceRecord.[Name,Value]" \
  --output text | sort -u |
while read -r NOME VALOR; do
  upsert "{\"Name\":\"$NOME\",\"Type\":\"CNAME\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$VALOR\"}]}"
done

aws acm wait certificate-validated --certificate-arn "$CERT_ARN"
```

O `UPSERT` cria o registro ou o substitui se já existir, e torna o comando seguro para rodar de novo. Cada chamada responde `PENDING` e, segundos depois, a mudança está em todos os servidores do Route 53. O `wait` consulta o ACM a cada minuto até o status virar `ISSUED`, o que costuma levar poucos minutos depois que a delegação valeu. Se ele estourar o tempo, confira o `dig` da seção anterior: o ACM pergunta pela internet, e sem delegação ele não encontra os registros.

Não apague esses três CNAMEs nunca. Eles são a autorização permanente para as renovações.

### A API de volta, com configuração nova

Recrie o banco e o cache com os comandos de "Banco e cache de volta", do capítulo 13, trocando o snapshot por `rango-db-final-cap13`. Recupere também as variáveis `VPC_ID`, `PUB_A`, `PUB_B`, `PRIV_A`, `PRIV_B`, `SG_WEB` e `SG_ALB` com as funções `id_subnet` e `id_sg` de lá.

Existe um problema escondido aqui. A AMI carrega o `/etc/rango/api.env` do dia em que foi criada, com o endpoint do cache daquele dia. O cache serverless ganha endpoint novo a cada criação, e as instâncias novas tentariam falar com um cache que não existe mais. E o `CORS_ORIGINS` ainda aponta para `http://localhost:5173`, então o React em `https://rango.com.br` seria barrado pelo navegador.

Em vez de gerar outra AMI, o remendo é um user data curto numa versão nova do Launch Template, que ajusta as duas linhas no primeiro boot. Nenhum dos valores é segredo:

```bash
CACHE_HOST=$(aws elasticache describe-serverless-caches \
  --serverless-cache-name rango-cache \
  --query "ServerlessCaches[0].Endpoint.Address" --output text)

cat > infra/asg/user-data-config.sh <<EOF
#!/bin/bash
set -euo pipefail
sed -i \\
  -e 's|^REDIS_URL=.*|REDIS_URL=rediss://$CACHE_HOST:6379|' \\
  -e 's|^CORS_ORIGINS=.*|CORS_ORIGINS=https://rango.com.br,https://www.rango.com.br|' \\
  /etc/rango/api.env
systemctl restart rango-api rango-worker@restaurante rango-worker@email
EOF

aws ec2 create-launch-template-version \
  --launch-template-name rango-api \
  --source-version 1 \
  --version-description "cap. 14: cache novo e CORS do dominio" \
  --launch-template-data "{\"UserData\":\"$(base64 -w0 infra/asg/user-data-config.sh)\"}"

aws ec2 modify-launch-template --launch-template-name rango-api --default-version 2
```

O `--source-version 1` copia a versão anterior e acrescenta o user data. No macOS, troque o `base64 -w0` por `base64 -i`. O `CORS_ORIGINS` aceita uma lista separada por vírgula, porque o `main.py` faz `split(",")` desde o capítulo 3. Como o ASG do capítulo 13 usa `$Default`, as instâncias que ele criar a partir de agora já nascem com a versão 2.

O capítulo 16 troca esse remendo por algo melhor: a instância vai buscar a configuração e a senha no Parameter Store a cada boot, e a AMI deixa de carregar o `api.env`.

Agora recrie o target group, o ALB e o ASG com os comandos do capítulo 13, com uma diferença: pule o `create-listener` da porta 80. O ALB ganha dois listeners novos. Antes, abra a porta 443 no grupo do balanceador:

```bash
aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0

aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
  --protocol HTTPS --port 443 \
  --certificates CertificateArn="$CERT_ARN" \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN"

aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}'
```

O listener HTTPS termina o TLS no ALB, como o Nginx do capítulo 3, e repassa às instâncias em HTTP pela rede privada. A *security policy* escolhida aceita só TLS 1.3 e 1.2. A porta 80 responde com um `301` para o HTTPS, sem incomodar as instâncias.

Com o ASG de volta, recrie também as ações `especial-tv-inicio` e `especial-tv-fim`, com o cálculo do próximo sábado de "Agendado para sábado", no capítulo 13. O `--force-delete` de lá levou as duas junto com o grupo.

### api.rango.com.br

O nome da API é um alias para o ALB. O alias precisa do ID da hosted zone interna que a AWS usa para os load balancers da região, e o próprio ALB informa esse valor:

```bash
read -r ALB_DNS ALB_ZONE <<< "$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].[DNSName,CanonicalHostedZoneId]" --output text)"

upsert "{\"Name\":\"api.rango.com.br\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"$ALB_ZONE\",\"DNSName\":\"$ALB_DNS\",\"EvaluateTargetHealth\":true}}"
```

Repare que não há TTL: no alias, quem decide é o recurso de destino. Teste:

```bash
dig +short api.rango.com.br
curl -sI http://api.rango.com.br/health | head -3
curl -s https://api.rango.com.br/restaurantes
```

```text
203.0.113.81
198.51.100.140

HTTP/1.1 301 Moved Permanently
Server: awselb/2.0
Location: https://api.rango.com.br:443/health

[{"id":"cantina-da-nona","nome":"Cantina da Nona","taxa_entrega":6.9,"taxa_entrega_fmt":"R$ 6,90"},...]
```

Dois IPs, um por nó do ALB. O `http://` foi redirecionado pelo próprio balanceador, e o `https://` respondeu com o certificado do ACM. Confira a cadeia com o `openssl` do capítulo 2:

```bash
openssl s_client -connect api.rango.com.br:443 -servername api.rango.com.br </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -enddate
```

```text
subject=CN=rango.com.br
issuer=C=US, O=Amazon, CN=Amazon RSA 2048 M02
notAfter=May  1 23:59:59 2027 GMT
```

O emissor é uma CA intermediária da Amazon (o nome exato pode variar), e o vencimento fica a 198 dias de hoje.

### O React num bucket privado

O front precisa saber onde a API mora. O Vite lê variáveis de arquivos `.env` por modo, e o `npm run build` roda no modo `production`. Crie `frontend/.env.production`:

```bash
VITE_API_URL=https://api.rango.com.br
```

Esse arquivo pode ir para o git, porque toda variável `VITE_` acaba dentro do bundle, legível no DevTools: segredo nenhum entra aqui. Ele tem prioridade sobre o `.env.local` só no build, e o desenvolvimento continua apontando para o Compose.

Crie o bucket. Buckets novos já nascem com Block Public Access ligado e com o Object Ownership em `BucketOwnerEnforced`, que o OAC exige:

```bash
CONTA=$(aws sts get-caller-identity --query Account --output text)
FRONT=rango-front-$CONTA

aws s3api create-bucket --bucket "$FRONT" --region us-east-1
aws s3api put-bucket-tagging --bucket "$FRONT" \
  --tagging 'TagSet=[{Key=Projeto,Value=rango}]'
```

Gere o build e envie. A ordem e os cabeçalhos importam:

```bash
cd frontend
npm ci
npm run build

aws s3 sync dist/ "s3://$FRONT/" \
  --exclude index.html \
  --cache-control "public, max-age=31536000, immutable"

aws s3 cp dist/index.html "s3://$FRONT/index.html" \
  --cache-control "no-cache"
cd ..
```

Os arquivos de `assets/` têm o hash no nome, como `index-BxQ3k9aZ.js`. Se o conteúdo muda, o nome muda, e por isso eles podem ficar um ano em qualquer cache. O `index.html` tem sempre o mesmo nome e aponta para os hashes da versão atual, então ele vai com `no-cache`: o navegador pode guardá-lo, mas precisa perguntar se mudou antes de usar. É a regra de `Cache-Control` do capítulo 2.

Os assets sobem primeiro. Se o `index.html` novo chegasse antes, um usuário poderia receber uma página apontando para um JavaScript que ainda não existe no bucket. E o `sync` vai sem `--delete` de propósito: os arquivos da versão anterior ficam no bucket, e quem está com a aba aberta desde ontem continua conseguindo carregar os pedaços da versão antiga. A seção de armadilhas mostra o que acontece sem isso.

### A distribuição

Crie o OAC. Ele é só uma configuração de assinatura, reaproveitável por várias distribuições:

```bash
OAC_ID=$(aws cloudfront create-origin-access-control \
  --origin-access-control-config \
    Name=rango-front-oac,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3 \
  --query "OriginAccessControl.Id" --output text)
```

A configuração da distribuição é um JSON grande. Salve como `infra/cloudfront/rango-front.json`, gerado a partir das variáveis:

```bash
mkdir -p infra/cloudfront
cat > infra/cloudfront/rango-front.json <<EOF
{
  "CallerReference": "rango-front-$(date +%s)",
  "Comment": "Front do Rango",
  "Enabled": true,
  "Aliases": {"Quantity": 2, "Items": ["rango.com.br", "www.rango.com.br"]},
  "DefaultRootObject": "index.html",
  "Origins": {"Quantity": 1, "Items": [{
    "Id": "s3-front",
    "DomainName": "$FRONT.s3.us-east-1.amazonaws.com",
    "S3OriginConfig": {"OriginAccessIdentity": ""},
    "OriginAccessControlId": "$OAC_ID"
  }]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-front",
    "ViewerProtocolPolicy": "redirect-to-https",
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "Compress": true,
    "AllowedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"],
      "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}}
  },
  "CustomErrorResponses": {"Quantity": 2, "Items": [
    {"ErrorCode": 403, "ResponsePagePath": "/index.html", "ResponseCode": "200", "ErrorCachingMinTTL": 10},
    {"ErrorCode": 404, "ResponsePagePath": "/index.html", "ResponseCode": "200", "ErrorCachingMinTTL": 10}
  ]},
  "ViewerCertificate": {
    "ACMCertificateArn": "$CERT_ARN",
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021"
  },
  "HttpVersion": "http2and3",
  "IsIPV6Enabled": true,
  "PriceClass": "PriceClass_All"
}
EOF

read -r DIST_ID DIST_DNS <<< "$(aws cloudfront create-distribution \
  --distribution-config file://infra/cloudfront/rango-front.json \
  --query "Distribution.[Id,DomainName]" --output text)"
echo "$DIST_ID $DIST_DNS"
```

```text
E1ABCDEF2GHIJK d1a2b3c4d5e6f7.cloudfront.net
```

Vale passar pelas linhas menos óbvias. O `S3OriginConfig` com `OriginAccessIdentity` vazio é obrigatório na API mesmo quando você usa OAC, porque o campo é do mecanismo antigo. O `CachePolicyId` é o da política gerenciada `CachingOptimized`, que respeita o `Cache-Control` do objeto dentro de limites de 1 segundo a 1 ano e não inclui cookies nem query strings na chave de cache. O `sni-only` usa o SNI do capítulo 2 para escolher o certificado. O `PriceClass_All` inclui as bordas da América do Sul, e a seção de armadilhas explica por que isso pesa para o Rangô.

O `CustomErrorResponses` é o equivalente do `try_files` do Nginx do capítulo 3. Uma SPA tem rotas que só existem no React: quando o Rangô ganhar o React Router, um link direto para `https://rango.com.br/pedidos/6f1c2a9e` vai pedir ao bucket um objeto chamado `pedidos/6f1c2a9e`, que não existe. O OAC só libera `s3:GetObject`, sem `s3:ListBucket`, e nessas condições o S3 responde `403` para uma chave inexistente, para não revelar o que existe ou não no bucket. Sem o mapeamento, o usuário veria isto:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
```

Com o mapeamento, o CloudFront troca o `403` e o `404` pelo `index.html` com status `200`, e o React lê a URL e desenha a tela certa.

Agora a bucket policy, que libera a leitura só para essa distribuição. Salve como `infra/s3/rango-front-policy.json`:

```bash
cat > infra/s3/rango-front-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SoADistribuicaoDoRango",
      "Effect": "Allow",
      "Principal": {"Service": "cloudfront.amazonaws.com"},
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$FRONT/*",
      "Condition": {
        "StringEquals": {"AWS:SourceArn": "arn:aws:cloudfront::$CONTA:distribution/$DIST_ID"}
      }
    }
  ]
}
EOF

aws s3api put-bucket-policy --bucket "$FRONT" \
  --policy file://infra/s3/rango-front-policy.json

aws cloudfront wait distribution-deployed --id "$DIST_ID"
```

O Block Public Access aceita essa policy, porque o principal é um serviço com condição sobre um ARN específico. O ARN da distribuição não tem região. O `wait` leva alguns minutos, até a configuração chegar a todas as bordas.

### O apex, e um erro de propósito

Falta apontar `rango.com.br` para a distribuição. O reflexo de quem conhece DNS é criar um CNAME. Veja o que o Route 53 diz:

```bash
upsert "{\"Name\":\"rango.com.br\",\"Type\":\"CNAME\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$DIST_DNS\"}]}"
```

```text
An error occurred (InvalidChangeBatch) when calling the ChangeResourceRecordSets operation:
[RRSet of type CNAME with DNS name rango.com.br. is not permitted at apex in zone rango.com.br.]
```

É a regra do capítulo 2, aplicada pelo próprio Route 53. Use alias, em A e em AAAA, já que a distribuição tem IPv6 ligado. O `HostedZoneId` de um alias para CloudFront é sempre o mesmo, `Z2FDTNDATAQYW2`, em qualquer conta:

```bash
for NOME in rango.com.br www.rango.com.br; do
  for TIPO in A AAAA; do
    upsert "{\"Name\":\"$NOME\",\"Type\":\"$TIPO\",\"AliasTarget\":{\"HostedZoneId\":\"Z2FDTNDATAQYW2\",\"DNSName\":\"$DIST_DNS\",\"EvaluateTargetHealth\":false}}"
  done
done
```

O `www` poderia ser um CNAME comum, porque não fica no apex. Com alias, as consultas a ele também saem de graça.

Teste o caminho todo. Primeiro o `index.html`, depois o mesmo arquivo de assets duas vezes (troque pelo nome que o seu build gerou):

```bash
curl -sI https://rango.com.br/ | grep -iE "^(http|cache-control|x-cache|x-amz-cf-pop)"
curl -sI https://rango.com.br/assets/index-BxQ3k9aZ.js | grep -iE "^(x-cache|x-amz-cf-pop)"
curl -sI https://rango.com.br/assets/index-BxQ3k9aZ.js | grep -iE "^(x-cache|x-amz-cf-pop)"
```

```text
HTTP/2 200
cache-control: no-cache
x-cache: Miss from cloudfront
x-amz-cf-pop: GRU3-P2

x-cache: Miss from cloudfront
x-amz-cf-pop: GRU3-P2

x-cache: Hit from cloudfront
x-amz-cf-pop: GRU3-P2
```

O `x-amz-cf-pop` mostra a borda que atendeu, pelo código do aeroporto: `GRU` é Guarulhos, em São Paulo. Do Recife, você pode ver outra. O primeiro pedido do JavaScript foi um *miss* e buscou no bucket da Virgínia; o segundo saiu do cache da borda. Só o primeiro visitante de cada borda paga a viagem até `us-east-1`.

Abra `https://rango.com.br` no navegador. O cadeado aparece, a lista de restaurantes vem de `https://api.rango.com.br`, e o console do DevTools não mostra erro de CORS, porque o `api.env` das instâncias já aceita a origem nova.

Teste também o endereço direto do bucket, o que precisa falhar:

```bash
curl -s -o /dev/null -w "%{http_code}\n" "https://$FRONT.s3.us-east-1.amazonaws.com/index.html"
```

```text
403
```

Num deploy futuro do front, o `index.html` com `no-cache` já faz o navegador perguntar pela versão nova, e a política `CachingOptimized` só o guarda na borda por instantes. Se você precisar forçar uma borda a esquecer algo, existe a invalidação, que remove caminhos do cache em todas as bordas:

```bash
aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/index.html"
```

Os primeiros 1.000 caminhos invalidados por mês são gratuitos. O capítulo 18 coloca esse passo no pipeline.

### As fotos e o domínio novo

O capítulo 11 deixou o CORS do bucket de fotos aceitando só `https://rango.test:5173`, e o upload direto do navegador agora parte de `https://rango.com.br`. Atualize `infra/s3/rango-fotos-cors.json`:

```json
{
  "CORSRules": [
    {
      "AllowedOrigins": [
        "https://rango.test:5173",
        "https://rango.com.br",
        "https://www.rango.com.br"
      ],
      "AllowedMethods": ["PUT"],
      "AllowedHeaders": ["content-type"],
      "MaxAgeSeconds": 3000
    }
  ]
}
```

```bash
aws s3api put-bucket-cors --bucket "rango-fotos-pratos-$CONTA" \
  --cors-configuration file://infra/s3/rango-fotos-cors.json
```

As fotos continuam sendo exibidas por presigned URLs de leitura, direto do S3. Servi-las pelo CloudFront exigiria trocar essas URLs por URLs assinadas do CloudFront, e fica para quando o volume justificar.

### Um vigia do lado de fora

O ALB e o ASG cuidam das instâncias, mas não sabem se o Rangô está acessível para quem está fora da AWS. Um health check do Route 53 testa o mesmo caminho que o cliente:

```bash
HC_ID=$(aws route53 create-health-check \
  --caller-reference "rango-api-$(date +%s)" \
  --health-check-config 'Type=HTTPS,FullyQualifiedDomainName=api.rango.com.br,Port=443,ResourcePath=/health,RequestInterval=30,FailureThreshold=3' \
  --query "HealthCheck.Id" --output text)

aws route53 change-tags-for-resource --resource-type healthcheck \
  --resource-id "$HC_ID" --add-tags Key=Name,Value=rango-api Key=Projeto,Value=rango
```

Depois de um ou dois minutos:

```bash
aws route53 get-health-check-status --health-check-id "$HC_ID" \
  --query "HealthCheckObservations[0:3].[Region,StatusReport.Status]" --output text
```

```text
us-east-1	Success: HTTP Status Code 200, OK
sa-east-1	Success: HTTP Status Code 200, OK
eu-west-1	Success: HTTP Status Code 200, OK
```

Verificadores em São Paulo, na Irlanda e na Virgínia veem o `/health` responder. O check publica uma métrica no CloudWatch, que aceita um alarme como qualquer outra; o capítulo 22 mostra como montar alarmes. Numa arquitetura com duas regiões, é este check que a política de failover consulta.

Um health check com HTTPS para endpoint na AWS custa US$ 1,00 por mês, mas a página de preços informa que até 50 health checks de endpoints da AWS por conta não são cobrados (referência, outubro de 2026).

### Sábado, 21h

Na quinta à noite, a produtora recebe a resposta: `rango.com.br`. No sábado, às 20h30, a ação agendada sobe o mínimo para 4, e as duas instâncias novas já estão saudáveis no target group quando o programa começa. Às 21h12, a Cantina da Nona aparece na tela com o endereço embaixo. Em três minutos, o ALB passa de 900 para 7.600 requisições por minuto, e a target tracking leva o grupo ao máximo de 6. O pico fica em 7.800 por minuto, umas 1.300 por instância, abaixo das 1.400 que cada uma aguenta pela conta do capítulo 13. O front quase não pesa nessa conta: o CloudFront entrega o `index.html` e o bundle pela borda de São Paulo, com 97% de acerto no cache. Até a meia-noite, são 1.140 pedidos, sem nenhum `502` no ALB e sem nenhum `too many clients` no banco. À 0h30, a ação `especial-tv-fim` devolve o mínimo a 2, e a política remove o excesso ao longo da madrugada.

### Desmontar

No domingo de manhã, com o especial encerrado, o que cobra por hora volta a ser desligado. Se você está acompanhando sem um programa de TV marcado, não precisa esperar o sábado: desmonte agora, e o `--force-delete` leva as ações agendadas junto com o grupo. Comece pelo health check e pelo registro da API, que apontariam para um ALB inexistente. Para apagar um registro, o Route 53 exige o registro exato, igual ao que foi criado:

```bash
aws route53 delete-health-check --health-check-id "$HC_ID"

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":{\"Name\":\"api.rango.com.br\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"$ALB_ZONE\",\"DNSName\":\"$ALB_DNS\",\"EvaluateTargetHealth\":true}}}]}"
```

Depois, a mesma sequência do capítulo 13, com o snapshot novo:

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
  --final-db-snapshot-identifier rango-db-final-cap14
aws rds wait db-instance-deleted --db-instance-identifier rango-db
aws rds delete-db-snapshot --db-snapshot-identifier rango-db-final-cap13
```

Ficam a hosted zone (US$ 0,50 por mês), o certificado, o bucket `rango-front-<conta>`, o OAC e a distribuição, que no pay-as-you-go não cobra nada parada. O site `https://rango.com.br` continua carregando, só que a lista de restaurantes vai falhar por falta de API. A versão 2 do Launch Template também fica, com um endpoint de cache que já não existe dentro do user data. O capítulo 15 reconstrói tudo isso de outro jeito.

## Armadilhas e casos reais

> **Armadilha:** Certificado na região errada. Você pede o certificado em `sa-east-1`, porque o ALB está lá, e tenta usá-lo no CloudFront. Ele nem aparece na lista do console, e pela CLI a criação falha com `InvalidViewerCertificate`. Certificados do ACM não podem ser movidos entre regiões: peça outro em `us-east-1`. Com o certificado certo, o mesmo erro aparece quando um nome alternativo da distribuição não está entre os SANs.

> **Armadilha:** Hosted zone recriada, delegação antiga. Ao apagar e recriar uma hosted zone, a AWS atribui outros quatro servidores de nome. O registrador continua apontando para os antigos, que agora não respondem pelo seu domínio, e o site some para quem não tiver a resposta em cache. Sempre que recriar a zona, atualize o Registro.br. O capítulo 15 traz a zona para o código sem apagá-la.

> **Armadilha:** Registro de validação apagado. Alguém faz uma "limpeza" na zona e remove aqueles CNAMEs de nome estranho. Nada acontece por meses. Quando o ACM tenta renovar, a validação falha, e ele avisa por e-mail e pelo AWS Health Dashboard. Se ninguém olhar, o certificado vence. Com validade de 198 dias, a chance de alguém esquecer o que aqueles registros fazem entre uma renovação e outra só aumenta.

> **Armadilha:** Domínio preso em outra distribuição. Um nome alternativo só pode estar em uma distribuição de cada vez. Se você criar uma segunda distribuição com `rango.com.br`, a operação falha com `CNAMEAlreadyExists`. Isso vai aparecer no capítulo 15, quando o código tentar criar a distribuição que hoje existe só pelo console: a antiga precisa liberar o nome primeiro.

> **Armadilha:** Price class barata demais. O `PriceClass_100` custa menos por GB porque usa só bordas da América do Norte, da Europa e de Israel. O `PriceClass_200` acrescenta Ásia, Oriente Médio e África. Nenhum dos dois inclui a América do Sul. Com eles, a sócia em Recife seria atendida por uma borda nos Estados Unidos, e o ganho de latência desapareceria quase todo. Para um público brasileiro, use `PriceClass_All`.

> **Armadilha:** O mapeamento de erro esconde erros. O `CustomErrorResponses` vale para a distribuição inteira. Se um arquivo de `assets/` sumir do bucket, o CloudFront entrega o `index.html` com status `200` no lugar dele, e o Chrome mostra `Failed to load module script: Expected a JavaScript module script but the server responded with a MIME type of "text/html"`. É o que acontece se você usar `aws s3 sync --delete` num deploy enquanto alguém está com a versão anterior aberta: o navegador pede um pedaço antigo, sob demanda, e recebe HTML. Mantenha os assets antigos por alguns dias e, quando o tráfego crescer, troque o mapeamento por uma CloudFront Function que reescreve para `/index.html` só os caminhos sem extensão.

> **Armadilha:** Registro órfão. Um `cdn.empresa.com.br` aponta para o endpoint de site de um bucket S3 que foi apagado. Como nomes de bucket são globais, qualquer conta da AWS pode criar um bucket com aquele nome e servir conteúdo no seu subdomínio, um ataque chamado *subdomain takeover*. Ao apagar um recurso, apague o registro junto, como fizemos com o `api.rango.com.br`.

> **Na vida real:** Em 6 de dezembro de 2018, milhões de clientes da operadora O2, no Reino Unido, ficaram sem dados móveis por quase um dia inteiro, e a SoftBank, no Japão, teve uma queda de mais de quatro horas. A causa, segundo a análise inicial da Ericsson, que fornecia o software do núcleo das duas redes, foi um certificado vencido embutido em duas versões do software dos nós SGSN-MME. Operadoras em cerca de 11 países foram afetadas. A renovação automática do ACM existe para tirar essa data das mãos das pessoas, desde que o registro de validação continue na zona.

## Resumo

- O Route 53 hospeda a zona do `rango.com.br` (hosted zone pública, US$ 0,50 por mês) com quatro servidores de nome, informados ao Registro.br. Registrador e provedor de DNS são papéis separados.
- O registro alias responde como um A, mas aponta para um recurso da AWS e acompanha os IPs dele. Ele resolve o CNAME proibido no apex, e as consultas a alias para ELB e CloudFront não são cobradas.
- Health checks do Route 53 testam o endpoint de fora, de várias regiões. As políticas de roteamento (simples, ponderada, latência, failover) decidem a resposta.
- O ACM emite certificados públicos gratuitos para ALB e CloudFront e os renova sozinho com validação DNS. Desde fevereiro de 2026, eles saem com 198 dias de validade, e a renovação começa 45 dias antes. Para o CloudFront, o certificado precisa estar em `us-east-1`.
- O CloudFront entrega o front a partir de bordas próximas do usuário. O bucket fica privado, e o OAC assina as requisições da distribuição, com uma bucket policy restrita ao ARN dela.
- SPA no CloudFront: `index.html` com `no-cache`, assets com hash e `max-age` de um ano, `403` e `404` mapeados para o `index.html`, e `PriceClass_All` para ter bordas no Brasil.
- O Rangô tem agora `https://rango.com.br` (CloudFront) e `https://api.rango.com.br` (ALB com listener HTTPS e redirecionamento da porta 80), com um único certificado para os três nomes.

## Arqueologia

Conte os comandos usados para colocar o Rangô no ar desde o capítulo 9: subnets, rotas, Security Groups que dependem uns dos outros, um banco restaurado de um snapshot com nome de capítulo, uma AMI, duas versões de Launch Template, uma distribuição com um JSON de quarenta linhas, registros de DNS com aspas escapadas. Cada recriação "com os comandos do capítulo anterior" trouxe uma surpresa, como o endpoint do cache que mudou.

Agora você precisa de uma homologação idêntica à produção. Qual porta o `rango-endpoints` liberou? Que versão do Launch Template está valendo, e por quê? Ninguém lembra o que foi clicado, e recriar o ambiente virou arqueologia.

No próximo capítulo, o Rangô inteiro vira código Python, com o AWS CDK por cima do AWS CloudFormation. Um `cdk deploy` cria a VPC, o banco, o ALB, o ASG, a distribuição e os registros de DNS, e um `cdk destroy` apaga tudo sem deixar sobra. A partir dele, todo exemplo do livro usa CDK.

## Referências

- Preços do Amazon Route 53 (hosted zones, consultas, alias, health checks): https://aws.amazon.com/route53/pricing/
- Escolha entre registros alias e não alias: https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-choosing-alias-non-alias.html
- Health checks e failover de DNS no Route 53: https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-failover.html
- Exemplos de Route 53 no CloudFormation (hosted zone ID `Z2FDTNDATAQYW2` para CloudFront): https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/quickref-route53.html
- Anúncio da validade padrão de 198 dias no ACM (fevereiro de 2026): https://aws.amazon.com/about-aws/whats-new/2026/02/aws-certificate-manager-updates-default
- Características dos certificados do ACM (validação e renovação): https://docs.aws.amazon.com/acm/latest/userguide/acm-certificate-characteristics.html
- Nomes alternativos e HTTPS no CloudFront (certificado em `us-east-1`): https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cnames-and-https-procedures.html
- Restringir acesso a uma origem S3 com OAC: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
- Políticas de cache gerenciadas do CloudFront: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html
- Planos de preço fixo do CloudFront: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html
- Preços do Amazon CloudFront e price classes: https://aws.amazon.com/cloudfront/pricing/
- Listeners HTTPS do Application Load Balancer: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/create-https-listener.html
- Variáveis de ambiente e modos no Vite: https://vite.dev/guide/env-and-mode
- O que causou as quedas da O2 e da SoftBank (TechCrunch, 7 de dezembro de 2018): https://techcrunch.com/2018/12/07/heres-what-caused-yesterdays-o2-and-softbank-outages
- Ericsson pede desculpas pela queda da O2 (Computing): https://www.computing.co.uk/news/3067847/ericsson-apologises-for-o2-network-outage
