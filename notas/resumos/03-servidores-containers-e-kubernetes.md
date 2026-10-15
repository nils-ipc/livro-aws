# Resumo 03 — Servidores, containers e Kubernetes

## Conceitos explicados (não reexplicar depois)
- servidor: computador em data center; bare metal vs VM; hypervisor fatia máquina física (VirtualBox citado); EC2 prometido cap. 9
- Linux: kernel vs distribuição; apt/dnf (pip do sistema); Ubuntu 24.04 = Python 3.12, 22.04 = 3.10; /etc, /var/log, /opt, /srv, /home
- root, sudo, portas <1024 exigem root ou CAP_NET_BIND_SERVICE; app com usuário sem privilégio em porta alta
- sinais: tabela SIGTERM, SIGKILL, SIGHUP (SSH fechado mata Uvicorn), SIGINT; nohup/tmux insuficientes
- systemd: PID 1, unit `rango-api.service` (User=rango, EnvironmentFile=/etc/rango/api.env, --host 127.0.0.1, Restart=on-failure), systemctl enable --now, journalctl -u
- proxy reverso Nginx: analogia middleware em processo separado; termina TLS, roteia por Host, estáticos, try_files SPA, clientes lentos; master root + workers www-data; X-Forwarded-*, Uvicorn confia só em 127.0.0.1; Certbot renova
- container: processo isolado; namespaces (o que vê) + cgroups (quanto consome); kernel compartilhado; diagrama ASCII VM vs container; Docker Desktop usa VM Linux
- imagem (classe) vs container (instância); camadas ≈ commits git; registry ≈ PyPI; Docker Hub; OCI; ECR prometido cap. 17
- orquestrador: estado desejado + reconciliação, analogia React
- Kubernetes: cluster, nós, control plane, kubectl; pod, deployment (rolling update), service (nome estável); Ingress/ConfigMap/Secret só citados
- quando não usar K8s

## Estado do Rangô ao fim
- só local, sem AWS
- main.py: campo `taxa_entrega` (6.9, 4.5) + `taxa_entrega_fmt` via `formatar_reais()` (bug locale.setlocale pt_BR removido)
- backend/requirements.txt (pip freeze), backend/Dockerfile (python:3.12-slim, USER rango, CMD exec form, 0.0.0.0:8000), backend/.dockerignore
- imagem `rango-api:0.1.1`
- raiz: compose.yaml (api sem portas + proxy nginx:1.27-alpine em 127.0.0.1:8443:443, certs/ montado :ro), nginx/rango.conf
- Uvicorn sem --ssl; TLS no Nginx
- frontend/.env.local: `VITE_API_URL=https://api.rango.test:8443`
- k8s/api.yaml (Deployment 3 réplicas, readinessProbe /health, resources; Service 80→8000); cluster kind `rango` criado e apagado

## Casos reais e exemplos usados (não repetir)
- deploy sexta 19h, IP 203.0.113.45, locale.Error: unsupported locale setting
- Codecov abr/2021 (credencial extraída de imagem Docker)
- Tesla/RedLock fev/2018 (console K8s sem senha, mineração)
- armadilhas: latest, segredos em camadas, dados no container, arm64 vs amd64 exec format error, CMD shell form, slim vs Alpine

## Promessas feitas
- ponte: Rangô na TV (programa de culinária mostra Cantina da Nona na quinta), tráfego ×50, CPU 100%, 80 ms → 12 s; um servidor só não aguenta; maior ou vários? como chegar ao menos ocupado? pedido no meio quando servidor cai → cap. 4
- health checks: cap. 4; estratégias de deploy: cap. 6; segredos: cap. 16; S3 para fotos: cap. 11; ECS/Fargate/EKS: cap. 17
