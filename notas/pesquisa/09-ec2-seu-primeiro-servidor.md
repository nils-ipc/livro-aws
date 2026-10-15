# Pesquisa 09 — EC2: seu primeiro servidor

## Pontos conferidos
- free tier depende data criação conta: antes 2025-07-15 vs a partir de 2025-07-15. fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html
- conta antes 2025-07-15: tipos free tier eligible `t2.micro`, `t3.micro`; 12 meses; excedeu = cobra pay-as-you-go. fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html
- conta a partir 2025-07-15: eligible `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, `c7i-flex.large`, `m7i-flex.large`. fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html
- conta nova: USD $100 crédito de cadastro + até $100 extra em créditos; dura 6 meses ou até créditos acabarem (o que vier primeiro); não excede limite (plano free). fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html
- EBS free tier eligible: `standard`, `st1`, `sc1`, `gp2`, `gp3` (ambos grupos). fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html
- listar tipos eligible: `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true --query "InstanceTypes[*].[InstanceType]" --output text | sort`. fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html
- listar AMIs eligible: `aws ec2 describe-images --filters Name=free-tier-eligible,Values=true --query "Images[*].[ImageId]" --output text | sort`. fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html
- console EC2 Dashboard caixa "EC2 Free Tier" só para contas antigas; uso atualiza 3 vezes/dia, não em tempo real. fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-free-tier-usage.html
- t2.micro/t3.micro sobem em modo Unlimited por padrão; pode gerar custo extra de crédito de CPU. fonte: https://aws.amazon.com/ec2/pricing/on-demand/
- crédito CPU Unlimited: T3 $0.05/vCPU-hora Linux; T4g $0.04/vCPU-hora Linux. fonte: https://aws.amazon.com/ec2/pricing/on-demand/
- IPv4 público: $0.005 por IP por hora, desde 2024-02-01, todo IPv4 público (em uso ou ocioso). fonte: https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights
- free tier IPv4: 750 horas/mês de IPv4 público em EC2 (conta antiga, 12 meses); passou disso, $0.005/h. fonte: https://aws.amazon.com/about-aws/whats-new/2024/02/aws-free-tier-750-hours-free-public-ipv4-addresses/
- 24x7 de 1 IPv4 ≈ 730 h x $0.005 ≈ $3.65/mês (conta minha, fora do free tier). fonte: https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights
- AMI recomendada: Amazon Linux 2023 (AL2023); gerenciador de pacotes `dnf`; AL2 sem `amazon-linux-extras`. fonte: https://docs.aws.amazon.com/linux/al2023/ug/ec2.html
- Amazon Linux 2 chegou ao fim do suporte (EOL) em 2026-06-30; não usar no livro. fonte: https://aws.amazon.com/amazon-linux-2/faqs/
- AL2023 suporte até junho 2029 (FAQ). fonte: https://aws.amazon.com/amazon-linux-2/faqs/
- parâmetro SSM AMI x86_64: `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`; arm64: `.../al2023-ami-kernel-default-arm64`; minimal: `al2023-ami-minimal-kernel-default-{x86_64,arm64}`. fonte: https://docs.aws.amazon.com/linux/al2023/ug/ec2.html
- uso em run-instances: `--image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`. fonte: https://docs.aws.amazon.com/linux/al2023/ug/ec2.html
- kernel padrão AL2023 muda de 6.1 para 6.18 a partir de 2026-08-17 em novas instâncias; para fixar: `al2023-ami-kernel-6.1-x86_64`. fonte: https://docs.aws.amazon.com/linux/al2023/ug/ec2.html
- cada AMI AL2023 é marcada deprecated 90 dias após lançamento; usar parâmetro SSM, não ID fixo. fonte: https://docs.aws.amazon.com/linux/al2023/ug/ec2.html
- AL2023 em Arm só Graviton2 ou superior; sem instâncias A1. fonte: https://docs.aws.amazon.com/linux/al2023/ug/ec2.html
- nome AMI: `al2023-ami-2023.0.[data].[build]-kernel-[versão]-[arm64|x86_64]`; conferir Owner alias = amazon. fonte: https://docs.aws.amazon.com/linux/al2023/ug/ec2.html
- run-instances sem `--security-group-ids` usa SG default da VPC: só aceita tráfego de dentro do mesmo SG; SSH de fora não entra. fonte: https://docs.aws.amazon.com/linux/al2023/ug/ec2.html
- Session Manager pré-requisitos: instância gerenciada pelo SSM + instance profile com policy `AmazonSSMManagedInstanceCore` + saída HTTPS 443 para endpoints do SSM (ou VPC endpoints). fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/session-manager.html
- Session Manager no CLI: instalar `session-manager-plugin` local (`session-manager-plugin --version`); iniciar `aws ssm start-session --target i-XXXX`. fonte: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
- instância aparece em Fleet Manager como Online antes de a sessão funcionar; agente: `systemctl status amazon-ssm-agent`. fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/session-manager.html
- user data: máximo 16 KB em forma bruta (antes do base64). fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html
- user data roda só no primeiro boot por padrão; editar com instância parada e reiniciar não reexecuta. fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html
- não pôr segredo em user data (legível pelo metadata service); usar Parameter Store. fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html
- IMDSv2 exigido (`HttpTokens=required`) pode quebrar software antigo que usa IMDSv1. fonte: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html

## Preços e limites (us-east-1, consulta 2026-10)
- gp3: $0.08/GB-mês; baseline 3,000 IOPS e 125 MiB/s inclusos; IOPS extra $0.005/IOPS-mês; throughput extra $0.04/MB/s-mês; cobrança por segundo, mínimo 60 s. fonte: https://aws.amazon.com/ebs/pricing
- preço/hora on-demand de t3.micro, t3.small, t4g.small: NÃO obtido na página (tabela dinâmica). conferir em https://aws.amazon.com/ec2/pricing/on-demand/

## Não confirmado
- preço por hora das instâncias t3/t4g us-east-1 (memória: t3.micro ~$0.0104/h; não usar sem conferir).
- `DeleteOnTermination` padrão do volume raiz = true no console (conhecimento geral; não achado na busca).
- `HttpTokens` padrão (IMDSv2 required) no AL2023 / em contas novas; não confirmado.
- caminho do log de cloud-init `/var/log/cloud-init-output.log` (só fonte de terceiros).
- SSM Agent pré-instalado no AL2023 (só confirmado para AL2 em fonte de terceiros).
- nome do pacote/serviço Nginx no AL2023 (`sudo dnf install -y nginx`; `systemctl enable --now nginx`): memória, não conferido.
- valor extra em créditos do plano novo ("até $100") confere em inglês na doc EC2; versão francesa de outra página mostrou $100 total em dado resultado de busca divergente.
