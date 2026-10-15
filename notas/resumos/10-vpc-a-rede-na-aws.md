# Resumo 10 — VPC: a rede na AWS

## Conceitos explicados (não reexplicar depois)
- VPC: rede privada isolada por região; analogia rede de casa (faixa privada, roteador, NAT); VPC/subnets/RTs/IGW/SGs/NACLs grátis
- CIDR VPC /16 a /28, tamanho imutável, secundários (5), sem sobreposição (peering, VPN); evitar 10.0.0.0/16, 172.31/16 (default), 172.17/16 (Docker)
- subnet presa a 1 AZ; 5 IPs reservados (.0, .1 router, .2 DNS, .3, último); /24 = 251; RDS e ALB exigem 2 AZs
- route table, rota `local` fixa, main route table; associação explícita
- IGW: 1 por VPC, NAT 1:1 IP público, sem custo
- subnet pública = rota 0.0.0.0/0 → IGW; privada = sem rota (proteção por construção); `map-public-ip-on-launch`
- NAT Gateway: sai sem entrar; US$ 0,045/h + 0,045/GB + EIP (us-east-1, out/2026); 1 por AZ em produção (~US$ 98/mês 3 AZs); cross-AZ US$ 0,01/GB; NAT regional (nov/2025) citado, não usado
- SG com origem outro SG (analogia `request.user.groups`); tabela SG vs NACL; NACL stateless, portas efêmeras 1024-65535, uso: bloquear faixa
- gateway endpoint (S3, DynamoDB) grátis; interface endpoint US$ 0,01/h/AZ + GB; SSM sem internet: ssm, ssmmessages, ec2messages

## Estado do Rangô ao fim
- mantidos: `rango-vpc` 10.20.0.0/16 (dns-hostnames on); subnets `rango-publica-a` 10.20.0.0/24, `-b` 10.20.1.0/24, `rango-privada-a` 10.20.10.0/24, `-b` 10.20.11.0/24 (us-east-1a/b); `rango-igw`; `rango-rt-publica` (0/0→igw), `rango-rt-privada` (local + gateway endpoint `rango-s3`); SGs `rango-web` (80 público), `rango-db` (5432 de `rango-web`), `rango-endpoints` (443 de 10.20.0.0/16)
- repo: `infra/ec2/user-data-db.sh` (postgresql17-server, initdb)
- testado e destruído: `rango-api-01` (pública), `rango-db-01` (privada 10.20.10.57, PG 17, role/db `rango`, senha via `\password`, pg_hba 10.20.0.0/16 scram-sha-256), NAT `rango-nat-a` + EIP, endpoints ssm/ssmmessages/ec2messages
- pedidos ainda no Redis/Valkey

## Casos reais e exemplos usados (não repetir)
- log hipotético `password authentication failed` porta 5432; Shodan
- Meow jul/2020 (~4 mil bancos, Diachenko, UFO VPN)
- hipotético 5 TB S3 via NAT = US$ 225
- teste timeout trocando SG; checkip mostra EIP do NAT

## Promessas feitas
- ponte: Cantina da Nona 340 fotos de 4 MB em `/opt/rango/fotos`, disco 10 GiB enchendo; foto não existe em outra instância; Uvicorn servindo bytes → S3, upload direto do navegador, buckets expostos (cap. 11)
- banco em EC2 sem NAT não atualiza; RDS nas subnets privadas: cap. 12; ASG/SG: cap. 13; CDK cria NAT por AZ (`nat_gateways`): cap. 15; senha em cofre (Parameter Store config, Secrets Manager senha do banco): cap. 16; WAF: cap. 23
