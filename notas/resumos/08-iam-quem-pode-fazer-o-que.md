# Resumo 08 — IAM: quem pode fazer o quê

## Conceitos explicados (não reexplicar depois)
- autenticação (assinatura) vs autorização (IAM); analogia decorator `@requer_permissao`; IAM sem custo
- principal, action (`servico:Operacao`), resource; ARN `arn:aws:servico:regiao:conta:recurso`, campos vazios (IAM global, S3)
- policy JSON: Version 2012-10-17, Statement, Sid, Effect, Action, Resource, Condition; ListBucket no bucket vs Get/PutObject em `bucket/*`
- policy `SoRegioesDoRango`: Deny ec2:* fora de us-east-1/sa-east-1 (`aws:RequestedRegion`)
- avaliação: implicit deny → Allow → Deny explícito vence; identity + resource-based somam (mesma conta); cross-account dois lados; boundary/SCP interseção
- usuário IAM (permanente), grupo (não aninha, não é principal), role (crachá de visitante); trust policy vs permissions policy
- STS; AKIA permanente vs ASIA temporária; sessão 1 h padrão, 15 min a 12 h
- menor privilégio: AWS managed → separar dia a dia/admin → customer managed → last accessed; inline policies
- root: sem limite por policy; lista curta de tarefas só-root; root centralizado (cap. 23)
- Identity Center (ex-AWS SSO): diretório ou IdP externo, permission sets, roles `AWSReservedSSO_`, access portal
- instance profile = envelope da role; `iam:PassRole` escalada; env vars AKIA passam na frente de AWS_PROFILE
- boto3 mesma cadeia de credenciais; código sem chave

## Estado do Rangô ao fim
- app ainda local (Compose)
- Identity Center em us-east-1, Organizations ativado (rango-estudos = conta de gerenciamento, único membro); portal `https://rango.awsapps.com/start`
- grupos `rango-admins` (AdministratorAccess), `rango-devs` (PowerUserAccess + inline SoRegioesDoRango); usuário `dev-rango` com MFA nos dois
- `~/.aws/config`: profiles `rango-dev`, `rango-admin`, sso-session `rango`; `export AWS_PROFILE=rango-dev`
- repo: `iam/rango-ec2-confianca.json` (trust ec2.amazonaws.com)
- role + instance profile `rango-ec2` com `AmazonSSMManagedInstanceCore` (para cap. 9)
- root: MFA 1, access keys 0 (`get-account-summary`); nada pago

## Casos reais e exemplos usados (não repetir)
- Unit 42 dez/2025: quarentena em 10 s, `AWSCompromisedKeyQuarantineV3` não revoga; quirk CloudTrail
- EleKtra-Leak 2023 (474 instâncias, 5 min); Classmethod (PowerUserAccess, ~10 min, Monero, GuardDuty)
- comandos: configure sso, sso login/logout, --use-device-code, simulate-principal-policy, create-instance-profile, AccessDenied CreateRole demonstrado
- cotas: 10 managed policies, 6.144 caracteres, trust 2.048

## Promessas feitas
- ponte: "Precisamos de um computador ligado o tempo todo, com IP público"; cap. 9: primeira EC2 com role `rango-ec2`, Session Manager sem porta 22, Rangô à mão com Uvicorn e Nginx
- bucket policy/fotos `rango-fotos-pratos`: cap. 11; CloudTrail, Organizations, SCPs, root centralizado: cap. 23
