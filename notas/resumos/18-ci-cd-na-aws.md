# Resumo 18 — CI/CD na AWS

## Conceitos explicados (não reexplicar depois)
- access key em secrets do GitHub = problema cap. 8; OIDC: JWT por job ("Entrar com Google"), STS `AssumeRoleWithWebIdentity`, ASIA 1 h; diagrama ASCII
- trust policy: `aud` = `sts.amazonaws.com`, `sub` exato (`StringEquals`); tabela sub (ref main, environment, pull_request); curinga `repo:X:*` perigoso; formato novo com IDs (repos após 15/07/2026)
- `id-token: write` só pede JWT
- GitHub environment: required reviewers + deployment branches `main` (sub não diz branch); plano privado varia
- roles bootstrap `cdk-hnb659fds-*`: role do GitHub só `sts:AssumeRole`; risco deslocado (exec role admin)
- passos fora do CDK precisam permissão própria (AccessDenied)
- ECS: rolling, blue/green, canary, linear (out/2025); blue/green: regra teste + produção, troca única, bake time, rollback por alarme, lifecycle hooks (`POST_TEST_TRAFFIC_SHIFT`), role `AmazonECSInfrastructureRolePolicyForLoadBalancers`
- actions ECS render/deploy (`@v2`) = drift se CDK é dono da task definition
- pinar actions por SHA, Dependabot; configure-aws-credentials v6 (Node 24)
- invalidação 1.000 caminhos/mês grátis, `/*` = 1
- CodePipeline V1 US$ 1/mês, V2 US$ 0,002/min (100 min grátis); CodeBuild à parte; CDK Pipelines citado

## Estado do Rangô ao fim
- stack `RangoPipeline` (`pipeline_stack.py`): provedor OIDC GitHub; roles `rango-github-imagem` (sub ref main, pull/push + DescribeImages em `rango-api`), `rango-github-deploy` (sub environment producao; AssumeRole bootstrap, DescribeStacks RangoProducao, ecs:UpdateService + ListServices) — MANTIDA, deploy manual
- `RangoProducao`: API sem pattern: ALB `AlbApi`, listener 443 default 404, redirect 80, TGs `GrupoAzul`/`GrupoVerde`, `RegraTeste` (header `X-Rango-Teste: verde`, prio 10), `RegraProducao` (prio 20); alarme `ErrosApi` (≥10 5xx/min); `TarefaApi` (container `api`); `ServicoApi` BLUE_GREEN, bake 10 min, circuit breaker, ROLLBACK_ON_ALARM; escala CPU 60%; `ApiA` explícito; grants front/invalidação p/ role importada; workers rolling
- `.github/workflows/ci.yaml`: testes → imagem (`ubuntu-24.04-arm`, tag `github.sha`, pula se existe) → deploy (environment producao, concurrency, `cdk deploy RangoRegistro RangoProducao`, front + invalidação `/index.html` só em push); `workflow_dispatch` input `versao` = rollback
- `renovar-tasks.yaml`: seg 9h UTC force-new-deployment
- variável GitHub `AWS_ACCOUNT_ID`; `cdk.context.json` commitado
- fim: `cdk destroy RangoProducao` (snapshot novo), workflows desabilitados (`gh workflow disable`)

## Casos reais e exemplos usados (não repetir)
- taxa Sabor do Sertão R$ 6,90 vs 4,50, aniversário sobrinha, aprovação no celular
- demo coluna `taxa_entrga` → 500, rollback por alarme
- tj-actions/changed-files mar/2025, CVE-2025-30066

## Promessas feitas
- ponte: Bruno quer resumo de vendas às 11h, 15h, 23h; worker 24 h por rotina 3×/dia → Lambda, cold start, limites, API Gateway, quando não compensa (cap. 19)
- taxas/SLOs no alarme: cap. 22; contas separadas/exec role: cap. 23
