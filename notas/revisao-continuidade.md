# Revisão de continuidade do manuscrito

Rascunho para o autor revisar. As correções da seção 1 foram aplicadas depois; ver a seção 0.

**Como foi feito.** Li `CLAUDE.md`, `instrucoes/livro.md`, `instrucoes/resumos.md` e `instrucoes/estrutura-do-capitulo.md`, os 24 resumos e as últimas linhas dos 24 `logs/NN-*.escrita.log`. Para cada capítulo, li a recapitulação inicial e comparei com o resumo do capítulo anterior. Também extraí todas as referências para capítulos futuros ("no capítulo X") e conferi cada uma contra o resumo do capítulo citado. Fiz buscas dirigidas por rota, data, versão, nome de recurso e promessa.

**Limites.** Não li os 24 capítulos de ponta a ponta. Não executei nenhum comando nem código. A checagem dos trechos de código CDK entre capítulos foi feita só pelos resumos. Itens marcados *(verificar)* são suspeitas que dependem de ler o trecho completo.

Referências de linha (`L123`) são do arquivo em `capitulos/` no momento da revisão.

---

## 0. Status das correções (15/out/2026)

Rascunho aplicado nos capítulos, pendente de revisão do autor. Nenhum comando ou código foi executado.

| Item | Decisão | O que mudou |
|---|---|---|
| A | Criar login no cap. 20 | Cap. 20: seção "O painel do restaurante ganha um login" (`TabelaPainel` no DynamoDB, Argon2 via `argon2-cffi`, sessão com SHA-256 do token e TTL 8 h, `POST /painel/entrar`, `restaurante_logado`, 403 para outro restaurante); cadastro por `put-item` e curls com `Authorization: Bearer`. Cap. 22 nomeia a rota; cap. 23 cita o cap. 20 e descreve o que o painel expõe. **Código de autenticação: revisão de segurança obrigatória.** Auth do entregador continua pendente. |
| B | Data calculada + fechar o especial | Cap. 13: `SABADO`/`INICIO`/`FIM` calculados com GNU date (nota para macOS); `--force-delete` coerente. Cap. 14: recria as ações agendadas, nova seção "Sábado, 21h" (números inventados, coerentes com o cap. 13), desmontagem no domingo. Cap. 15: recapitulação cita o especial. |
| C | Manter Secrets Manager | Cap. 16 explica a regra (padrão Parameter Store, exceção Secrets Manager para rotação gerenciada); cap. 12 remete ao 16; promessas dos caps. 9 e 10 corrigidas. |
| D | — | Cap. 22: `AlarmeDiscoDb` (`FreeStorageSpace` < 2 GiB), contagem de alarmes ajustada (8 + cobrança + burn rate = 10). Cap. 14: promessa do alarme de health check reescrita. Cap. 17 e resumo 17: Fargate Spot remetido ao cap. 24. |
| E | — | Cap. 24: `listar_fotos` lista o bucket (`list_objects_v2`, `s3:ListBucket` restrito a `fotos/*`); registro no Valkey sai. Cap. 11: promessa ajustada. |
| F | Fatura de dezembro | Cap. 24 analisa a fatura de dezembro (4/jan/2027), o primeiro mês inteiro nas contas do cap. 23; números de horas (744), totais (US$ 687,18), datas do NAT (30/nov) e do EBS (26/nov) recalculados. Cap. 23: ponte e origem da homologação. |
| G | — | Cap. 12: Multi-AZ continua recomendada; Rangô começa sem, por custo, e o assunto volta no cap. 24. |
| H | — | Cap. 12: subseção "O Compose na mesma versão do RDS" (`postgres:18-alpine`, volume em `/var/lib/postgresql`, `rango-api:0.7.0`). Cap. 17 cita `0.7.0` desde o cap. 12. *(conferir o caminho do volume na doc da imagem `postgres` 18)* |
| I | — | Cap. 15: uma frase listando as exceções ao "todo exemplo usa CDK". |
| 1.3 | — | Cap. 7: mapa da Parte II completo (DynamoDB, Step Functions, OpenTelemetry, caps. 23 e 24) e Free plan só para caps. 8–9. Cap. 2: recapitulação do celular. Cap. 18: fixar por hash inclui o `ci.yaml` do cap. 6. Cap. 13: aviso da AMI já é uma Armadilha visível. RDS Proxy segue como pendência do cap. 24. |

Não tratado: seção 4 (resumos acima de ~300 palavras).

---

## 1. Inconsistências entre capítulos

Ordenadas por impacto na narrativa. "Decisão" é o que o autor precisa escolher.

### 1.1 Alta prioridade

**A. A rota `POST /painel/entrar` nunca foi criada (cap. 22 → 23 → 24)**
- Cap. 23, L7: "A rota que recebeu as 41 mil respostas 401 é a `POST /painel/entrar`, o login do painel em que a Cantina da Nona e o Sabor do Sertão acompanham os pedidos". Reaparece em L9 ("uma única senha certa abriria o painel de um restaurante"), L140 (`search_string="/painel/entrar"` na regra `LimiteLogin`), L173 e L197 (`curl ... /painel/entrar`).
- Nenhum capítulo anterior cria login, usuário de restaurante, hash de senha ou painel. O resumo 20 registra o oposto: "rotas do entregador SEM autenticação (pendente)". Em `grep` de `painel`, `entrar`, `/login` e `/auth` nos caps. 1–22, só aparecem "painel do restaurante" (cap. 5 L138, cap. 11 L7, cap. 21 L9) e "painel" de dashboard, sem rota de login.
- Cap. 22, L672 só diz "uma rota que pede senha", sem nome. O log do cap. 23 afirma que a rota foi "citada no cap. 22". A citação existe, mas sem o nome da rota.
- Efeito em cascata: a regra de WAF do cap. 23 protege uma rota que não existe no código. O resumo 23 também diz que ela ficou no WAF do ALB (`FirewallApi`).
- O cap. 24 recapitula "um WAF na frente do login" (L3) e lista "auth do entregador" como pendência.
- **Decisão:** (a) criar o login do painel antes (por exemplo, no cap. 12 ou 20, com tabela de usuários e hash de senha), ou (b) reescrever o cap. 22/23 para usar uma rota que existe. Se for (a), considerar também a autenticação das rotas do entregador, que o cap. 20 deixou aberta.

**B. Data fixa 17/out/2026 no cap. 13 e o especial de TV que nunca acontece (cap. 13–15)**
- Cap. 13, L543–555: `20h30 de sábado, 17 de outubro, são 23h30 UTC` e `--start-time 2026-10-17T23:30:00Z` / `2026-10-18T03:30:00Z` nas ações agendadas `especial-tv-inicio/fim`. Se o leitor rodar depois dessa data, o comando falha.
- O mesmo capítulo usa outras datas fixas em exemplos de saída: `2026-10-15T14:28:41Z` (L222), `2026-10-15T18:21:40Z` (L536) e o nome da AMI `rango-api-20261015` (L236, L351, L612).
- Esse nome de AMI se espalha: cap. 14 (L3, L69), cap. 15 (resumo), cap. 16 e cap. 17 (L3). O cap. 17 troca por `rango-api-20261103` (data de uma terça, consistente com o calendário de 2026).
- O mesmo trecho se contradiz. L583 manda apagar o ASG com `--force-delete`, o que, segundo o próprio texto, "apaga também a política, os alarmes que ela criou e as ações agendadas". Isso desfaz o plano do sábado que acabou de ser criado. L583 adverte "se a data do especial ainda não passou ... adie esta seção".
- O cap. 14 (L7) começa numa "quinta-feira, 15h" com a produtora ainda perguntando o endereço do especial de sábado. Termina com tudo destruído. O cap. 15 abre numa segunda-feira com a homologação do Bruno. O especial de TV nunca é narrado (nem sucesso nem falha), apesar de ser o gancho desde o cap. 4.
- Linha do tempo comprimida: cap. 10 usa log de `2026-10-14` (L~20); caps. 11–13 caem em 14–15/out. Datas conferidas como coerentes com o dia da semana: 17/out/2026 sábado, 3/nov terça, 16/nov segunda, 3/dez quinta.
- **Decisão:** trocar a data fixa por variável (`$(date -u -d ...)`) ou por placeholder; decidir se o AMI usa data real ou sufixo de versão; fechar a história do especial (um parágrafo no cap. 14 ou 15 bastaria).

**C. Senha mestre do RDS no Secrets Manager (cap. 12) vs política da IPC Global**
- Cap. 12, L240: `--manage-master-user-password` guarda a senha mestre no Secrets Manager. Log do cap. 12: "A IPC Global prefere o Parameter Store: decidir se mantém."
- A decisão não afeta só o cap. 12. O cap. 16 constrói o resto da arquitetura sobre o Secrets Manager: L74 ("a senha mestre do `rango_admin` foi para o Secrets Manager"), L99 (regra do Rangô: "Credencial que dá para girar vai para o Secrets Manager"), `DatabaseSecret` com rotação multi-usuário (resumo 16), e o cap. 17 injeta via `valueFrom`.
- O cap. 19 também cria `SegredoWebhook` (Secrets Manager, com CMK) para o HMAC do webhook.
- Promessas que não batem com o cap. 16:
  - Cap. 10, L450: "o capítulo 16 vai levá-la [a senha] para o Parameter Store".
  - Cap. 9, L100: "Segredos vão para o Parameter Store, assunto do capítulo 16".
  - O resumo 9 repete essa promessa.
  - O cap. 16 leva a senha para o Secrets Manager e deixa só configuração no Parameter Store.
- **Decisão:** manter Secrets Manager (justificando a rotação automática como exceção à preferência, e registrando isso no texto) ou reescrever 12/16/17/19 para Parameter Store `SecureString` (perde a rotação nativa, que é o assunto central do cap. 16). Em qualquer caso, alinhar as promessas dos caps. 9 e 10.

### 1.2 Média prioridade

**D. Alarmes prometidos que não aparecem no cap. 22**
- Cap. 12, L45: "o alarme no espaço livre (métrica `FreeStorageSpace`, que veremos no capítulo 22) continua necessário". O cap. 22 só cita a métrica de passagem (L57) e cria `AlarmeConexoesDb`; não há alarme de `FreeStorageSpace`.
- Cap. 14, L520: o health check do Route 53 "publica uma métrica no CloudWatch, e o capítulo 22 monta os alarmes sobre ela". O resumo 22 não lista alarme de health check.
- Resumo 17 promete "Fargate Spot nos workers" para o cap. 21. O cap. 21 removeu os workers; Fargate Spot só chega no cap. 24, para homologação.

**E. Registro de fotos no Valkey/Redis (cap. 11 → 24)**
- Resumo 11: `POST /fotos` grava num Redis set `fotos:{r}`. Cap. 24, L331 ainda lê `r.smembers(f"fotos:{restaurante}")`.
- O cache é o ElastiCache Serverless, destruído com a stack em cada capítulo, e o cap. 23 migra as fotos com `sync`. Isso cria um problema: os pedidos saíram do Redis no cap. 12, mas o cadastro de fotos, que é dado durável, ficou lá. *(verificar se algum capítulo trata disso)*.

**F. Homologação aparece pronta no cap. 24 sem ter sido criada com custo mensal plausível**
- Cap. 15 (L11, L163, L734) e cap. 16 (L286) falam de uma segunda chamada a `RangoInfraStack` com `ambiente="homologacao"`, mas os caps. 17–22 terminam cada um com `cdk destroy RangoProducao` e nunca dizem o que acontece com a homologação.
- A conta `rango-homologacao` (345678901234) só é criada no cap. 23 (L251). Mesmo assim, o cap. 24 (L84) cobra US$ 226,48 de homologação em novembro, "quase o mesmo que a produção em VPC, load balancer, Fargate e WAF", e US$ 431,10 de produção, como se ambas rodassem o mês inteiro. A produção só migra para `rango-producao` no cap. 23 (16/nov em diante). *(verificar a aritmética do mês)*.
- O Diego (cap. 23, L64: "entrou na equipe há duas semanas") é personagem novo. É o único; não há problema, só fica registrado.

**G. Multi-AZ recomendada, depois ausente**
- Cap. 12, L75: Multi-AZ DB instance "é o ponto de partida razoável" para produção. Cap. 13, L134 cria com `--no-multi-az`. A stack do cap. 15 não tem Multi-AZ (resumo 15). Cap. 24, L476 trata como "buraco de confiabilidade" a resolver depois. Pode ser intencional, mas a recomendação do cap. 12 e o resultado final divergem. O resumo 24 lista como pendência: Multi-AZ, RDS Proxy, auth do entregador, WAF Count→Block.

**H. Imagem local e Postgres local desatualizados (cap. 11/12 → 17)**
- Cap. 12, L664 (só como "Dica"): trocar `postgres:17-alpine` por `postgres:18-alpine` no Compose. Resumo 12 registra "pendente: Compose → postgres:18-alpine". Nenhum capítulo seguinte confirma a troca. O cap. 6 e o cap. 10 ainda falam em PG 17.
- Cap. 17 (abertura) diz que a imagem local é `rango-api:0.6.0` "desde o capítulo 11". O cap. 12 mudou o código (`banco.py`, `psycopg`) sem subir a versão da tag, segundo os resumos. *(verificar)*.

**I. Promessa "a partir do cap. 15, todo exemplo usa CDK" vs passos feitos à mão**
- `instrucoes/livro.md` e o cap. 15 prometem CDK para tudo. Exceções confirmadas pelos resumos: SLO e Transaction Search no console (cap. 22), Security Hub no console (cap. 23), policy manual do bucket de fotos para o behavior `/fotos/*` (cap. 24), variável `AWS_ACCOUNT_ID` do GitHub (cap. 18). O cap. 21 faz "drift proposital" para demonstrar recusa. Não são erros, mas vale uma frase explicando.

### 1.3 Baixa prioridade

- **Cap. 7, mapa da Parte II (L38–52):** a tabela não lista DynamoDB (20), Step Functions (21), segurança (23) nem custos (24), e cita X-Ray no cap. 22, que o próprio cap. 22 trata como em fim de suporte (SDK/Daemon até 25/02/2027, migração para OpenTelemetry).
- **Cap. 7, L143:** "Os capítulos 8 a 11 cabem bem [no Free plan]". O cap. 10 usa NAT Gateway e interface endpoints e o cap. 12 usa RDS. *(verificar se cabem no Free plan)*.
- **Cap. 2, recapitulação (L3):** "o Rangô rodava no seu celular, pela rede de casa". O resumo 1 e o cap. 1 mostram a API no notebook e o celular só como cliente na LAN. Redação imprecisa, não factual.
- **Cap. 6:** o CI usa `actions/checkout@v5` e `setup-python@v6`; o cap. 18 recomenda fixar actions por SHA (`tj-actions`) sem voltar ao cap. 6.
- **Cap. 13 (log):** a AMI leva o `api.env` com `PGPASSWORD` até o cap. 16 resolver. É proposital e está dito, mas o texto do cap. 13 só avisa em L249; confirmar que o aviso está visível.
- **Cap. 22/23:** o resumo 22 deixa "conexões do Postgres esgotadas sem correção definitiva". O cap. 24 só nomeia o RDS Proxy como pendência futura.

---

## 2. Recapitulações conferidas contra o resumo anterior

| Cap. | Resultado |
|---|---|
| 2 | Coerente com o resumo 1. Só a redação sobre o "celular" (1.3). |
| 3 | Coerente com o resumo 2 (`rango.test`, mkcert). |
| 4 | Coerente com o resumo 3 (`rango-api:0.1.1`, Nginx com TLS, três réplicas no kind). |
| 5 | Coerente com o resumo 4. A promessa de idempotência foi cumprida. |
| 6 | Coerente com o resumo 5 (stream Redis, DLQ, 2,5 s). |
| 7 | Coerente com o resumo 6 (lista de pendências, "onde e como"). |
| 8 | Coerente com o resumo 7 (`Unable to locate credentials`, alarme de US$ 10, MFA em dois dispositivos). |
| 9 | Coerente com o resumo 8 (`dev-rango`, `rango-ec2`, profiles). |
| 10 | Coerente com o resumo 9. |
| 11 | Coerente com o resumo 10 (gateway endpoint do S3 mantido). |
| 12 | Coerente com o resumo 11 (bucket `rango-fotos-pratos-<conta>`, presigned). |
| 13 | Coerente com o resumo 12 (snapshot `rango-db-final-cap12`, ElastiCache apagado). |
| 14 | Coerente com o resumo 13 (AMI, LT, SGs, snapshot cap13). |
| 15 | Coerente com o resumo 14 (zona, certificado, distribuição, snapshot cap14). |
| 16 | Coerente com o resumo 15 (stack `RangoProducao`, snapshot placeholder). |
| 17 | Coerente com o resumo 16 (Parameter Store, Secrets Manager, KMS, AMI com senha morta). |
| 18 | Coerente com o resumo 17 (`RangoRegistro` mantida, três serviços Fargate). |
| 19 | Coerente com o resumo 18 (OIDC, blue/green, workflows desabilitados). |
| 20 | Coerente com o resumo 19 (Lambdas e HTTP API). |
| 21 | Coerente com o resumo 20 (DynamoDB, Streams). |
| 22 | Coerente com o resumo 21 (máquina de estados, dez lugares de falha). |
| 23 | Coerente com o resumo 22, exceto a rota de login (1.1.A). |
| 24 | Coerente com o resumo 23; "WAF na frente do login" herda 1.1.A. |

Forward references (todas as menções "capítulo N" onde N é posterior ao atual, ~170 ocorrências) conferidas contra os resumos: as não cumpridas estão em 1.1.C e 1.2.D.

---

## 3. Pendências deixadas por cada capítulo (últimas linhas dos `logs/NN-*.escrita.log`)

| Cap. | Pendências registradas pelo próprio capítulo |
|---|---|
| 01 | Conferir links das RFCs, a saída de `lsof`/`nc` e o caso MongoDB 2017 (The Register, SiliconANGLE). |
| 02 | Confirmar `allowedHosts` do Vite e os prazos do CA/B Forum (escritos de memória, sem busca). Saídas do `dig` com `rango.com.br` são ilustrativas. |
| 03 | Rodar os exemplos de Docker, Compose e kind. Validar links do Codecov e da Fortune (Tesla), confirmados só por busca. |
| 04 | Comandos Docker/Nginx/Redis não rodados; saídas estimadas. Confirmar o link InfoQ do Prime Video. |
| 05 | Rodar o mão na massa (timings e saída de `XPENDING` foram estimados). Conferir se `docker compose kill` evita o restart automático com `unless-stopped`. |
| 06 | Conferir links da GitLab e da SEC e as versões `actions/checkout@v5` / `setup-python@v6`. Nenhum comando ou link foi executado ou aberto. |
| 07 | Conferir telas atuais do console (MFA, Budgets) e a saída de `describe-availability-zones` em `sa-east-1`. Incidente DynamoDB de 19–20/out/2025 como caso real novo. |
| 08 | Passos de console do Identity Center e saída do `aws configure sso` vêm da memória; nada foi testado numa conta real. |
| 09 | Conferir numa instância real `dnf install nginx`, `python3.12 -m venv`, `default_server` do Nginx, versões de exemplo (Python 3.12.12, nginx 1.28.0) e o texto do erro `PassRole`. Validar links Capital One e IMDSv2. Preço/hora da t3.micro ficou de fora. |
| 10 | Comandos AWS não testados. Confirmar o pacote `postgresql17-server` no AL2023 (fonte só de terceiros) e se `ec2messages` ainda é exigido pelo SSM. |
| 11 | Preços do S3 vêm de levantamento de terceiros (conferir na página oficial). Limite de 5 GB por PUT só em fontes secundárias. Código é rascunho, nada executado. |
| 12 | Conferir na doc: gatilhos do storage autoscaling, fórmula do `max_connections`, `--manage-master-user-password`. Decidir se mantém a senha mestre no Secrets Manager (ver 1.1.C). |
| 13 | Capítulo no teto de 5.000 palavras. AMI leva `api.env` com senha até o cap. 16. Data do especial (17/out/2026) fixa no texto (ver 1.1.B). Comandos AWS não executados; saídas são exemplos. |
| 14 | Conferir ao vivo `CustomErrorResponses` 403/404 (sem fonte oficial), se o Registro.br testa os NS antes da troca e o CN da CA intermediária. |
| 15 | Não verificados: nomes das classes `CfnServerlessCache.*Property` e `ListenerCertificate.from_certificate_manager`, cascata do *Delete VPC* no console, saídas de `cdk diff`/drift. Só `HealthChecks.with_additional_checks` foi confirmado na doc. Considerar declarar uso de IA. |
| 16 | Nome do snapshot no `app.py` é placeholder. Testar de verdade a 2ª rotação e o instance refresh. |
| 17 | Validar com `cdk synth` a sintaxe de `ApplicationLoadBalancedFargateService` e `Secret.from_secrets_manager(field=)`. Mensagem `ResourceInitializationError` e saída `x-rango-instancia` vieram da memória. |
| 18 | Blue/green em CDK Python (regras com pesos, regra de teste por cabeçalho no mesmo listener) e OIDC não testados. Confirmar formato do `sub` do repositório e regras de environment do plano GitHub. A parte de IAM/OIDC precisa de revisão de segurança. |
| 19 | Conferir preços da Lambda na página oficial. Webhook HMAC precisa de revisão de segurança. |
| 20 | Rotas do entregador sem autenticação (aviso no texto; precisa de revisão de segurança). CDK e código não executados. |
| 21 | Código e CDK não executados. Conferir o caso Kinesis (25/nov/2020) e a dependência circular do `grant_task_response`. |
| 22 | Conferir no console a criação do SLO e as telas do Transaction Search. Conferir se o formato JSON da Lambda põe os campos `extra` no nível de cima e deixa o `print` (EMF) intacto. Conferir se o trace segue da API para o Step Functions e se `aws-opentelemetry-distro` traz as instrumentações sem `opentelemetry-bootstrap`. Falta de conexões no Postgres sem correção definitiva. |
| 23 | Confirmar `POST /painel/entrar` (ver 1.1.A). Conferir na documentação: AWS Backup (cópia entre contas, Vault Lock), janela e limite mínimo da regra de taxa do WAF, comandos de root centralizado. |
| 24 | Conferir o preço do interface endpoint (US$ 0,01/h, não confirmado nas notas) e os nomes de usage type (ilustrativos) nas saídas do Cost Explorer. Pode exigir aviso de uso de IA. |

Pendências transversais, não repetidas por cap.:
- **Teste real.** Nenhum comando nem código foi executado em nenhum capítulo. As saídas mostradas são estimadas ou ilustrativas.
- **Revisão de segurança.** Recomendada para o código de autenticação, autorização, HMAC, OIDC e IAM (caps. 8, 9, 18, 19, 20, 23).
- **Dados de cliente.** Nada nos exemplos usa dados reais; IDs de conta e IPs são fictícios (RFC 5737).
- **Aviso de uso de IA.** Os logs dos caps. 15 e 24 já lembram que a publicação externa pode exigir declarar assistência de IA (política da IPC Global).

---

## 4. Resumos acima de ~300 palavras

`instrucoes/resumos.md` fixa "máximo de ~300 palavras". Contagem por `split()` (palavras separadas por espaço) e por tokens alfanuméricos (ignora hífens e símbolos soltos):

| Resumo | split() | alfanum. | Excesso sobre 300 (split) |
|---|---|---|---|
| 01 | 371 | 409 | +71 |
| 02 | 394 | 431 | +94 |
| 03 | 414 | 458 | +114 |
| 04 | 432 | 451 | +132 |
| 05 | 372 | 395 | +72 |
| 06 | 375 | 412 | +75 |
| 07 | 410 | 426 | +110 |
| 08 | 377 | 401 | +77 |
| 09 | 436 | 484 | +136 |
| 10 | 381 | 461 | +81 |
| 11 | 379 | 416 | +79 |
| 12 | 413 | 466 | +113 |
| 13 | 345 | 384 | +45 |
| 14 | 345 | 410 | +45 |
| 15 | 377 | 424 | +77 |
| 16 | 345 | 374 | +45 |
| 17 | 396 | 408 | +96 |
| 18 | 404 | 430 | +104 |
| 19 | 393 | 425 | +93 |
| 20 | 370 | 400 | +70 |
| 21 | 378 | 419 | +78 |
| 22 | 374 | 413 | +74 |
| 23 | 387 | 419 | +87 |
| 24 | 357 | 391 | +57 |

**Os 24 resumos passam de 300 palavras**, não só o 01 e o 04. Os maiores são 09 (436), 04 (432) e 03 (414); o menor excesso é +45 (13, 14, 16). Os logs dos caps. 1 e 4 já registram o estouro. Nenhum dos demais logs menciona.

Os resumos mais longos são também os que mais carregam o estado de infraestrutura (09, 12, 18). Se o limite for aplicado, são os melhores candidatos a cortar "Casos reais" e comandos listados.

**Tamanho dos capítulos** (3.000–5.000 palavras, sem código): todos dentro do limite. Sem código e sem a seção Referências, ficam entre 4.755 (cap. 22) e 4.962 (cap. 7). Incluindo Referências, o cap. 7 chega a 5.058 e outros oito passam de 5.040, sem ser problema se a regra contar só o corpo.
