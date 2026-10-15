# Pesquisa 12 — RDS: banco de dados gerenciado

Consulta: out/2026. Rascunho; conferir antes de publicar.

## Pontos conferidos
- RDS PostgreSQL: versão major fica em standard support ao menos até EOL da comunidade. Depois, Extended Support pago, até 3 anos além do fim do standard support. fonte: https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-release-calendar.html
- PostgreSQL 18: release comunidade 13 nov 2025, release RDS 14 nov 2025. RDS fim standard support 28 fev 2031. Fim Extended Support 28 fev 2034. fonte: https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-release-calendar.html
- PostgreSQL 18.4 (minor mais recente no calendário): release RDS 14 mai 2026. Fim standard support set 2027. fonte: https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-release-calendar.html
- PostgreSQL 14: fim standard support fev 2027 (mês/ano aproximado). fonte: https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-release-calendar.html
- Datas só com mês/ano são aproximadas; AWS atualiza. Minor pode perder suporte antes da major. fonte: https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-release-calendar.html
- `rds.force_ssl`: default 1 (ligado) no PostgreSQL 15+. Default 0 no 14 e anteriores. fonte: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html
- `rds.force_ssl`: mudar exige parameter group customizado (o default não é editável). Instância já rodando precisa de reboot para usar o novo parameter group. fonte: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html
- Multi-AZ DB cluster: só MySQL e PostgreSQL. 2 standbys legíveis (3 instâncias, 3 AZs). fonte: https://aws.amazon.com/blogs/database/choose-the-right-amazon-rds-deployment-option-single-az-instance-multi-az-instance-or-multi-az-database-cluster/
- Multi-AZ DB cluster: failover típico < 35 s, sem perda de dados. Latência de commit até 2x menor que Multi-AZ com 1 standby. fonte: https://aws.amazon.com/rds/features/multi-az
- Multi-AZ instance (1 standby): standby NÃO atende leitura nem escrita. Para leitura, usar cluster ou réplica de leitura. fonte: https://aws.amazon.com/blogs/database/choose-the-right-amazon-rds-deployment-option-single-az-instance-multi-az-instance-or-multi-az-database-cluster/
- Preço do Multi-AZ DB cluster: página de preço RDS PostgreSQL só cita "Multi-AZ com um standby" e "Multi-AZ com dois standbys legíveis". fonte: https://aws.amazon.com/rds/postgresql/pricing/

## Aurora Serverless v2
- Scale to zero (auto-pause): MinCapacity=0 ACU. Sem suporte à versão: mínimo 0.5 ACU. fonte: https://docs.aws.eu/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html
- Versões mínimas com auto-pause: Aurora PostgreSQL 16.3, 15.7, 14.12, 13.15. Aurora MySQL 3.08.0+. fonte: https://docs.aws.eu/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html
- `SecondsUntilAutoPause`: 300 a 86400 s, default 300. fonte: https://docs.aws.eu/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html
- Resume: tipicamente ~15 s. Pausado > 24 h: 30 s ou mais. Configurar timeout do cliente > 15 s e retry. fonte: https://docs.aws.eu/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html
- Pausado: sem cobrança de compute da instância (`ServerlessV2Usage` = 0). Storage e custos de cluster continuam. fonte: https://docs.aws.eu/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html
- Não pausa com: qualquer conexão de usuário aberta (inclusive ociosa), RDS Proxy anexado, replicação lógica, Global Database primário. `pg_cron` não acorda instância pausada. fonte: https://docs.aws.eu/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html
- CLI: `aws rds modify-db-cluster --db-cluster-identifier <id> --serverless-v2-scaling-configuration MinCapacity=0,MaxCapacity=<max>,SecondsUntilAutoPause=<s>`. Verificar: `aws rds describe-db-clusters --db-cluster-identifier <id> --query 'DBClusters[*].ServerlessV2ScalingConfiguration|[0]'`. fonte: https://docs.aws.eu/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html

## Preços e limites (us-east-1, out/2026)
- ElastiCache Serverless Valkey: $0.084 por GB-hora. $0.0023 por milhão de ECPUs. Mínimo medido 100 MB por cache. fonte: https://aws.amazon.com/elasticache/pricing/
- ElastiCache Serverless Redis OSS: mínimo 1 GB por cache (taxas não listadas na página; ver Não confirmado). fonte: https://aws.amazon.com/elasticache/pricing/
- Piso de storage Valkey Serverless: 0,1 GB x $0.084 x ~730 h ≈ $6/mês (cálculo próprio a partir da fonte). fonte: https://aws.amazon.com/elasticache/pricing/
- Valkey Serverless: AWS diz 33% mais barato e 90% menor mínimo que as outras engines. fonte: https://aws.amazon.com/elasticache/pricing/
- Free Tier: contas criadas antes de 15 jul 2025 = modelo 12 meses (750 h cache.t3.micro ElastiCache; 750 h db.t3.micro/db.t4g.micro RDS Single-AZ, 20 GB storage, 20 GB backup). Contas após 15 jul 2025 = Free Plan ou Paid Plan com créditos ($100 + até $100 por ativação de serviços). Free Tier ElastiCache exclui Serverless. fonte: https://aws.amazon.com/elasticache/pricing/ e https://aws.amazon.com/free/database/
- RDS Extended Support, exemplo PostgreSQL 12 (us-east-2): $0.100 por vCPU-hora de 1 mar 2025 a 28 fev 2027. $0.200 a partir de 1 mar 2027. fonte: https://aws.amazon.com/rds/postgresql/pricing/
- Créditos de CPU T4g/T3 ilimitados: $0.075 por vCPU-hora, igual em todas as regiões. fonte: https://aws.amazon.com/rds/postgresql/pricing/

## Não confirmado
- Preço por hora de db.t4g.micro/medium (Single-AZ e Multi-AZ), gp3 por GB-mês, backup storage extra: tabelas não carregaram. Usar Pricing Calculator.
- Preço por ACU-hora do Aurora Serverless v2: não encontrado.
- Preço do cache.t4g.micro/small: não listado na página.
- Taxas de Serverless Redis OSS ($0.125/GB-h, $0.0034/M ECPU): só fonte de terceiros.
- Tempo de failover do Multi-AZ instance (1 standby): sem número oficial (blogs falam ~60 s). Retenção de PITR até 35 dias e senha mestre gerenciada no Secrets Manager (`--manage-master-user-password`): não conferidos nesta pesquisa; vêm da memória do modelo.
- Free Tier: valores de crédito vêm das páginas oficiais da AWS apenas parcialmente; confirmar no console de billing.
- Resultado da busca sobre PostgreSQL 17 (fim de standard support): não conclusivo.
