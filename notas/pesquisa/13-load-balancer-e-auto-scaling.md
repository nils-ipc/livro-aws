# Pesquisa 13 — Load Balancer e Auto Scaling

## Pontos conferidos
- ALB health check default (instance/ip): interval 30 s (faixa 5–300), timeout 5 s (faixa 2–120). fonte: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html
- Healthy threshold default 5 (faixa 2–10). fonte: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html
- Deregistration delay default 300 s (faixa 0–3600). Atributo: `deregistration_delay.timeout_seconds`. fonte: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-target-group-attributes.html
- Estado do alvo em deregistration: `draining`, depois `unused`. Sem requisição em andamento nem conexão ativa: deregistration termina na hora (console segue mostrando `draining` até o timeout). fonte: mesma URL
- Alvo que fecha conexão antes do delay: cliente recebe erro 5xx. fonte: mesma URL
- Algoritmo default: round robin. Outros: least outstanding requests, weighted random. Atributo: `load_balancing.algorithm.type` (valor `least_outstanding_requests`). fonte: mesma URL
- Slow start desligado por padrão. Atributo: `slow_start.duration_seconds` (0 desliga). Aumento linear de tráfego. Não funciona com least outstanding requests nem weighted random. fonte: mesma URL
- Fail open: sem alvos saudáveis suficientes, ALB manda tráfego a todos os alvos registrados. fonte: mesma URL
- Cross-zone no ALB: sempre ligado no nível do LB, não desliga; target group pode sobrescrever (`load_balancing.cross_zone.enabled`). fonte: mesma URL
- Subnet sem alvo (AZ vazia) com cross-zone off: HTTP 503. fonte: mesma URL
- Sticky sessions: por target group. Duration-based cookie `AWSALB` (+ `AWSALBCORS`); app-based cookie com nome próprio (não usar `AWSALB`, `AWSALBAPP`, `AWSALBTG`). Duração 1 s a 7 dias. Atributos: `stickiness.enabled`, `stickiness.type` (`app_cookie`), `stickiness.lb_cookie.duration_seconds`. Não funciona com cross-zone off. fonte: mesma URL
- Se alvo sticky fica unhealthy ou sai: ALB escolhe outro e a sessão passa a "grudar" no novo. fonte: mesma URL
- Automatic Target Weights (ATW): detecção de anomalia sempre ligada (5xx e falhas de conexão, mín. 3 alvos saudáveis); mitigação só com weighted random. fonte: mesma URL
- ASG health check grace period: console default 300 s; CLI/SDK default 0 s. Vale para instâncias novas, standby retornadas e anexadas manualmente. fonte: https://docs.aws.amazon.com/autoscaling/ec2/userguide/health-check-grace-period.html
- Durante a grace period, instância fora do estado EC2 `running` é marcada Unhealthy e substituída na hora. fonte: mesma URL
- CLI: `aws autoscaling create-auto-scaling-group --auto-scaling-group-name my-asg --health-check-grace-period 60 ...`; `aws autoscaling update-auto-scaling-group --auto-scaling-group-name my-asg --health-check-grace-period 120`. fonte: mesma URL
- Com lifecycle hooks de launch, grace period pode ser 0. AWS recomenda definir também default instance warmup. fonte: mesma URL
- Target tracking com `ALBRequestCountPerTarget` exige `ResourceLabel` (identifica ALB + target group). Alvo = média de requisições por instância em 1 minuto. fonte: https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html
- ASG só escala a zero se min capacity = 0. fonte: https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html
- Warmup da política sobrescreve o default do grupo; sem default instance warmup, `EstimatedInstanceWarmup` usa o default cooldown. Instância em warmup não entra nas métricas agregadas. fonte: https://docs.aws.amazon.com/autoscaling/ec2/APIReference/API_PutScalingPolicy.html
- Launch configurations: contas criadas a partir de 1 out 2024 não criam por nenhum meio (console, API, CLI, CloudFormation). Sem suporte a novos tipos de instância desde 1 jan 2023. Usar Launch Templates. fonte: https://docs.aws.amazon.com/autoscaling/latest/userguide/LaunchConfiguration.html
- Cotas ALB: 1.000 alvos por ALB, 50 listeners por ALB, 100 regras por ALB (sem contar default), 3.000 target groups por região (ALB e NLB juntos). Todas ajustáveis. fonte: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-limits.html

## Preços e limites (us-east-1, out/2026)
- ALB: US$ 0,0225 por hora (hora parcial conta cheia). fonte: https://aws.amazon.com/elasticloadbalancing/pricing/
- LCU: US$ 0,008 por LCU-hora; cobra só a dimensão de maior uso na hora. fonte: https://aws.amazon.com/elasticloadbalancing/pricing/
- 1 LCU = 25 novas conexões/s, ou 3.000 conexões ativas/min (1.500 com mTLS), ou 1 GB/h processado (0,4 GB/h alvo Lambda), ou 1.000 avaliações de regra/s (10 primeiras regras grátis). fonte: mesma URL
- Free tier ELB: 750 h/mês (Classic + ALB) e 15 LCUs. Contas criadas a partir de 15 jul 2025: até US$ 200 em créditos que podem cobrir ELB. fonte: mesma URL
- IPv4 público: US$ 0,005 por IP por hora desde 1 fev 2024 (~US$ 3,65/mês). Vale também para os IPs do ALB. fonte: https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/

## Não confirmado
- Idle timeout default do ALB (60 s na memória; não apareceu na documentação consultada). Conferir em https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-load-balancer-attributes.html antes de afirmar.
- Unhealthy threshold default do ALB (2 na memória) e faixa de slow start (30–900 s na memória): não verificados.
- Default cooldown de 300 s do ASG e default de health check type (EC2, não ELB; precisa habilitar ELB): não verificados nesta pesquisa.
- Preço de warm pools e comportamento de instance refresh: não pesquisados.
