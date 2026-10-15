# Resumo 02 — DNS, HTTPS e TLS

## Conceitos explicados (não reexplicar depois)
- DNS: agenda de contatos; hierarquia raiz → br → com.br → rango; delegação ("não sei, mas sei quem sabe")
- resolver recursivo (provedor, 1.1.1.1, 8.8.8.8) vs servidor autoritativo; zona = tabela de registros
- raiz: 13 nomes a–m.root-servers.net, anycast, >1.000 instâncias; DNS UDP 53, TCP fallback
- TTL: analogia `max_age` de decorator de cache; "propagação" = cache antigo expirando; cache negativo (SOA)
- registros A, AAAA, CNAME (alias de import), MX, TXT (prova de posse), NS; CNAME proibido no apex (solução AWS no cap. 14)
- Registro.br publica NS; registrador ≠ provedor DNS; zona do Rangô irá para Route 53
- HTTP em texto; cabeçalho Host, virtual hosting; HTTP/2 e /3 só mudam transporte
- TLS: sigilo, integridade, autenticação; troca de chaves ECDHE; man-in-the-middle
- certificado, CA, root store (analogia cartório), intermediários, cadeia, SAN, curinga cobre 1 nível
- validação DV por desafio HTTP ou DNS TXT; Let's Encrypt/ACME/Certbot; ACM citado
- validade: LE 90 dias; CA/B Forum 2025: 200 d (mar/2026), 100 d (mar/2027), 47 d (mar/2029)
- handshake TLS 1.3 (1 RTT; 1.2 = 2), diagrama ASCII; SNI visível
- CDN: borda/PoP, origem, hit/miss, TLS na borda; Cache-Control: assets com hash `max-age=31536000, immutable`, index.html `no-cache`; `no-store` dados pessoais
- mixed content; HSTS difícil de desfazer

## Estado do Rangô ao fim
- só local, sem AWS
- hosts: `rango.test`, `api.rango.test` → 127.0.0.1 (.test RFC 6761)
- `certs/` na raiz (gitignored): `rango.test+1.pem`, `rango.test+1-key.pem` via mkcert; autoassinado testado e apagado
- API: `uvicorn ... --ssl-keyfile/--ssl-certfile`, `CORS_ORIGINS="https://rango.test:5173"`
- `frontend/vite.config.ts`: host 127.0.0.1, allowedHosts ["rango.test"], server.https
- `frontend/.env.local`: `VITE_API_URL=https://api.rango.test:8000`
- celular na LAN deixou de funcionar (sem hosts/CA)

## Casos reais e exemplos usados (não repetir)
- Wi-Fi da praça de alimentação; dono da Cantina da Nona e o folheto
- Facebook 4/out/2021 (~6 h, DNS inalcançável)
- DST Root CA X3 expirou 30/set/2021
- TTL 86400 na migração de sexta (hipotético); certificado vencido manual
- requests/httpx usam certifi; rootCA-key.pem do mkcert
- comandos: dig, dig +trace, dig @, curl -v, openssl req, openssl s_client | x509

## Promessas feitas
- ponte: falta o servidor; quem roda Uvicorn após reboot, porta 443 sem rodar como admin, certificado/renovação; erro 500 "na minha máquina funciona" → servidor por dentro, proxy reverso, containers (cap. 3)
- Route 53, alias no apex, ACM, CloudFront: cap. 14
