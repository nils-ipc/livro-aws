# Resumo 15 — Infraestrutura como código com CDK

## Conceitos explicados (não reexplicar depois)
- CloudFormation: template (JSON/YAML) → stack; logical ID vs physical ID; grafo de dependências; change set (atualizar, interrupção, substituir); grátis p/ `AWS::*`; 500 recursos/template, 2.000 stacks/região
- rollback automático; `UPDATE_ROLLBACK_COMPLETE`; criação falha → `ROLLBACK_COMPLETE` (só apagar); `UPDATE_ROLLBACK_FAILED` → `continue-update-rollback`, `--resources-to-skip`
- drift: detecta, não corrige; `detect-stack-drift`, `describe-stack-resource-drifts`, `cdk drift`; deploy sem mudança não reverte drift
- CDK: analogia Django ORM → SQL; gera template, CloudFormation executa; L1 `Cfn*`, L2, L3 patterns (cap. 17)
- CLI em Node (22/24; Node 20 fim 30/10/2026); `aws-cdk-lib` fixada `==`; v1 fim jun/2023
- bootstrap por conta+região, stack `CDKToolkit` (S3+ECR+roles), exec role AdministratorAccess, `--cloudformation-execution-policies`; evitar `--express`
- context `cdk.json`, lookups em `cdk.context.json` (commit); tokens → `Fn::GetAtt` + dependência
- `synth`/`diff`/`deploy`/`destroy`; rename construct = logical ID novo = replace; `cdk refactor`, `cdk import`
- removal_policy SNAPSHOT (banco) vs DESTROY + auto_delete_objects (custom resource Lambda)
- armadilhas: trocar snapshot_identifier = substitui banco; nome fixo bloqueia replace; JSII erro em runtime (mypy/pyright)

## Estado do Rangô ao fim
- repo: `rango-infra/` (app.py, cdk.json c/ `certificado_arn`, `rango_infra/rango_infra_stack.py`, `cdk.context.json`)
- stack `RangoProducao` us-east-1: VPC 10.20.0.0/16, 2 AZs, `nat_gateways=0`, públicas + PRIVATE_ISOLATED, gateway endpoint S3; SGs SgApi/SgCache; RoleApi (SSM + fotos/*); `rango-db` de snapshot (t4g.micro, gp3, máx 100, 7 d, ParametrosPg); CfnServerlessCache `rango-cache`; LaunchTemplate (AMI `rango-api-20261015` lookup, IMDSv2, user data sed REDIS_URL/host DB/CORS via tokens); ASG `Api` 2–6, grace 90, warmup 60, 600 req/min; ALB 443 RECOMMENDED_TLS + redirect; bucket Front; Distribution OAC; A/AAAA apex/www, A api
- deploy 1 falhou CNAMEAlreadyExists → stack apagada, distribuição `E1ABCDEF2GHIJK` e alias antigos apagados
- apagados à mão: LT `rango-api`, bucket `rango-front-<conta>`, OAC, subnet/parameter group, snapshot cap14, role/instance profile `rango-ec2`, `rango-vpc` inteira
- fim: `cdk destroy`; snapshot final nome gerado (achar via describe-db-snapshots); MANTIDOS zona, cert, bucket fotos, AMI, `CDKToolkit`; site fora do ar

## Casos reais e exemplos usados (não repetir)
- homologação p/ Bruno até quinta; ConnectionError cache velho; porta 22 no SG do ALB (drift)

## Promessas feitas
- ponte: AMI tem `api.env` com PGPASSWORD; senha no `.env`, commit, Slack → Parameter Store, Secrets Manager, rotação, KMS, instância busca no boot (cap. 16)
- homologação/config por ambiente: cap. 16; front no pipeline: cap. 18; exec role restrita/multicontas: cap. 23; L3 ECS: cap. 17
