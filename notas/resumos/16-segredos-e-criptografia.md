# Resumo 16 — Segredos e criptografia

## Conceitos explicados (não reexplicar depois)
- configuração vs segredo vs chave criptográfica; Parameter Store / Secrets Manager / KMS
- Parameter Store: hierarquia `/rango/{ambiente}/...`, `GetParametersByPath` ≈ `os.environ` remoto; String/StringList/SecureString; standard (10.000, 4 KB, grátis) vs advanced (100.000, 8 KB, pago, não volta); higher throughput citado
- Secrets Manager: ~US$ 0,40/segredo/mês + US$ 0,05/10k chamadas (out/2026); rotação Lambda ("gerenciador de senhas com cron"); staging labels AWSCURRENT/AWSPENDING/AWSPREVIOUS; `rate()` mín. 4 h, UTC; tabela comparativa; regra: padrão Parameter Store (SecureString p/ segredo sem rotação), exceção Secrets Manager quando precisa de rotação gerenciada
- rotação single-user vs multi-user (`rango_clone`, `GRANT rango TO rango_clone`, anterior válida até rotação seguinte)
- KMS: chave nunca sai do HSM (analogia gerente do banco); Encrypt máx. 4 KB; envelope encryption (GenerateDataKey, Plaintext + CiphertextBlob; analogia cadeado + envelope lacrado)
- chaves AWS managed (`aws/...`, grátis, fixas) vs customer managed (US$ 1/mês, key policy = segunda tranca); rotação 365 d padrão, +US$ 1 nas 2 primeiras, sob demanda 25×; exclusão 7–30 d, PendingDeletion, cancel
- CloudFormation não cria SecureString; `unsafe_plain_text` vaza no template
- instance refresh; `max_instance_lifetime`

## Estado do Rangô ao fim
- `app.py`: `ambiente="producao"`, snapshot do fim do cap. 15
- stack: `kms.Key` `alias/rango-producao-segredos` (rotação, pending 7 d, DESTROY); interface endpoints Ssm + SecretsManager nas privadas; `DatabaseSecret` `rango` (masterarn, CMK) `.attach(db)`; `add_rotation_multi_user` 30 d; 5 `StringParameter` `/rango/producao/{aws_region,cors_origins,database_url (sem usuário),fotos_bucket,redis_url}`; role: GetParametersByPath + `grant_read`; ASG `max_instance_lifetime` 7 d + `add_dependency`; outputs AsgNome, SegredoAppArn
- `rango-infra/user_data/configurar.sh`: monta `/etc/rango/api.env` (PGUSER/PGPASSWORD do segredo), restart units
- `scripts/envelope.py` (boto3 + cryptography AESGCM, didático; produção = AWS Encryption SDK)
- 2ª rotação manual: senha vazada morta; instance refresh
- `cdk destroy`: chave PendingDeletion 7 d; mantidos zona, cert, bucket fotos, AMI `rango-api-20261015` (api.env com senha morta), snapshot novo, CDKToolkit
- código do app inalterado

## Casos reais e exemplos usados (não repetir)
- senha em AMI, Slack de março (Bruno), commit `a12d6c0` (`git log -S`)
- Toyota T-Connect (2017–2022, ~296 mil)
- push protection GitHub, `git filter-repo`

## Promessas feitas
- ponte: AMI envelhece (código antigo, rebuild manual, patches) → ECR, ECS, Fargate; segredo vira campo da task definition (cap. 17)
- CloudTrail/contas separadas/PowerUser lê segredos: cap. 23
