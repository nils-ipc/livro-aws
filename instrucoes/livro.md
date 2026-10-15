# O livro: público, projeto-fio, tamanho e sumário

## Público-alvo

Dev **sênior full stack**, **Python + React**, que **sabe muito pouco de DevOps**.

O que o leitor **já sabe** (não explicar):
- Python (Django/Flask), React, JavaScript/TypeScript.
- HTTP no nível da aplicação, REST, JSON, SQL, git, terminal, variáveis de ambiente.
- Arquitetura de aplicação, testes, debugging.

O que o leitor **não sabe** (explicar do zero, sem condescendência):
- Redes (IP, subnet, CIDR, roteamento, NAT, DNS por dentro, TLS).
- Infraestrutura, servidores, provisionamento, escalabilidade operacional.
- Containers e orquestração, CI/CD, observabilidade, backups, recuperação de desastres, segurança de infraestrutura.
- Qualquer serviço da AWS.

Regra de ouro: tratar o leitor como um colega inteligente que nunca precisou cuidar da infraestrutura. Nada de explicar o que é uma função. Mas também nada de pular um conceito de infraestrutura assumindo que ele já conhece.

Sempre que possível, **ancorar o conceito novo em algo que o leitor já domina** (ex.: Security Group lembra um middleware de autorização, só que na rede; IAM Policy lembra um decorator de permissão; CloudFormation lembra uma migration, só que da infraestrutura inteira).

## Projeto-fio

O livro inteiro acompanha **um único projeto**: o **Rangô**, um app de pedidos de comida com **backend em FastAPI** e **frontend em React**.

- Na **Parte I**, o Rangô serve de exemplo para ilustrar os conceitos, sem AWS ainda.
- Na **Parte II**, ele sai do notebook do leitor e termina em produção na AWS: escalável, seguro, observável e com custo sob controle.
- Cada capítulo evolui o Rangô com o que foi apresentado.
- O estado do projeto ao fim de cada capítulo deve ser coerente com o início do próximo.
- Exemplos isolados são bem-vindos, mas o Rangô é o fio condutor.

## Tamanho

- **24 capítulos**: 6 de fundamentos (Parte I) + 18 de AWS (Parte II).
- Cada capítulo: **3.000 a 5.000 palavras** (contando o texto e excluindo blocos de código).

## Sumário

A ordem é intencional: cada capítulo usa o que foi construído nos anteriores. Não reordenar sem revisar as pontes e as recapitulações.

### Parte I — Fundamentos de DevOps para desenvolvedores

Visão **panorâmica**: apresentar os conceitos, o vocabulário e o porquê de cada coisa, sem aprofundar. Nada de AWS ainda (no máximo citar que existe um serviço para aquilo, sem detalhar). A Parte II retoma e aprofunda cada conceito.

| # | Arquivo | Título | Problema que abre o capítulo | Conteúdo principal |
|---|---------|--------|------------------------------|--------------------|
| 01 | `01-do-notebook-para-o-mundo.md` | Do notebook para o mundo | O Rangô funciona em `localhost:8000`. Como alguém do outro lado do país acessa isso? | Apresentação do livro e do Rangô. O caminho de uma requisição: IP, portas, TCP e UDP, roteamento, NAT, IP público vs privado, subnets e CIDR no básico. |
| 02 | `02-dns-https-e-tls.md` | DNS, HTTPS e TLS | O usuário digita `rango.com.br`. Como isso vira um IP? E por que o navegador diz "não seguro"? | Como o DNS resolve um nome (resolvers, servidores autoritativos, TTL, tipos de registro), HTTP por baixo dos panos, TLS (handshake, certificados, autoridades certificadoras), CDN e cache na borda. |
| 03 | `03-servidores-containers-e-kubernetes.md` | Servidores, containers e Kubernetes | "Na minha máquina funciona." No servidor, não. | Servidor físico vs máquina virtual, o básico de Linux para rodar uma aplicação, processos e serviços, proxy reverso, containers (imagem, registry, isolamento), orquestração e os conceitos principais do Kubernetes (pod, deployment, service). |
| 04 | `04-arquitetura-que-escala.md` | Arquitetura que escala | O Rangô apareceu na TV. Um servidor só não aguenta. | Escala vertical vs horizontal, load balancers (camada 4 vs camada 7, health checks), aplicação stateless, cache, monolito vs microsserviços, serverless como conceito, gargalos clássicos. |
| 05 | `05-filas-eventos-e-sistemas-distribuidos.md` | Filas, eventos e sistemas distribuídos | Confirmar um pedido trava a API esperando e-mail, pagamento e restaurante. | Síncrono vs assíncrono, filas, pub/sub, eventos, entrega "pelo menos uma vez", idempotência, retries e backoff, dead letter queue, consistência eventual, as falácias da computação distribuída. |
| 06 | `06-producao-de-verdade.md` | Produção de verdade | Às 3h da manhã o banco corrompeu. O último backup é de quando? | Backups, réplicas de banco (primária, réplica de leitura, failover), RPO e RTO, disaster recovery, alta disponibilidade, infraestrutura como código, CI/CD, estratégias de deploy (rolling, blue/green, canary), observabilidade (logs, métricas, traces), gestão de segredos, incidentes e postmortems. |

### Parte II — AWS na prática

Cada capítulo **retoma o conceito da Parte I correspondente** com uma referência curta (sem repetir a explicação) e mostra como a AWS implementa aquilo, agora em profundidade.

| # | Arquivo | Título | Problema que abre o capítulo | Conteúdo principal |
|---|---------|--------|------------------------------|--------------------|
| 07 | `07-bem-vindo-a-aws.md` | Bem-vindo à AWS | Já sabemos o que precisa existir. Agora: onde e como? | O que é nuvem, modelo de responsabilidade compartilhada, regiões e zonas de disponibilidade, criar a conta, root user, MFA, **alarme de cobrança** (antes de tudo), console vs CLI, free tier e suas armadilhas. |
| 08 | `08-iam-quem-pode-fazer-o-que.md` | IAM: quem pode fazer o quê | Caso real: chave de acesso publicada no GitHub, e a conta minerando criptomoeda em minutos. | Usuários, grupos, roles, policies (o JSON por dentro), princípio do menor privilégio, IAM Identity Center, configurar a AWS CLI com SSO, por que nunca usar o root. |
| 09 | `09-ec2-seu-primeiro-servidor.md` | EC2: seu primeiro servidor | Precisamos de um computador ligado o tempo todo, com IP público. | Instâncias, tipos e famílias, AMIs, key pairs vs Session Manager, Security Groups (primeiro contato), user data, EBS, deploy manual do Rangô com Uvicorn e Nginx. Sentir o trabalho de fazer tudo à mão. |
| 10 | `10-vpc-a-rede-na-aws.md` | VPC: a rede na AWS | O banco de dados está acessível pela internet inteira. | VPC, CIDR na prática, subnets públicas e privadas, route tables, Internet Gateway, NAT Gateway (e o custo dele), Security Groups vs NACLs, VPC endpoints. |
| 11 | `11-s3-armazenamento-de-objetos.md` | S3: armazenamento de objetos | As fotos dos pratos estão enchendo o disco do servidor. | Buckets, objetos, classes de armazenamento, lifecycle, versionamento, bucket policies, Block Public Access, presigned URLs para upload direto do React. Casos reais de buckets expostos. |
| 12 | `12-rds-banco-de-dados-gerenciado.md` | RDS: banco de dados gerenciado | Postgres na mesma EC2 do app: backup manual, upgrade arriscado, disco cheio de madrugada. | RDS PostgreSQL, Aurora, Multi-AZ, réplicas de leitura, snapshots e point-in-time recovery, parameter groups, conexão a partir da subnet privada. ElastiCache (Redis/Valkey) como cache. |
| 13 | `13-load-balancer-e-auto-scaling.md` | Load Balancer e Auto Scaling | O Rangô voltou a aparecer na TV. Agora vamos aguentar. | ALB, target groups, health checks, Launch Templates, Auto Scaling Groups, políticas de escala, o que muda no app para ser stateless (sessões, uploads). |
| 14 | `14-route-53-cloudfront-e-certificados.md` | Route 53, CloudFront e certificados | O usuário acessa por IP, sem HTTPS, e o React demora para carregar longe da região. | Route 53 (zonas, registros, alias, health checks), ACM (certificados gratuitos), CloudFront, deploy do React como SPA em S3 + CloudFront com OAC. |
| 15 | `15-infraestrutura-como-codigo-com-cdk.md` | Infraestrutura como código com CDK | Ninguém lembra o que foi clicado no console. Recriar o ambiente virou arqueologia. | CloudFormation (stacks, drift, rollback), **AWS CDK em Python**, recriar o Rangô inteiro em código. A partir daqui, todo exemplo usa CDK. |
| 16 | `16-segredos-e-criptografia.md` | Segredos e criptografia | A senha do banco está no `.env`, no repositório e numa conversa do Slack. | Parameter Store, Secrets Manager, rotação automática, KMS (criptografia em repouso, envelope encryption), injetar configuração no app sem hardcode. |
| 17 | `17-containers-com-ecr-ecs-e-fargate.md` | Containers com ECR, ECS e Fargate | Manter EC2 atualizada e configurada é um trabalho que não para. | ECR, ECS (cluster, task definition, service), Fargate, integração com ALB e Secrets Manager. EKS: o que é e quando faz sentido escolher Kubernetes. |
| 18 | `18-ci-cd-na-aws.md` | CI/CD na AWS | O deploy ainda é alguém rodando comandos na sexta-feira às 18h. | GitHub Actions com OIDC (sem chaves de longa duração), build e push para o ECR, deploy no ECS, deploy do front no S3 + invalidação do CloudFront, `cdk deploy` no pipeline, blue/green e rollback. Menção ao CodePipeline. |
| 19 | `19-serverless-com-lambda-e-api-gateway.md` | Serverless com Lambda e API Gateway | Pagar um servidor 24 horas por dia para uma rotina que roda três vezes por dia. | Lambda (modelo de execução, cold start, limites, layers), API Gateway (HTTP API vs REST API), quando serverless vale a pena e quando não. Migrar parte do Rangô. |
| 20 | `20-dynamodb.md` | DynamoDB | O rastreamento de entregas em tempo real está sobrecarregando o Postgres. | Modelo chave-valor, partition key e sort key, desenhar a partir dos padrões de acesso, single-table design, GSIs, capacidade on-demand vs provisionada, TTL, Streams. Quando **não** usar. |
| 21 | `21-sqs-sns-eventbridge-e-step-functions.md` | SQS, SNS, EventBridge e Step Functions | O fluxo do pedido do Rangô ainda é uma cadeia de chamadas síncronas. | SQS (filas, DLQ, visibility timeout), SNS (fan-out), EventBridge (barramento, regras, agendamentos), Step Functions para orquestrar o pedido. Idempotência na prática. |
| 22 | `22-observabilidade-com-cloudwatch.md` | Observabilidade com CloudWatch | "Está lento." Onde? Desde quando? Para quem? | CloudWatch Logs e Logs Insights, métricas, alarmes, dashboards, logs estruturados no FastAPI, X-Ray/OpenTelemetry para tracing distribuído, SLOs na prática. |
| 23 | `23-seguranca-em-producao.md` | Segurança em produção | Um bot está testando senhas em massa, e alguém apagou um recurso. Quem foi? | CloudTrail, GuardDuty, WAF no CloudFront/ALB, Shield, AWS Config, Security Hub, múltiplas contas com Organizations e SCPs, AWS Backup, resposta a incidentes. |
| 24 | `24-custos-e-arquitetura.md` | Custos e arquitetura | A fatura chegou, e ela é maior que o faturamento do Rangô. | Cost Explorer, budgets, tags de custo, os vilões clássicos (NAT, tráfego de saída, recursos esquecidos), Savings Plans e Spot, Well-Architected Framework, revisão final do Rangô e próximos passos do leitor. |
