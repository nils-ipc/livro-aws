# Pesquisa 07 — Bem-vindo à AWS

## Pontos conferidos
- Free Tier novo p/ contas criadas a partir de 15/jul/2025 (anúncio 16/jul/2025): dois planos, Free plan e Paid plan. fonte: https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/
- Créditos: até US$ 200. US$ 100 no cadastro + até US$ 100 por atividades no widget "Explore AWS". fonte: https://aws.amazon.com/free/faqs/
- Free plan expira em 6 meses após criar conta OU ao esgotar créditos, o que vier primeiro. fonte: https://aws.amazon.com/free/faqs/
- Free plan: só subconjunto de serviços (exclui os que gastariam créditos rápido ou exigem compra de hardware). fonte: https://aws.amazon.com/free/faqs/
- Free plan: sem cobrança, a menos que migre p/ Paid plan. Sem volta de Paid p/ Free. fonte: https://aws.amazon.com/free/faqs/
- Free plan: créditos promocionais (ex.: AWS Activate) não aplicáveis. fonte: https://aws.amazon.com/free/faqs/
- Ao expirar Free plan: conta suspensa, dados retidos 90 dias, upgrade nesse prazo restaura acesso, depois apagada em definitivo. fonte: https://aws.amazon.com/free/faqs/
- Paid plan: acesso a todos os serviços; uso além dos créditos cobrado a preço on-demand. Créditos restantes valem até 12 meses após criação da conta. fonte: https://aws.amazon.com/free/faqs/
- Paid plan: limite mensal de gasto de projeto a partir de US$ 20; avisos a 50%, 75%, 90%; no limite AWS pausa o projeto até o mês seguinte. fonte: https://aws.amazon.com/free/faqs/
- Página de FAQ inconsistente sobre validade dos créditos (6 vs 12 meses). Livro: dizer que a regra exata deve ser conferida no console Billing. fonte: https://aws.amazon.com/free/faqs/
- Free plan: avisos periódicos por e-mail sobre saldo de créditos e fim do plano; API `GetAccountPlanState`. fonte: https://aws.amazon.com/free/faqs/
- Alarme de cobrança CloudWatch: métrica `EstimatedCharges`, namespace Billing, "Total Estimated Charge". fonte: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/monitor_estimated_charges_with_cloudwatch.html
- Dados de cobrança ficam só em US East (N. Virginia) `us-east-1`, representam cobrança mundial. Região do console precisa ser N. Virginia p/ criar alarme. fonte: mesma URL acima
- Antes: habilitar em Billing and Cost Management > Billing Preferences > Alert preferences > Edit > "Receive CloudWatch Billing Alerts" > Save preferences. Depois de habilitar, ~15 min até dados aparecerem; não dá para desabilitar a coleta. fonte: mesma URL acima
- Quem habilita: root ou IAM user com permissão de ver billing. Conta APN (Partner Network): métricas de billing não publicadas. fonte: mesma URL acima
- Alarme dispara só quando cobrança atual excede o limite; não usa projeção. Se já passou do limite ao criar, vai direto a `ALARM`. Valores só em USD. fonte: mesma URL acima
- Config sugerida na doc: Statistic Maximum, Period 6 hours, Static, Greater, Datapoints 1 out of 1, missing data "Treat missing data as missing", notificação via tópico SNS (e-mail). fonte: mesma URL acima
- AWS Budgets: monitorar e notificar é grátis. 2 budgets com ação grátis por mês; demais US$ 0,10/dia cada. Relatório entregue US$ 0,01. fonte: https://aws.amazon.com/aws-cost-management/aws-budgets/pricing
- Root MFA obrigatório em todos os tipos de conta (inclusive contas-membro) desde jun/2025. fonte: https://aws.amazon.com/about-aws/whats-new/2025/06/aws-iam-mfa-root-users-across-all-account-types
- Até 8 dispositivos MFA por root user ou IAM user, de qualquer tipo; basta 1 para entrar. Preferir passkey/security key (FIDO, resistente a phishing) a TOTP. fonte: https://docs.aws.amazon.com/IAM/latest/UserGuide/Using_ManagingMFA.html
- MFA do root só habilita pelo console; não por CLI/API. SMS MFA descontinuado. fonte: https://docs.aws.amazon.com/IAM/latest/UserGuide/Using_ManagingMFA.html
- Infra global: 124 Availability Zones em 39 Regions (página consultada out/2026); planejadas +7 AZs e +2 Regions (Arábia Saudita e Chile). fonte: https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
- Local Zones = extensão de uma Region, compute/storage/banco perto do usuário final. fonte: https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
- São Paulo: `sa-east-1`, lançada 2011, 3 AZs (fonte oficial listava 3; conferir com `aws ec2 describe-availability-zones --region sa-east-1`). fonte: https://www.aws.amazon.com/about-aws/global-infrastructure/regions_az

## Preços e limites (us-east-1 e geral, out/2026)
- IPv4 público: US$ 0,005 por IP por hora (~US$ 44,80/ano por endereço), anexado ou não, desde 1/fev/2024. fonte: https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights
- Free tier de IPv4: 750 h/mês só com EC2 e só em conta sob free tier (12 meses, regra antiga). Em ELB, NAT gateway, Global Accelerator, cobra. BYOIP não cobra. fonte: https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights
- Alarme CloudWatch e SNS: preço não conferido. Não citar valor.

## Não confirmado
- Detalhe por atividade do bônus de US$ 100 (reportagem Neowin diz 5 atividades de US$ 20; páginas AWS dizem só "até US$ 100"). Não usar número por atividade.
- Se contas criadas antes de 15/jul/2025 mantêm o modelo antigo de 12 meses/750 h. Não confirmado; dizer só que regras mudaram.
- Preços do Free plan de serviços específicos (EC2 t3.micro etc.) não verificados.
- Regras de "limite de gasto de projeto" do Paid plan: escopo de "projeto" não esclarecido.
