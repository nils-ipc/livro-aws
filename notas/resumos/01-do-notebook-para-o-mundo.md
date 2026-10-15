# Resumo 01 — Do notebook para o mundo

## Conceitos explicados (não reexplicar depois)
- livro: Parte I conceitos sem AWS, Parte II (cap. 7+) AWS; Rangô apresentado (pedidos de comida, FastAPI + React/Vite + PostgreSQL local)
- FastAPI apresentado brevemente (parecido com Flask, tipos, async); Uvicorn = servidor ASGI
- localhost/127.0.0.1/::1: loopback, nunca sai da máquina; cada máquina tem o seu
- IP: identifica interface; IPv4 32 bits, ~4,3 bi, esgotado; IPv6 128 bits
- porta: prédio/apartamento; IP→máquina, porta→processo, path→função; <1024 privilegiadas
- bind 127.0.0.1 vs 0.0.0.0
- TCP: handshake SYN/SYN-ACK/ACK; RST = recusada; recusada vs timeout
- UDP: sem handshake; DNS, HTTP/3/QUIC
- roteamento salto a salto, gateway padrão, longest prefix match (analogia rotas FastAPI), 0.0.0.0/0
- IP privado RFC 1918 (10/8, 172.16/12, 192.168/16) vs público
- NAT: tabela tipo dicionário Python, analogia portaria; barra entrada não solicitada; port forwarding
- CGNAT: 100.64.0.0/10, comum no Brasil
- CIDR: bits fixos, 2^(32−n); /32=1, /28=16, /24=256, /16=65.536, /0=todos; AWS reserva 5 IPs/subnet (251 em /24)
- subnet: máquinas que se falam direto; pública vs privada
- IPs documentação 203.0.113.x, 198.51.100.x (RFC 5737), usados no livro todo

## Estado do Rangô ao fim
- só local, sem AWS
- backend/app/main.py: GET /health, GET /restaurantes (lista em memória: Cantina da Nona, Sabor do Sertão); CORS via env `CORS_ORIGINS`
- frontend/src/App.tsx: `VITE_API_URL` (fallback localhost:8000); `frontend/.env.local`
- portas: 8000 Uvicorn, 5173 Vite, 5432 Postgres
- testado no celular via LAN: `uvicorn --host 0.0.0.0`, `npm run dev -- --host`

## Casos reais e exemplos usados (não repetir)
- sócia em Recife recebe link localhost:5173, depois 192.168.0.12 (timeout)
- bug localhost no fetch do React no celular
- ataques de resgate MongoDB jan/2017 (>27 mil bancos)
- Docker `-p` fura ufw; faixas colidindo com VPN
- comandos: lsof, nc -zv, ip route, traceroute, checkip.amazonaws.com, ipaddress

## Promessas feitas
- ponte: sócia teria de digitar `http://203.0.113.45:5173`; quer `rango.com.br` com cadeado; como nome vira IP e quem garante que site é seu → DNS e TLS (cap. 2)
- proxy reverso/portas privilegiadas: cap. 3; containers: cap. 3
- máquina com IP público ligada sempre: Parte II (cap. 9)
- distância até região AWS importa: Parte II
- faixas sem sobreposição, subnets na AWS, 5 IPs reservados: cap. 10
