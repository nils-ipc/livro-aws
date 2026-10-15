# Pesquisa 16 — Segredos e criptografia

## Pontos conferidos
- Parameter Store tiers: standard (padrão) e advanced. Escolha por parâmetro. fonte: https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-advanced-parameters.html
- Standard: máx 10.000 parâmetros/conta/região; valor máx 4 KB; sem policies; sem compartilhar entre contas; sem custo adicional. fonte: https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-advanced-parameters.html
- Advanced: máx 100.000 parâmetros; valor máx 8 KB; parameter policies (ex.: expiração) suportadas; compartilhável entre contas; cobrado. fonte: https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-advanced-parameters.html
- Standard → advanced: pode. Advanced → standard: não pode (truncaria 8→4 KB, remove policies, criptografia diferente). Solução: apagar e recriar. fonte: https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-advanced-parameters.html
- Tier padrão da conta/região: Standard, Advanced ou Intelligent-Tiering. Mudar o padrão só afeta parâmetros novos sem tier explícito. fonte: https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-advanced-parameters.html
- Ver tier padrão: `aws ssm get-service-setting --region us-east-1 --setting-id arn:aws:ssm:us-east-1:111122223333:servicesetting/ssm/parameter-store/default-parameter-tier`. fonte: https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-advanced-parameters.html
- Ver tier de um parâmetro: `aws ssm describe-parameters --parameter-filters "Key=Name,Option=Equals,Values=/myapp/dev/log-level" --query "Parameters[0].Tier" --output text`. fonte: https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-advanced-parameters.html
- Parameter Store: tier (armazenamento) ≠ throughput (taxa de requisições). Higher throughput é configuração por conta/região; depois de ativada, cobra por interação de API, em standard e advanced. fonte: https://aws.amazon.com/systems-manager/pricing/
- "Interação de API" = requisição × parâmetro individual. Get de 10 parâmetros = 10 interações. Advanced prorrateado por hora. fonte: https://aws.amazon.com/systems-manager/pricing/
- Secrets Manager: sem taxa separada de rotação; criar nova versão não cobra; chamadas da rotação contam como chamadas de API. fonte: https://aws.amazon.com/secrets-manager/pricing/
- Rotação Secrets Manager: `rate()` em horas ou dias, mínimo 4 horas; fuso UTC; `cron()` para janelas finas. fonte: https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-secretsmanager-rotationschedule-rotationrules.html
- Propriedade `Duration` = janela de rotação; não pode invadir a próxima janela nem o próximo dia UTC. Sem Duration: horas → fecha em 1 h; dias → fecha no fim do dia UTC. fonte: https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-secretsmanager-rotationschedule-rotationrules.html
- `RotateImmediatelyOnUpdate` (CFN) / `rotate_immediately_on_update` (CDK): padrão true. Com false, só roda o passo testSecret (cria e remove versão AWSPENDING). Com `rate()` anterior, rotação agendada antiga ainda pode disparar. fonte: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_secretsmanager/RotationScheduleOptions.html
- KMS rotação automática: só chave simétrica de criptografia; não vale para assimétrica, HMAC, material importado, custom key store. Chaves AWS managed: não dá para ligar/desligar. fonte: https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html
- KMS rotação padrão: 365 dias; `RotationPeriodInDays` customiza (`aws kms enable-key-rotation --key-id ... --rotation-period-in-days N`). fonte: https://docs.aws.amazon.com/cli/latest/reference/kms/enable-key-rotation.html
- KMS rotação sob demanda: até 25 vezes por chave; não altera agenda automática. fonte: https://docs.aws.amazon.com/kms/latest/developerguide/rotating-keys-on-demand.html
- KMS `ScheduleKeyDeletion`: janela 7 a 30 dias, padrão 30; chave fica Pending Deletion (desabilitada); `CancelKeyDeletion` cancela. fonte: https://docs.aws.amazon.com/boto3/latest/reference/services/kms/client/schedule_key_deletion.html
- ECS `secrets[].valueFrom`: ARN completo do segredo ou do parâmetro SSM; parâmetro SSM na mesma região aceita só o nome. Campo JSON: `ARN:json_key::` (versão stage e id vazios = mais recente). Campo JSON no Fargate exige platform version 1.4.0+. fonte: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html (via busca; confirmar na página)
- CDK Python: `ecs.Secret.from_secrets_manager(secret, field=None)`; `ecs.Secret.from_ssm_parameter(parameter)`; `from_secrets_manager_version` fixa versão/stage. Passar em `secrets={...}` do `add_container`/`ContainerDefinition`. fonte: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_ecs/Secret.html
- Execution role da task precisa de `secretsmanager:GetSecretValue` e/ou `ssm:GetParameters`/`ssm:GetParameter` (e `kms:Decrypt` se CMK). fonte: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html (via busca)

## Preços e limites (consulta em out/2026; páginas não mostraram região)
- Secrets Manager: US$0,40/segredo/mês; US$0,05/10.000 chamadas de API (inferido dos exemplos da página; confirmar no Pricing Calculator). fonte: https://aws.amazon.com/secrets-manager/pricing/
- Secrets Manager free tier: página cita plano gratuito por 6 meses após criar a conta e até US$200 em créditos. Não citar "30 dias grátis" sem conferir. fonte: https://aws.amazon.com/secrets-manager/pricing/
- KMS: chave gerenciada pelo cliente US$1/mês (proporcional por hora). Chaves AWS managed: US$0 de armazenamento; requisições cobradas. fonte: https://aws.amazon.com/kms/pricing/
- KMS: US$0,03/10.000 requisições simétricas; free tier 20.000 requisições/mês (todas as regiões; exclui assimétricas e GenerateDataKeyPair). fonte: https://aws.amazon.com/kms/pricing/
- KMS rotação automática: +US$1/mês na 1ª rotação e +US$1/mês na 2ª; depois não cobra mais. fonte: https://aws.amazon.com/kms/pricing/
- KMS multi-region: US$1/mês por chave primária e por réplica. Chave agendada para exclusão: US$0. fonte: https://aws.amazon.com/kms/pricing/
- Parameter Store advanced: cobrado por parâmetro/mês e por interação de API; valor em USD não confirmado (mirror europeu mostrou €0,0493, suspeito). fonte: https://aws.amazon.com/systems-manager/pricing/

## Casos reais
- Toyota T-Connect: subcontratada publicou código no GitHub público em dez/2017 com chave de acesso hardcoded ao servidor de dados. Exposto até 15/09/2022 (quase 5 anos). ~296.019 clientes; só e-mails e números de controle. Toyota trocou chaves em 17/09/2022; sem evidência de acesso de terceiros, mas não descartado. Divulgado em out/2022. fonte: https://blog.gitguardian.com/toyota-accidently-exposed-a-secret-key-publicly-on-github-for-five-years/

## Não confirmado
- Faixa permitida de `RotationPeriodInDays` no KMS (90 a 2560 dias): busca não mostrou. Não usar números; dizer só "padrão 365 dias, configurável".
- Preço em USD do advanced parameter e da higher throughput no Parameter Store.
- Preço de réplica de segredo (replicação multi-região) no Secrets Manager.
- Se os preços da página KMS/Secrets Manager valem para us-east-1 (páginas não informaram região).
- Rotação gerenciada (managed rotation, ex.: segredos de RDS gerenciados pelo RDS) e limites de 2025/2026: não pesquisado.
- Caso Uber 2016 (credenciais AWS no GitHub): busca não retornou. Não usar como fato.
