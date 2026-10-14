# Resumo 01 — Do notebook para o mundo

## Conceitos explicados (não reexplicar depois)
- livro: Parte I conceitos sem AWS, Parte II AWS; Rangô apresentado (pedidos de comida, FastAPI + React/Vite + PostgreSQL)
- localhost/127.0.0.1: loopback, nunca sai da máquina
- IP: identifica interface; IPv4 32 bits, ~4,3 bi, esgotado; IPv6 128 bits citado
- porta: escolhe processo; analogia prédio/apartamento e IP→servidor, porta→processo, path→função FastAPI; portas padrão 80/443/22/5432; <1024 privilegiadas (volta cap. 3); "Address already in use"
- 127.0.0.1 vs 0.0.0.0 (todas interfaces) no bind
- TCP: three-way handshake SYN/SYN-ACK/ACK, ordem, reenvio; RST = connection refused
- UDP: sem handshake; DNS, vídeo, HTTP/3 sobre QUIC
- roteamento: salto a salto, tabela de rotas, gateway padrão, longest prefix match (analogia rotas FastAPI mais específicas), 0.0.0.0/0 = catch-all
- IP privado (RFC 1918: 10/8, 172.16/12, 192.168/16) vs público
- NAT: tabela tipo dicionário Python; bloqueia conexão de entrada não solicitada; port forwarding
- CGNAT: 100.64.0.0/10, comum no Brasil
- CIDR: bits fixos; /32=1, /28=16, /24=256, /16=65.536, /0=todos; AWS reserva 5 IPs por subnet (251 em /24)
- subnet: bloco que se fala direto; organiza/isola (pública/privada)
- connection refused vs timeout
- IPs de documentação 203.0.113.x, 198.51.100.x (RFC 5737)

## Estado do Rangô ao fim
- só local, sem AWS
- backend/app/main.py: GET /health, GET /restaurantes (lista fixa em memória: Cantina da Nona, Sabor do Sertão); CORS via env `CORS_ORIGINS`
- frontend/src/App.tsx: `VITE_API_URL` (fallback localhost:8000), `.env.local`
- portas: 8000 Uvicorn, 5173 Vite, 5432 Postgres local
- testado no celular via LAN com `--host 0.0.0.0` / `npm run dev -- --host`

## Casos reais e exemplos usados (não repetir)
- sócia em Recife, link localhost:5173
- bug localhost no fetch do React rodando no celular
- ataques de resgate MongoDB jan/2017 (>27 mil bancos)
- comandos: ipconfig getifaddr, ip addr, curl checkip.amazonaws.com, lsof, nc -zv, netstat -rn/ip route, traceroute, módulo ipaddress

## Promessas feitas
- ponte: cliente digita `rango.com.br` e vê cadeado; como nome vira IP e quem garante que site é seu → DNS e TLS (cap. 2)
- servidor com IP público ligado sempre: cap. 9
- banco exposto na internet, subnets privadas, escolha de faixas: cap. 10
- proxy reverso/portas privilegiadas: cap. 3
- acessar servidores sem depender do IP de casa: Parte II
