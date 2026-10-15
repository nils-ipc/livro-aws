# Pesquisa 23 — Segurança em produção

## Pontos conferidos
- CloudTrail: eventos de gerenciamento registrados por padrão, sem custo. Event History = últimos 90 dias, console e API lookup-events, por Região. fonte: https://aws.amazon.com/cloudtrail/pricing/
- CloudTrail: 1 cópia dos eventos de gerenciamento em trail para S3 sem custo da CloudTrail; custo do S3 à parte. fonte: https://aws.amazon.com/cloudtrail/pricing/
- CloudTrail: data events, Insights e cópias extras de trail cobrados à parte. fonte: https://aws.amazon.com/cloudtrail/pricing/
- CloudTrail Lake: 30 dias grátis para cliente novo; cobra ingestão, retenção, análise; 2 opções: retenção de 1 ano extensível ou 7 anos. fonte: https://aws.amazon.com/cloudtrail/pricing/
- GuardDuty: 30 dias grátis automáticos no 1º uso, por conta e por Região; cada conta da organização tem o próprio trial. fonte: https://docs.aws.amazon.com/guardduty/latest/ug/guardduty-pricing.html
- GuardDuty: cada protection plan adicional ganha novo trial de 30 dias ao ser habilitado. fonte: https://aws.amazon.com/guardduty/pricing
- GuardDuty: Malware Protection for EBS entra no trial; Malware Protection for S3 não tem trial, tem free tier; on-demand malware scan fora do trial. fonte: https://aws.amazon.com/guardduty/pricing
- GuardDuty: console mostra dias restantes do trial e estimativa de custo diário. fonte: https://docs.aws.amazon.com/guardduty/latest/ug/guardduty-pricing.html
- Security Hub: novo Security Hub em disponibilidade geral em 2 dez 2025 (análise de risco quase em tempo real, enablement unificado, preço simplificado). fonte: https://aws.amazon.com/about-aws/whats-new/2025/12/security-hub-near-real-time-risk-analytics/
- Security Hub: o serviço antigo (agregação de findings, checagens de boas práticas) agora se chama Security Hub CSPM. fonte: https://aws.amazon.com/security-hub/faqs/
- Security Hub: plano Essentials, pay-as-you-go por resource unit/mês, proporcional ao tempo monitorado. Inclui CSPM, regras de automação, Inspector (EC2, ECR, Lambda standard, CIS), Config Recorder service-linked. fonte: https://aws.amazon.com/security-hub/pricing/
- Security Hub: 1 resource unit = 1 instância EC2, ou 18 imagens ECR, ou 12 funções Lambda, ou 125 recursos IAM (users/roles). Demais recursos incluídos. fonte: https://aws.amazon.com/security-hub/pricing/
- Security Hub: trial de 30 dias cobre Essentials; add-ons (threat analytics, Lambda code scanning) e plano Extended fora do trial. fonte: https://aws.amazon.com/security-hub/pricing/
- SCP: só em organização com all features habilitado (não vale só com consolidated billing). fonte: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- SCP: não concede permissão, só limita o máximo. Permissão efetiva = interseção de SCP/RCP com políticas de identidade e de recurso. fonte: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- SCP: NÃO afeta usuários e roles da conta de gerenciamento; afeta só contas membro (inclusive membro designado delegated administrator). fonte: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- SCP: afeta o root user das contas membro; não afeta service-linked roles. fonte: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- SCP: não afeta contas fora da organização que acessam recurso via resource policy. fonte: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- SCP: não remover FullAWSAccess sem substituir; senão todas as ações das contas membro falham. fonte: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- SCP: desabilitar o tipo de política desanexa todas as SCPs; ao reabilitar só volta FullAWSAccess, anexos perdidos. fonte: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- SCP: AWS recomenda testar em uma OU, movendo contas aos poucos, nunca anexar direto na raiz sem teste. fonte: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- Shield Standard: grátis, automático (CloudFront, Route 53, ELB). fonte: https://aws.amazon.com/shield/pricing
- Shield Advanced inclui regra gerenciada WAF de DDoS L7 e cobre até 50 bilhões de requests/mês por payer em recursos protegidos no WAF. fonte: https://aws.amazon.com/shield/pricing
- Config: cobra por configuration items registrados, avaliações de regras ativas e avaliações de conformance packs; S3 e SNS à parte. fonte: https://aws.amazon.com/config/pricing

## Preços e limites (us-east-1 presumido, consulta out/2026)
- WAF: $5.00 por web ACL/mês; $1.00 por regra/mês; $1.00 por rule group (inclusive gerenciado)/mês; $0.60 por milhão de requests. Allow/Block/Count sem custo extra. fonte: https://aws.amazon.com/waf/pricing
- WAF: acima de 1.500 WCU, $0.20 por milhão de requests a cada 500 WCU extras. Body inspection extra: $0.30 por milhão a cada 16 KB além de 16 KB. fonte: https://aws.amazon.com/waf/pricing
- WAF Bot Control: assinatura $10.00/mês por web ACL. Common: $1.00 por milhão após 10 milhões grátis/mês. Targeted: $10.00 por milhão após 1 milhão grátis/mês. fonte: https://aws.amazon.com/waf/pricing
- WAF Fraud Control ATP e Account Creation Fraud Prevention: $10.00/mês por web ACL cada; preço por request em faixas, não confirmado. fonte: https://aws.amazon.com/waf/pricing
- WAF: cobrança do WAF é adicional ao preço do CloudFront/ALB. fonte: https://aws.amazon.com/waf/pricing
- Shield Advanced: $3,000/mês, compromisso de 1 ano, mais taxa de uso por transferência de saída (CloudFront, ELB, EC2, Global Accelerator). Exemplo oficial: +$50 sobre 1.000 GB regionais = $3,050. Cobrado por payer account. fonte: https://aws.amazon.com/shield/pricing
- Security Hub Essentials: exemplo oficial usa $3.75 por resource unit (EC2); valor só de exemplo, confirmar no Pricing Calculator. fonte: https://aws.amazon.com/security-hub/pricing/

## Não confirmado
- Casos reais (ataque de força bruta em massa, recurso apagado): nenhum caso pesquisado; não citar empresa, ano ou número.
- Preço por evento de data events ($0.10 por 100.000) e Insights ($0.35 por 100.000): só fonte secundária (cloudzero, vantage). Não usar como fato.
- Config $0.003 por configuration item: só blog de terceiros. Confirmar em https://aws.amazon.com/config/pricing.
- Shield Response Team exige Business ou Enterprise Support: só fonte secundária.
- Tamanho máximo de SCP e máximo de SCPs por alvo: não lidos (ver orgs_reference_limits).
- AWS Backup (preço, vault lock, cross-account/cross-Region copy): não pesquisado.
- Preços do GuardDuty após o trial: não obtidos.
