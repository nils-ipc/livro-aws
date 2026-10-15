# Resumo 09 — EC2: seu primeiro servidor

## Conceitos explicados (não reexplicar depois)
- instância = VM no Nitro; cobrança por segundo (mín. 60 s) em running; stopped cobra só disco
- nome tipo: família/geração/atributos (g Graviton, i, a, d)/tamanho; tabela T, M, C, R
- família T burstable, créditos CPU (analogia franquia celular); unlimited padrão T3 cobra excedente; standard desacelera
- Graviton arm64 vs x86_64 (ligado ao exec format error cap. 3)
- free tier por data da conta (15/07/2025); t3.micro elegível nos dois
- AMI ≈ imagem Docker da máquina; AL2023 (dnf, Python 3.9 padrão, pacote python3.12), AL2 EOL 30/06/2026; parâmetro SSM `resolve:ssm:`; AMI obsoleta em 90 dias
- key pair vs Session Manager (saída 443, IAM, sem porta 22); 3 pré-requisitos
- Security Group: middleware na rede, só allow, stateful, origem CIDR ou SG; SG default
- user data: cloud-init, root, 1º boot só, 16 KB, sem segredos (IMDS)
- EBS: disco de rede, preso à AZ, cobra parado, snapshots, gp3 ~US$ 0,08/GB-mês, DeleteOnTermination
- iam:PassRole com Resource da role + `iam:PassedToService`
- VPC default; IP público via NAT 1:1 (não aparece em `ip addr`); Elastic IP
- systemd template unit `@`/`%i` (analogia função com parâmetro); deploy key GitHub
- IMDSv2 (`HttpTokens=required`)

## Estado do Rangô ao fim
- permission set `PowerUserAccess`: inline ganhou Sid `PassarSoARoleDoServidor` (PassRole só `rango-ec2`, só ec2)
- repo: `infra/ec2/user-data.sh` (nginx, git, python3.12, python3.12-pip, valkey; usuário rango home /opt/rango; /etc/rango)
- criado e testado: SG `rango-web` (só 80/0.0.0.0/0), instância `rango-api-01` t3.micro AL2023, gp3 10 GiB criptografado, IP 198.51.100.23 / 172.31.23.104; /opt/rango/codigo, /opt/rango/venv, /etc/rango/api.env (REDIS_URL 127.0.0.1, CORS localhost:5173), `rango-api.service` (2 workers, 127.0.0.1:8000), `rango-worker@restaurante|email`, `/etc/nginx/conf.d/rango.conf` (porta 80, default_server)
- destruídos: instância, volume, SG; deploy key removida; role `rango-ec2` mantida
- pedidos ainda no Redis/Valkey; front local, sem HTTPS

## Casos reais e exemplos usados (não repetir)
- sócia em Recife, terça 22h, notebook na mochila
- Capital One jul/2019 (SSRF, IMDSv1, ~100 mi + 6 mi), IMDSv2 nov/2019
- erro UnauthorizedOperation PassRole; descrição SG sem acento (InvalidParameterValue); git com cwd /root; reboot test
- armadilhas: porta 22 aberta, IP muda no stop, free tier ≠ grátis, user data 1 vez, 1 GiB sem swap → modify-instance-attribute t3.small

## Promessas feitas
- ponte: trazer Postgres para o servidor; atalho = instalar na mesma EC2 e abrir 5432 para 0.0.0.0/0 "só até terminar o teste"; VPC default tudo público; cap. 10: VPC própria, subnets públicas/privadas, rotas, IGW, NAT Gateway (custo)
- bucket de fotos e acesso da role: cap. 11; React com domínio/HTTPS: cap. 14; load balancer com DNS: caps. 13–14; segredos em cofre gerenciado (Parameter Store config, Secrets Manager senha do banco): cap. 16; VPC endpoints SSM: cap. 10
