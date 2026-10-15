# Pesquisa 14 — Route 53, CloudFront e certificados

## Pontos conferidos
- Route 53: hosted zone inclui até 10.000 registros. acima: US$ 0,0015/registro/mês. fonte: https://aws.amazon.com/route53/pricing/
- Alias A/AAAA para serviços AWS suportados (ELB, CloudFront etc.): consultas sem custo. fonte: https://aws.amazon.com/route53/pricing/
- Alias para recurso não-AWS: consulta cobrada como padrão (fonte secundária). fonte: https://aws.amazon.com/route53/pricing/
- CNAME no apex proibido por DNS. alias resolve isso (conceito estável, não pesquisado).
- Consulta padrão (zona pública): US$ 0,40/milhão até 1 bi/mês; US$ 0,20/milhão acima. fonte: https://aws.amazon.com/route53/pricing/
- Zona privada: consultas grátis (fonte secundária, não confirmada na página oficial). fonte: https://aws.amazon.com/route53/pricing/
- Health check básico: US$ 0,50/mês endpoint AWS; US$ 0,75/mês endpoint não-AWS. fonte: https://aws.amazon.com/route53/pricing/
- Health check recurso opcional (HTTPS, string match etc.): US$ 1,00/mês AWS; US$ 2,00/mês não-AWS. fonte: https://aws.amazon.com/route53/pricing/
- Até 50 health checks de endpoints AWS por conta sem cobrança. fonte: https://aws.amazon.com/route53/pricing/
- Preço de registro de domínio varia por TLD; .com.br não consta na página de preços. Registro .br: conferir se Route 53 registra (não confirmado). fonte: https://aws.amazon.com/route53/pricing/
- ACM: certificados públicos novos e renovados têm validade padrão de 198 dias (antes 395). anunciado 18/02/2026. fonte: https://aws.amazon.com/about-aws/whats-new/2026/02/aws-certificate-manager-updates-default
- Motivo: CA/Browser Forum, máximo 200 dias a partir de 15/03/2026. fonte: https://aws.amazon.com/about-aws/whats-new/2026/02/aws-certificate-manager-updates-default
- ACM renova 45 dias antes de expirar. certificados existentes de 395 dias seguem válidos até renovar. certificados privados seguem 395 dias. fonte: https://aws.amazon.com/about-aws/whats-new/2026/02/aws-certificate-manager-updates-default
- Renovação automática exige validação DNS (recomendada). validação HTTP não suporta wildcard; wildcard exige DNS ou e-mail. fonte: https://docs.aws.eu/acm/latest/userguide/acm-certificate-characteristics.html
- Certificado para CloudFront deve estar em us-east-1, independente da região da origem. fonte: https://stackharbor.com/en/knowledge-base/awsguide-cloudfront-custom-domain-acm-https/ (secundária; confirmar na doc CloudFront)
- Domínio (alternate domain name) só pode estar em uma distribuição; erro `CNAMEAlreadyExists` em migração. fonte: https://oneuptime.com/blog/post/2026-02-12-acm-certificates-cloudfront-distributions/view (secundária)
- OAC: bucket policy com principal `cloudfront.amazonaws.com`, ação `s3:GetObject`, condição `AWS:SourceArn` = ARN da distribuição. fonte: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
- OAC exige S3 Object Ownership "Bucket owner enforced" (padrão em buckets novos). fonte: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_cloudfront_origins/README.html
- OAC só funciona com endpoint REST do bucket, não com endpoint de website estático. fonte: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
- Objetos com SSE-KMS: key policy precisa de statement para a distribuição. fonte: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
- CDK Python: `S3BucketOrigin.with_origin_access_control(bucket)` cria o OAC se `origin_access_control` não for passado (e ajusta a bucket policy). fonte: https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_cloudfront_origins/S3BucketOrigin.html
- Padrão SPA: `default_root_object="index.html"` + `error_responses` mapeando 403 e 404 para `/index.html` com status 200. esconde erros reais (ex.: API/arquivo ausente). fonte: https://qiita.com/guupys/items/90c72611b9dc14cc0f63
- Bucket privado sem `s3:ListBucket` para o OAC: S3 devolve 403 (não 404) para chave inexistente; por isso o mapeamento do 403 (conhecimento prévio, não confirmado em fonte oficial).

## Preços e limites (us-east-1/EUA, out/2026)
- CloudFront agora tem planos flat-rate: Free, Pro, Business, Premium; sem cobrança de excedente; sem compromisso anual. fonte: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html
- Cada plano cobre 1 distribuição e até 1 domínio apex. inclui CDN, WAF/DDoS, Route 53 DNS, certificado TLS (ACM), CloudWatch Logs, créditos S3. fonte: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html
- Franquia mensal: Free 1 M requisições / 100 GB; Pro 10 M / 50 TB; Business 125 M / 50 TB; Premium 500 M / 50 TB. franquia não é limite rígido; avisos em 50%, 80%, 100%. fonte: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html
- Registros por hosted zone no plano: Free 50, Pro 100, Business 1000, Premium 5000. comportamentos de cache: 5/10/50/100. regras WAF: 5/25/50/75. fonte: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html
- Créditos S3 Standard: Free 5 GB, Pro 50 GB, Business 1 TB, Premium 5 TB. OAC, DNSSEC, CloudFront Functions incluídos em todos; Lambda@Edge continua pay-as-you-go. fonte: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html
- Preço mensal dos planos: Free US$ 0, Pro US$ 15, Business US$ 200, Premium US$ 1.000 (só em resumo de busca; conferir na página oficial). fonte: https://aws.amazon.com/blogs/networking-and-content-delivery/introducing-flat-rate-pricing-plans-with-no-overages
- Hosted zone Route 53: US$ 0,50/mês (primeiras 25); US$ 0,10/mês adicionais. fonte: https://aws.amazon.com/route53/pricing/
- Pay-as-you-go CloudFront: free tier permanente de 1 TB saída + 10 M requisições/mês (fonte secundária). fonte: https://www.cloudzero.com/blog/cloudfront-pricing

## Não confirmado
- Hosted zone ID fixo dos alias para CloudFront (`Z2FDTNDATAQYW2`, de memória): conferir na doc antes de citar. Em CDK, `route53_targets.CloudFrontTarget` dispensa o ID.
- Hosted zone deletada em até 12 h não é cobrada (só fonte terceira).
- Mapeamento 403/404 → index.html: sem página oficial lida.
- Se a página de preços pay-as-you-go da CloudFront mudou além do free tier citado.
- Regra de exclusividade us-east-1 do ACM para CloudFront: só fontes secundárias.
