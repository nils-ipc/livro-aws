# Resumo 11 — S3: armazenamento de objetos

## Conceitos explicados (não reexplicar depois)
- S3: dicionário gigante via HTTP; bucket, objeto (bytes + metadados), key; prefixos ≠ pastas; sem edição parcial; PUT mesma key substitui
- nome bucket único no mundo; sem limite tamanho/objetos; 10.000 buckets padrão (até 1 mi); 11 noves, ≥3 AZs; consistência forte desde dez/2020; PUT único até 5 GB, maior = multipart
- custo: Standard ~US$ 0,023/GB-mês (terceiros, out/2026); 100 GB/mês saída grátis; tráfego de saída → caps. 14 e 24
- classes (analogia bancada/despensa/depósito): tabela 7 classes; duração mínima 30/90/180 d; mínimo 128 KB (IA, Glacier Instant); One Zone-IA só dado regenerável; Intelligent-Tiering taxa monitoramento
- lifecycle: job de limpeza declarativo; 30 d mín. para IA; set/2024 não transiciona < 128 KB
- versionamento: analogia git; VersionId, delete marker, só suspende; + lifecycle noncurrent
- bucket policy = resource-based; Block Public Access 4 configs (tabela); padrão abr/2023 + ACLs desabilitadas (BucketOwnerEnforced); SSE-S3 padrão desde 5/jan/2023
- presigned URL: ingresso com hora marcada; assinatura local; expira com credencial temporária (EC2 ~6 h, AssumeRole 1 h); reuso; bearer token; `s3:signatureAge`; CORS no bucket; erros SignatureDoesNotMatch (demo Content-Type), ExpiredToken

## Estado do Rangô ao fim
- bucket `rango-fotos-pratos-<conta>` us-east-1: BPA on, versionamento, lifecycle `limpar-historico` (noncurrent 30 d, delete markers órfãos, multipart 7 d), CORS PUT de `https://rango.test:5173`, policy Deny sem HTTPS + Deny PutObject signatureAge > 600000; MANTIDO
- repo: `infra/s3/rango-fotos-policy.json`, `-lifecycle.json`, `-cors.json`; `iam/rango-ec2-fotos.json`
- role `rango-ec2` + inline `RangoFotos` (Put/Get/DeleteObject em `fotos/*`, sem ListBucket)
- `backend/app/fotos.py`: POST `/restaurantes/{r}/fotos/upload-url` (ExpiresIn 300, key `fotos/{r}/{uuid}.ext`), POST `/fotos` (head_object, ≤10 MB, Redis set `fotos:{r}`), GET `/fotos` (URLs GET 3600 s); boto3 em requirements
- `frontend/src/EnviarFoto.tsx`
- compose: `rango-api:0.6.0`, env FOTOS_BUCKET/AWS_REGION/AWS_PROFILE, `~/.aws:/home/rango/.aws:ro` (só dev); derrubado
- pedidos ainda no Redis

## Casos reais e exemplos usados (não repetir)
- Verizon/NICE Systems jun/2017 (UpGuard, Vickery, 14 mi vs 6 mi)
- Capital One só referenciado (cap. 9)
- 340 fotos × 4 MB = 1,3 GB ≈ 3 centavos/mês

## Promessas feitas
- ponte: fotos saíram; Postgres na EC2 precisa de backup.sh, patch PG 17, disco enchendo de madrugada; pedidos no Redis → RDS com PITR, réplica outra AZ, subnets privadas (cap. 12)
- CloudFront + OAC, origem CORS do domínio: cap. 14; KMS: cap. 16; tráfego de saída: cap. 24
