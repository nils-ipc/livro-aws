# Pesquisa 24 — Custos e arquitetura

## Pontos conferidos
- Free Tier mudou 15/07/2025. Contas novas: Free Plan (expira 6 meses após cadastro ou ao acabar créditos) ou Paid Plan. fonte: https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/
- Créditos: US$100 no cadastro + US$100 por 5 atividades de US$20 (EC2, RDS, Lambda, Bedrock, AWS Budget). fonte: https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/
- Free Plan: alguns serviços indisponíveis. Fim do plano sem upgrade: 90 dias de carência, depois conta fechada e recursos apagados. fonte: https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/
- Paid Plan: todos os serviços, créditos aplicados automaticamente, créditos não usados valem até 12 meses do cadastro. fonte: https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/
- Contas criadas antes de 15/07/2025 ficam no Free Tier legado. fonte: https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/
- Public IPv4 cobrado: US$0,005/h, em uso ou ocioso, todas as regiões comerciais (~US$3,65/mês por endereço). fonte: https://aws.amazon.com/vpc/pricing/
- Public IPv4 vale para EC2, NAT Gateway, ALB público e outros recursos públicos. fonte: https://aws.amazon.com/vpc/pricing/
- NAT Gateway: US$0,045/h + US$0,045/GB processado (exemplo us-east-2 na página oficial; us-east-1 igual segundo fonte secundária). ~US$32,85/mês parado. fonte: https://aws.amazon.com/vpc/pricing/
- NAT Gateway regional: US$0,045/h por AZ, mesmo preço por GB. fonte: https://aws.amazon.com/vpc/pricing/
- Tráfego EC2 ↔ NAT Gateway na mesma AZ por IP privado: sem cobrança de transferência. Em AZs diferentes: cobra transferência entre AZs. fonte: https://aws.amazon.com/vpc/pricing/
- Saída para internet: US$0,09/GB (exemplo da página). Via NAT: processamento + saída = US$0,135/GB. fonte: https://aws.amazon.com/vpc/pricing/
- Gateway VPC endpoint (S3, DynamoDB): sem cobrança por hora nem por dados. Forma de cortar tráfego S3 que passaria pelo NAT. fonte: https://aws.amazon.com/vpc/pricing/
- Peering entre AZs da mesma região: US$0,01/GB por direção. fonte: https://aws.amazon.com/vpc/pricing/
- AWS Budgets: 2 budgets com ações grátis por conta (doc oficial de cotas). fonte: https://docs.aws.amazon.com/cost-management/latest/userguide/management-limits.html
- Cost Anomaly Detection: detecção em até 24 h após o uso; mínimo 10 dias de histórico. fonte: https://docs.aws.amazon.com/cost-management/latest/userguide/management-limits.html
- Cost Explorer: console sem custo adicional; chamadas de API são cobradas. fonte: https://aws.amazon.com/compare/budgets-and-cost-explorer/
- Cost Explorer: previsão até 18 meses (mensal) e 3 meses (diária). fonte: https://aws.amazon.com/aws-cost-management/
- Savings Plans: 4 tipos (Compute, EC2 Instance, SageMaker AI, Database). fonte: https://aws.amazon.com/savingsplans/faqs
- Compute Savings Plans: até 66% off, aplica a EC2, Fargate e Lambda, qualquer família, região, SO. fonte: https://docs.aws.amazon.com/savingsplans/latest/userguide/plan-types.html
- EC2 Instance Savings Plans: até 72% off, preso a uma família numa região. fonte: https://docs.aws.amazon.com/savingsplans/latest/userguide/plan-types.html
- Database Savings Plans cobrem Aurora, RDS, DynamoDB, ElastiCache, DocumentDB, Neptune, Keyspaces, Timestream, DMS. fonte: https://aws.amazon.com/savingsplans/faqs
- Spot: até 90% off vs On-Demand. Aviso de interrupção com 2 minutos. fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-best-practices.html
- Spot: rebalance recommendation chega antes do aviso de 2 min. EventBridge captura os dois. ASG tem Capacity Rebalancing. fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-best-practices.html
- Spot indicado para carga stateless, tolerante a falha e flexível. fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-best-practices.html
- Well-Architected: 6 pilares (Operational Excellence, Security, Reliability, Performance Efficiency, Cost Optimization, Sustainability). fonte: https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html
- Princípios do pilar Cost Optimization (5): implement cloud financial management; adopt a consumption model; measure overall efficiency; stop spending money on undifferentiated heavy lifting; analyze and attribute expenditure. fonte: https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/design-principles.html
- Exemplo oficial: parar dev/test fora do horário comercial economiza 75% (40 h vs 168 h por semana). fonte: https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/design-principles.html

## Não confirmado
- Preço exato do NAT Gateway em us-east-1 (página oficial só mostrou exemplo Ohio). Conferir em calculator.aws antes de usar como fato.
- Preço de interface VPC endpoint (~US$0,01/h por AZ + US$0,01/GB, só fonte secundária).
- Budgets adicionais a US$0,02/dia e preço por requisição da Cost Explorer API: só fontes secundárias ou não-USD.
- Cost Anomaly Detection gratuito: só blog de terceiros.
- Desconto de Database Savings Plans (35% citado por terceiros, sem confirmação oficial).
- Free tier de 100 GB/mês de saída para internet e preços de saída por faixa: não pesquisado.
- Casos reais de fatura inesperada (empresa, ano, valor): não pesquisado; limite de buscas atingido.
