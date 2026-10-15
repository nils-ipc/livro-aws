# Pesquisa 11 — S3: armazenamento de objetos

## Pontos conferidos
- Padrão novos buckets desde abr/2023: 4 configs Block Public Access ligadas. fonte: https://aws.amazon.com/about-aws/whats-new/2023/04/amazon-s3-security-best-practices-buckets-default
- Padrão novos buckets: ACLs desabilitadas (Object Ownership = Bucket owner enforced). Set/update ACL falha; leitura de ACL funciona. fonte: https://aws.amazon.com/about-aws/whats-new/2023/04/amazon-s3-security-best-practices-buckets-default
- Anúncio 13/12/2022; deploy começou 05/04/2023; todas as Regiões. fonte: https://aws.amazon.com/blogs/aws/heads-up-amazon-s3-security-changes-are-coming-in-april-of-2023
- Vale para qualquer método de criação (CLI, API, SDK, CloudFormation). Buckets existentes não mudam. fonte: https://aws.amazon.com/about-aws/whats-new/2022/12/amazon-s3-automatically-enable-block-public-access-disable-access-control-lists-buckets-april-2023
- Presigned URL, IAM user: até 7 dias, só com SigV4. fonte: https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html
- Presigned URL com credencial temporária: expira junto com a credencial, mesmo com expiração maior pedida. fonte: https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html
- Role de EC2 (instance profile): URL vale pela duração da credencial, tipicamente 6 h. fonte: https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html
- AssumeRole: sessão padrão 1 h; URL morre com a sessão. ECS: credencial roda a cada 1–6 h. fonte: https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html
- Presigned URL gerada no console S3: expiração de 1 minuto a 12 horas. CLI/SDK: até 7 dias. fonte: https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html
- Presigned URL reutilizável até expirar. PUT com mesma key substitui objeto existente. fonte: https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html
- Expiração checada no momento da requisição HTTP. Download em andamento continua após expirar; retomada falha. fonte: https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html
- Presigned URL = bearer token. Limitar com bucket policy: condição `s3:signatureAge` (milissegundos; exemplo doc: `"NumericGreaterThan": {"s3:signatureAge": "600000"}` = Deny se assinatura > 10 min). fonte: https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html
- Restrição de rede: `aws:SourceIp` (endpoint público); `aws:SourceVpc` / `aws:SourceVpce` (VPC endpoint). fonte: https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html
- Upload com presigned URL: SigV4 suporta checksums CRC-64/NVME, CRC32, CRC32C, SHA-1, SHA-256, MD5 etc.; SigV2 só MD5. fonte: https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html
- Erros comuns presigned: `SignatureDoesNotMatch` (relógio fora de NTP, proxy alterando headers, método/headers diferentes entre gerar e usar); `ExpiredToken` (credencial que assinou expirou); 403 (quem gerou sem permissão, ou Deny na bucket policy). fonte: https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html
- Lifecycle: objeto precisa ter ≥ 30 dias para ir a Standard-IA ou One Zone-IA. fonte: https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html
- Lifecycle desde set/2024: por padrão NÃO transiciona objetos < 128 KB para nenhuma classe (custo da requisição de transição > economia). Configs criadas antes mantêm comportamento antigo até serem editadas. Sobrescrever com filtro `ObjectSizeGreaterThan` / `ObjectSizeLessThan`. fonte: https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html
- Duração mínima cobrada: Standard-IA e One Zone-IA 30 dias; Glacier Instant Retrieval 90; Glacier Flexible Retrieval 90; Glacier Deep Archive 180. fonte: https://aws.amazon.com/s3/pricing/
- Tamanho mínimo cobrado 128 KB: Standard-IA, One Zone-IA, Glacier Instant Retrieval. Flexible Retrieval e Deep Archive: +40 KB metadata por objeto arquivado. fonte: https://aws.amazon.com/s3/pricing/
- Intelligent-Tiering: retrieval standard/bulk grátis; cobra taxa mensal de monitoramento por objeto. fonte: https://aws.amazon.com/s3/pricing/
- Cota padrão: 10.000 buckets general purpose por conta (era 100 até nov/2024); até 1 milhão via Service Quotas; primeiros 2.000 grátis, acima cobra taxa mensal. Cotas gerenciadas só em us-east-1. fonte: https://aws.amazon.com/about-aws/whats-new/2024/11/amazon-s3-up-1-million-buckets-per-aws-account/
- Docs: sem limite de tamanho de bucket nem de número de objetos. fonte: https://docs.aws.amazon.com/AmazonS3/latest/dev/BucketRestrictions.html

## Preços e limites (us-east-1, out/2026)
- GET (Standard): US$ 0,0004 por 1.000 requisições. fonte: https://aws.amazon.com/s3/pricing/
- Transferência para internet: primeiros 100 GB/mês grátis (agregado entre serviços e Regiões). fonte: https://aws.amazon.com/s3/pricing/
- Inter-Region us-east-1 → us-east-2: US$ 0,01/GB (exemplo da página). fonte: https://aws.amazon.com/s3/pricing/
- Free tier novos clientes (desde 15/07/2025): até US$ 200 em créditos; plano gratuito 6 meses; créditos usáveis em 12 meses. Valores de S3 específicos não listados. fonte: https://aws.amazon.com/s3/pricing/
- Valores abaixo vêm de blogs de terceiros (página oficial não renderizou tabelas): Standard US$ 0,023/GB-mês (primeiros 50 TB), PUT/COPY/POST/LIST US$ 0,005 por 1.000; Standard-IA US$ 0,0125/GB, retrieval US$ 0,01/GB; Glacier Instant US$ 0,004/GB, retrieval US$ 0,03/GB; Deep Archive US$ 0,00099/GB. fonte: https://cloudburn.io/blog/amazon-s3-pricing

## Casos reais
- Capital One, 2019: anunciado 19/07/2019; mais de 100 milhões de registros de clientes EUA/Canadá; WAF mal configurado + SSRF; role do WAF com acesso a buckets (relato: mais de 700 buckets). Fonte secundária. fonte: https://www.rackspace.com/pt-br/blog/capital-one-data-breach-two-security-controls-you-should-review

## Não confirmado
- Preços S3 oficiais (tabelas não renderizaram); conferir no AWS Pricing Calculator antes de citar como exato. Usar "cerca de" e a data.
- Criptografia padrão SSE-S3 em todos os objetos (jan/2023): não verificado nesta pesquisa.
- Limites de objeto (5 GB por PUT único, 5 TB máximo, multipart): não verificado.
- `generate_presigned_post` (conditions, content-length-range): não verificado; só PUT presigned foi conferido.
- CORS para upload direto do React (JSON exato): não verificado.
- Casos de buckets expostos além de Capital One (ex.: Verizon 2017): não verificado, e Capital One não foi por bucket público.
- Lifecycle IA → Glacier exigir +30 dias, e 128 KB para Intelligent-Tiering: só fonte de terceiros, não usar.
