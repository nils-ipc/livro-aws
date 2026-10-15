# Pesquisa 10 — VPC: a rede na AWS

## Pontos conferidos
- CIDR da VPC: tamanho permitido /16 (65.536 IPs) a /28 (16 IPs). fonte: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html
- Tamanho de CIDR existente não muda (não aumenta nem diminui). Pode associar CIDR secundário. CIDR primário não pode ser desassociado. fonte: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html
- CIDR secundário: mesma faixa /16 a /28, sem sobrepor existentes. Rota `local` criada automaticamente para cada CIDR. fonte: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html
- Proibidos como CIDR de VPC: 0.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4. fonte: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html
- Faixas RFC 1918 recomendadas: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16. fonte: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html
- Evitar 172.17.0.0/16 (Docker bridge; Cloud9 e SageMaker AI usam; conflito de IP). fonte: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html
- Restrição de CIDR secundário: VPC com 10.0.0.0/8 não aceita secundário de 172.16.0.0/12 nem 192.168.0.0/16. VPC com 172.16.0.0/12 não aceita 172.31.0.0/16. fonte: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html
- Planejar CIDR sem sobreposição com outras VPCs/rede on-premises (peering e Direct Connect gateway exigem não sobrepor). fonte: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html
- Regional NAT Gateway lançado 19/11/2025. Um gateway cobre várias AZs, expande/contrai sozinho. Modos: automático (AWS gerencia IPs) e manual. fonte: https://aws.amazon.com/about-aws/whats-new/2025/11/aws-nat-gateway-regional-availability
- Regional NAT: CLI `aws ec2 create-nat-gateway` aceita availability mode `zonal` ou `regional`. Não precisa de subnet pública. Todas as regiões comerciais, exceto GovCloud e China. fonte: https://docs.aws.amazon.com/cli/latest/reference/ec2/create-nat-gateway.html
- Regional NAT: ao surgir recurso em nova AZ, expansão pode levar até ~60 min; até lá tráfego sai por outra AZ (cross-AZ). Fonte secundária. fonte: https://www.repost.aws/articles/AR77CnVH2zR6KjoD4SvgNVAQ/understanding-amazon-vpc-regional-nat-gateway
- CDK Vpc (padrão): um NAT gateway por AZ (`nat_gateways` reduz custo, mas pode gerar tráfego cross-AZ). Layout padrão: subnets públicas + privadas (com NAT). Com `nat_gateways=0` e sem subnet_configuration: públicas + isoladas. Docs v1 citam PRIVATE_WITH_NAT; v2 usa PRIVATE_WITH_EGRESS (nome v2 não confirmado na busca). fonte: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_ec2/VpcProps.html
- Gateway endpoints (S3, DynamoDB): sem cobrança por hora nem por GB. fonte: https://aws.amazon.com/vpc/pricing/
- Interface endpoint: cobra por hora por AZ + por GB processado, somado em todos os endpoints da região. fonte: https://aws.amazon.com/privatelink/pricing/
- Endpoint de interface em 3 AZs = 3x horas de endpoint. fonte: https://cloudcostkit.com/guides/aws-privatelink-pricing/

## Preços e limites (consulta em 10/2026; preços us-east-2 Ohio na página, conferir região sa-east-1)
- NAT Gateway: US$ 0,045/h + US$ 0,045/GB processado (Ohio). Cobra o GB independente de origem/destino. fonte: https://aws.amazon.com/vpc/pricing/
- Regional NAT Gateway: US$ 0,045/h por AZ ativa + US$ 0,045/GB. fonte: https://aws.amazon.com/vpc/pricing/
- IPv4 público: US$ 0,005/h por IP (em uso ou ocioso), desde 01/02/2024. Vale para EC2, RDS, EKS etc. BYOIP isento. fonte: https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights
- Free tier de IPv4: 750 h/mês só para EC2 e só nos 12 primeiros meses da conta. Outros serviços cobram. fonte: https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights
- Interface endpoint: US$ 0,01/h por AZ (fonte secundária). Dados: US$ 0,01/GB nos primeiros 1 PB, 0,006 nos 4 PB seguintes, 0,004 acima de 5 PB. fonte: https://aws.amazon.com/privatelink/pricing/
- Tráfego entre AZs: US$ 0,01/GB em cada direção (exemplo de peering na página). Saída para internet: US$ 0,09/GB. fonte: https://aws.amazon.com/vpc/pricing/
- Cotas por região: 5 VPCs, 5 internet gateways (1 por VPC), 5 EIPs, 5 NAT gateways por AZ. fonte: https://docs.aws.amazon.com/vpc/latest/userguide/amazon-vpc-limits.html
- Cotas por VPC: 200 subnets, 200 route tables, 200 NACLs, 5 CIDRs IPv4 (até 50). fonte: https://docs.aws.amazon.com/vpc/latest/userguide/amazon-vpc-limits.html
- Rotas por route table: 500 (até 1.000). fonte: https://docs.aws.amazon.com/vpc/latest/userguide/amazon-vpc-limits.html
- Security groups: 2.500 por região, 60 regras entrada e 60 saída por SG, 5 SGs por interface de rede (até 16); regras × SGs por interface ≤ 1.000. fonte: https://docs.aws.amazon.com/vpc/latest/userguide/amazon-vpc-limits.html
- NACL: 20 regras por NACL, para entrada e para saída (até 40 + 40, pode afetar desempenho). fonte: https://docs.aws.amazon.com/vpc/latest/userguide/amazon-vpc-limits.html
- EIPs por NAT gateway público: 2 (até 8). fonte: https://docs.aws.amazon.com/vpc/latest/userguide/amazon-vpc-limits.html

## Casos reais
- Capital One, 2019: WAF (ModSecurity) mal configurado em EC2 permitiu alcançar o serviço de metadata e obter credenciais temporárias da role; role com permissões excessivas. Cerca de 100 milhões de pessoas (Krebs cita ~106 milhões). Técnica exata (SSRF) varia por fonte. IMDSv2 mitiga. fonte: https://krebsonsecurity.com/2019/08/what-we-can-learn-from-the-capital-one-hack/
- Ataque "Meow", julho/2020: bot apagou bancos Elasticsearch e MongoDB expostos sem autenticação, sem pedir resgate. Contagens: >1.800 (BleepingComputer, 22/07), ~4.000 (BleepingComputer, atualização), >4.600 (TechTarget). Primeiro caso público achado por Bob Diachenko (UFO VPN). fonte: https://www.bleepingcomputer.com/news/security/new-meow-attack-has-deleted-almost-4-000-unsecured-databases/

## Não confirmado
- 5 IPs reservados por subnet (.0 rede, .1 router da VPC, .2 DNS, .3 reservado, último broadcast): a página lida não listou; conferir antes de afirmar.
- Hora exata e valor de interface endpoint em sa-east-1 e us-east-1; NAT em sa-east-1 (página mostrou só Ohio).
- Nome PRIVATE_WITH_EGRESS e defaults de `max_azs` no CDK v2: busca não confirmou.
- Regras de NACL (número de regra, stateless, portas efêmeras 1024-65535) e precedência: não pesquisado; conferir em https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html
- Caso de RDS público no Shodan: busca não retornou fonte.
