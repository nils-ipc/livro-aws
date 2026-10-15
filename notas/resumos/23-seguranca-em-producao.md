# Resumo 23 — Segurança em produção

## Conceitos explicados (não reexplicar depois)
- CloudTrail: `git log` da conta; gerenciamento grátis, Event History 90 d por região, IAM em us-east-1; dados/Insights pagos; trail = 1ª cópia grátis (só S3); Lake citado; `lookup-events` + jq; validação de integridade (digest, `validate-logs`)
- WAF: middleware antes do app; web ACL, regras por prioridade, Allow/Block/Count/CAPTCHA, managed rule groups, WCU 1.500; regra de taxa + `scope_down_statement`; REGIONAL vs CLOUDFRONT (só us-east-1); US$ 5 ACL + 1/regra/grupo + 0,60/M (out/2026); Bot Control/Fraud Control citados
- Shield Standard grátis; Advanced US$ 3.000/mês, 1 ano
- contas = fronteira (bancos separados vs prefixo); OUs; conta de gerenciamento vazia
- SCP: teto, nunca concede; all features; não afeta conta de gerenciamento nem service-linked roles; afeta root membro; FullAWSAccess; desabilitar perde anexos; testar em OU; erro `explicit deny in a service control policy`
- root centralizado (`enable-organizations-root-credentials-management`, `-root-sessions`)
- GuardDuty: CloudTrail + Flow Logs + DNS; findings (InstanceCredentialExfiltration, MaliciousIPCaller, BitcoinTool, RootCredentialUsage); 30 d por conta/região; admin delegado; sample findings
- Config (histórico, rules); Security Hub novo (GA 2/dez/2025), antigo = CSPM; Essentials por resource unit (exemplo US$ 3,75)
- AWS Backup: planos, cofres, cópia entre contas, Vault Lock compliance
- resposta a incidente: confirmar, conter (revoke sessions, SCP emergência, IP set), preservar, erradicar, postmortem

## Estado do Rangô ao fim
- org: OUs `Seguranca` (`rango-seguranca` 210987654321), `Cargas` (`rango-homologacao` 345678901234, `rango-producao` 456789012345); `rango-estudos` só billing/Identity Center
- Rangô migrado p/ `rango-producao` (bootstrap exec role restrita, zona/cert novos, snapshot via CMK, fotos sync); profiles `rango-producao-admin`, `rango-seguranca-admin`
- devs: PowerUser em homologação, `SomenteLeitura` (ViewOnlyAccess) em produção
- SCPs `rango-base` (OU Cargas: auditoria + regiões) e `rango-producao` (Delete só `cdk-hnb659fds-cfn-exec-role-*`); repo `organizacao/scp-*.json`
- trail `rango-organizacao` → bucket `rango-trilha-<conta>` (stack `RangoSeguranca`); GuardDuty us-east-1 + sa-east-1; regra `AchadosGraves` (≥7) → `rango-seguranca-alertas`; Security Hub no console
- `RangoProducao`: `FirewallApi` (LimiteLogin 20/300 s em `/painel/entrar` + 3 grupos em Count) no ALB, `FirewallFront` no CloudFront; `PlanoBackup` 6h UTC, 35 d, cópia 90 d (`cofre_seguranca_arn`)

## Casos reais e exemplos usados (não repetir)
- segunda 16/nov/2026: 41 mil 401, 6 IPs 203.0.113.0/24; Diego (script `-sms$`, 10h02 UTC)

## Promessas feitas
- ponte: fatura de dezembro (4/jan), 1º mês inteiro nas contas novas maior que faturamento; Bruno "isso é normal?"; endpoints, fim dos trials, EBS 100 GiB esquecido → Cost Explorer, budgets, tags, NAT, saída, Savings Plans, Spot, Well-Architected, revisão final (cap. 24)
