# Pesquisa 17 — Containers com ECR, ECS e Fargate

Consulta: outubro/2026.

## Pontos conferidos
- ECS blue/green nativo lançado 17/07/2025. Não precisa CodeDeploy. fonte: https://aws.amazon.com/about-aws/whats-new/2025/07/amazon-ecs-built-in-blue-green-deployments/
- Blue/green nativo funciona com ALB, NLB ou Service Connect. fonte: https://aws.amazon.com/about-aws/whats-new/2025/07/amazon-ecs-built-in-blue-green-deployments/
- Blue/green nativo: ECS sobe versão nova ao lado da antiga, valida, troca tráfego, bake time, depois remove tasks antigas. fonte: https://aws.amazon.com/blogs/aws/accelerate-safe-software-releases-with-new-built-in-blue-green-deployments-in-amazon-ecs
- Lifecycle hooks = funções Lambda síncronas. Pontos: pre scale up, post scale up, test traffic shift, production traffic shift, post test traffic shift, post production traffic shift. fonte: https://aws.amazon.com/blogs/containers/extending-deployment-pipelines-with-amazon-ecs-blue-green-deployments-and-lifecycle-hooks
- Rollback automático via alarmes CloudWatch e deployment circuit breaker. fonte: https://aws.amazon.com/blogs/aws/accelerate-safe-software-releases-with-new-built-in-blue-green-deployments-in-amazon-ecs
- ECS Express Mode anunciado 21/11/2025. Sem custo adicional, paga só recursos criados. fonte: https://aws.amazon.com/about-aws/whats-new/2025/11/announcing-amazon-ecs-express-mode/
- Express Mode: entrega imagem, cria cluster, task definition, ALB, auto scaling, domínio Route 53, URL. Até 25 serviços Express compartilham um ALB. Recursos ficam visíveis e editáveis na conta. fonte: https://aws.amazon.com/about-aws/whats-new/2025/11/announcing-amazon-ecs-express-mode/
- Secrets Manager em `secrets` da task definition. Formato exato do `valueFrom`: `arn:aws:secretsmanager:region:account-id:secret:secret-name:json-key:version-stage:version-id`. fonte: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html
- Campos json-key, version-stage, version-id opcionais, mas os `:` finais obrigatórios. Exemplo chave JSON: `...:secret:appauthexample-AbCdEf:username1::`. Padrão sem stage: AWSCURRENT. fonte: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html
- Version-stage e version-id são mutuamente exclusivos. fonte: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html
- Segredo é injetado só no start do container. Rotação não chega a task em execução. Precisa nova task ou "Force new deployment" no service. fonte: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html
- Fargate: segredo completo exige platform version 1.3.0+. Chave JSON ou versão específica exige 1.4.0+ (Linux). fonte: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html
- Injeção de segredo usa task execution role (não task role). Precisa permissão de leitura no segredo. fonte: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html
- Task em subnet privada precisa de interface VPC endpoint do Secrets Manager (ou NAT) para buscar o segredo. fonte: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html
- Variáveis de ambiente ficam visíveis a app, logs e ferramentas de debug do container. fonte: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html
- `valueFrom` também aceita ARN completo de parâmetro do SSM Parameter Store. fonte: https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-ecs-taskdefinition-secret.html
- ECR: tráfego entre ECR e Fargate/EC2/Lambda na mesma região é grátis. Entre regiões cobra preço de transferência de internet. fonte: https://aws.amazon.com/ecr/pricing
- ECR privado: sem franquia grátis de transferência pela internet (500 GB e 5 TB só em repositórios públicos). fonte: https://aws.amazon.com/ecr/pricing

## Preços e limites (us-east-1, outubro/2026)
- Fargate Linux/x86: $0.040478 por vCPU-hora, $0.004446 por GB-hora. fonte: https://aws.amazon.com/fargate/pricing/
- Fargate Linux/ARM (Graviton): $0.032380 por vCPU-hora, $0.003560 por GB-hora (cerca de 20% menor). fonte: https://aws.amazon.com/fargate/pricing/
- Fargate cobra por segundo, mínimo 1 minuto (Linux). Windows: mínimo 5 minutos. fonte: https://aws.amazon.com/fargate/pricing/
- Fargate: 20 GB de storage efêmero grátis por task. Adicional $0.000111 por GB-hora (até 200 GB). fonte: https://aws.amazon.com/fargate/pricing/
- Fargate Spot: até 70% de desconto, só ECS, só Linux (x86 e ARM). Task pode ser interrompida. fonte: https://aws.amazon.com/fargate/pricing/
- Compute Savings Plans cobrem Fargate: até 50% de desconto, compromisso de 1 ou 3 anos. fonte: https://aws.amazon.com/fargate/pricing/
- Fargate cobra do início do download da imagem até a task terminar. fonte: https://aws.amazon.com/eks/pricing/ (texto equivalente para EKS) e https://aws.amazon.com/fargate/pricing/
- ECS em si: sem custo adicional. Paga EC2 ou Fargate. fonte: https://aws.amazon.com/ecs/pricing/
- ECR free tier: 500 MB por mês de storage privado, por 1 ano, para clientes novos. fonte: https://aws.amazon.com/ecr/pricing
- ECR storage: $0.10 por GB-mês (valor visto em fontes de terceiros, conferir na página oficial). fonte: https://aws.amazon.com/ecr/pricing
- EKS: $0.10 por cluster por hora (suporte padrão). fonte: https://aws.amazon.com/eks/pricing/
- EKS extended support: $0.60 por cluster por hora ($0.10 + $0.50). Versão tem 14 meses de suporte padrão e mais 12 de estendido. fonte: https://aws.amazon.com/eks/pricing/
- EKS Provisioned Control Plane (opcional, somado ao cluster): XL $1.65, 2XL $3.40, 4XL $6.90, 8XL $13.90 por hora. fonte: https://aws.amazon.com/eks/pricing/
- EKS Auto Mode: taxa extra por instância sobre o preço EC2. Exemplo c6a.2xlarge: EC2 $0.306/h + $0.03672/h. fonte: https://aws.amazon.com/eks/pricing/
- Conta exemplo (derivada, x86): 0.5 vCPU + 1 GB = 0.5×0.040478 + 1×0.004446 = $0.024685/h, cerca de $18/mês (730 h). Cálculo próprio, não vem da AWS.

## Não confirmado
- Preço Fargate Spot ARM exato: terceiros citam $0.00995229 vCPU-h e $0.0010942 GB-h. Varia com oferta. Não usar como fato.
- Detalhes de tag immutability e exclusões (`immutable with exclusions`) no ECR. Não pesquisado a fundo.
- Sintaxe de `ecs_patterns.ApplicationLoadBalancedFargateService` e `ecs.Secret.from_secrets_manager(secret, field=...)` em CDK Python. Não conferido, validar na documentação do CDK antes de usar.
- Data em que EKS 1.33 saiu do suporte padrão (fonte de terceiro, endoflife.ai). Não usar.
- Preço de ECR Archive tier. Só fonte de terceiro.
