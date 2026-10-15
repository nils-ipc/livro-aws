# Pesquisa 18 — CI/CD na AWS

## Pontos conferidos
- GitHub OIDC → AWS: provider URL `https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`. fonte: https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws
- Trust policy: Principal Federated `arn:aws:iam::<conta>:oidc-provider/token.actions.githubusercontent.com`; Action `sts:AssumeRoleWithWebIdentity`. fonte: mesma URL
- Condition `token.actions.githubusercontent.com:aud` = `sts.amazonaws.com` (StringEquals). fonte: mesma URL
- Condition `token.actions.githubusercontent.com:sub`: AWS recomenda sempre avaliar. fonte: mesma URL
- Formato sub branch: `repo:octo-org/octo-repo:ref:refs/heads/octo-branch`. fonte: mesma URL
- Formato sub environment: `repo:ORG/REPO:environment:NOME`. fonte: mesma URL
- Wildcard `repo:ORG/REPO:*` (StringLike) libera qualquer branch, PR, environment → evitar; preferir valor exato. fonte: mesma URL
- Novo: sub com IDs imutáveis `repo:octo-org@123456/octo-repo@456789:ref:refs/heads/...` p/ repos criados após 15/07/2026 ou com opt-in; não existe em GHES. Conferir antes de citar formato. fonte: mesma URL
- Workflow precisa `permissions: id-token: write` + `contents: read` (checkout). `id-token: write` só permite pedir JWT, não dá acesso a recurso. fonte: mesma URL
- Inputs configure-aws-credentials: `role-to-assume`, `role-session-name`, `aws-region`. fonte: mesma URL
- Doc GitHub não menciona thumbprint no provider. Thumbprint não confirmado como necessário hoje (ver Não confirmado). fonte: mesma URL
- configure-aws-credentials: última release vista v6.2.3 (22/07/2026); 6.x usa Node 24 (runner ≥ v2.327.1). Exemplos antigos com `@v1`/`@v2`/`@v4` estão defasados. fonte: https://github.com/aws-actions/configure-aws-credentials/releases
- Doc GitHub pina action por SHA de commit (`e3dd6a42…`), não por tag → boa prática: pinar SHA. fonte: https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws
- amazon-ecs-deploy-task-definition: usar `@v2`; README cita v2.6.3 (SDK ≥ 3.995.0). Inputs: `task-definition`, `service`, `cluster`, `wait-for-service-stability: true`. fonte: https://github.com/aws-actions/amazon-ecs-deploy-task-definition
- Mesmo README: `wait-max-delay-seconds` (polling fixo, ex. 15; padrão backoff exponencial até 10 min), `max-retries` padrão 3. fonte: mesma URL
- Controller `CODE_DEPLOY`: inputs extras `codedeploy-appspec`, `codedeploy-application`, `codedeploy-deployment-group`. README não cobre blue/green nativo do ECS nem circuit breaker. fonte: mesma URL
- README mostra workflow: configure-aws-credentials → amazon-ecr-login → build/push tag `${{ github.sha }}` → amazon-ecs-render-task-definition → amazon-ecs-deploy-task-definition. Exemplo usa chaves longas (`aws-access-key-id`): NÃO copiar; usar OIDC. Versões `@v1` do exemplo defasadas. fonte: mesma URL
- ECS blue/green nativo (sem CodeDeploy): ECS gerencia dois target groups/listener rules; test traffic antes de produção; rollback rápido enquanto bake time não expira. fonte: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-blue-green.html
- Bake time = período com blue e green rodando juntos após shift de produção. Dobra uso de recursos durante deploy. fonte: mesma URL
- Lifecycle hooks: Lambda ou pause (espera `ContinueServiceDeployment`). Com NLB: +10 min em TEST_TRAFFIC_SHIFT e PRODUCTION_TRAFFIC_SHIFT. fonte: mesma URL
- Estágios: RECONCILE_SERVICE, PRE_SCALE_UP, POST_SCALE_UP, TEST_TRAFFIC_SHIFT, POST_TEST_TRAFFIC_SHIFT, PRE_PRODUCTION_TRAFFIC_SHIFT, PRODUCTION_TRAFFIC_SHIFT, POST_PRODUCTION_TRAFFIC_SHIFT. fonte: https://docs.aws.eu/AmazonECS/latest/APIReference/API_DeploymentLifecycleHook.html
- ECS tem 4 estratégias: rolling (padrão), blue/green, canary, linear. Canary e linear lançados em out/2025, todas as regiões comerciais. fonte: https://aws.amazon.com/about-aws/whats-new/2025/10/amazon-ecs-built-in-linear-canary-deployments
- Linear: step percent 3.0–100.0; step bake time 0–1440 min. Rollback também por circuit breaker e alarmes CloudWatch. fonte: https://docs.aws.eu/AmazonECS/latest/developerguide/deployment-type-linear.html
- CDK no pipeline: `cdk deploy --all --require-approval never`. Pede conta bootstrapped; roles de bootstrap qualifier padrão `hnb659fds` (`cdk-hnb659fds-deploy-role-…`). Role do GitHub pode ter só `sts:AssumeRole` nelas (menor privilégio). Starter kits usam AdministratorAccess: evitar. fonte: https://dev.classmethod.jp/articles/github-actions-oidc-aws-cdk-deploy/
- Hooks/scripts do pipeline fora do CDK (ex. `aws s3 sync`, `create-invalidation`) precisam permissões explícitas na role, senão AccessDenied. fonte: https://dev.to/simonireilly/secure-aws-cdk-deployments-with-github-actions-3jfk

## Preços e limites (us-east-1, out/2026)
- CloudFront invalidação: 1.000 paths/mês grátis, somando todas as distribuições da conta. Wildcard (`/*`) conta 1 path. Tag invalidation entra na mesma cota. fonte: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/PayingForInvalidation.html
- Cada path conta individualmente mesmo em um único request. fonte: mesma URL
- CodePipeline V1: US$ 1,00 por pipeline ativo/mês (ativo = >30 dias e ao menos uma mudança no mês); 1º pipeline V1 grátis no free tier. fonte: https://aws.amazon.com/codepipeline/pricing
- CodePipeline V2: US$ 0,002 por minuto de execução de ação (arredonda p/ cima); free tier 100 min/mês; aprovação manual não cobra. CodeBuild/CodeDeploy/S3 cobrados à parte. fonte: mesma URL

## Não confirmado
- US$ 0,005/path de invalidação após a cota: só fonte de terceiros; não usar como fato.
- Limites de invalidações simultâneas (3.000 paths em andamento / 15 wildcards) e 150 paths/s: fontes divergentes.
- Se thumbprint do OIDC provider ainda é exigido no IAM: não verificado.
- Qual 6.x da configure-aws-credentials introduziu Node 24 (fontes divergem: 6.1.0 ou outra); conferir CHANGELOG.
- Flag `--ci` do `cdk deploy`: comportamento não confirmado em doc oficial.
- Status atual do CodeCommit e do CodeDeploy para ECS (fim de novos clientes?): não pesquisado.
- Se ECS blue/green nativo exige ALB (roadmap antigo diz sim; doc atual cita também NLB, Service Connect, VPC Lattice): usar a doc atual.
