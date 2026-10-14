#!/usr/bin/env bash
#
# Escreve os capítulos do livro, um por vez, chamando o Claude Code em modo
# não interativo. Para cada capítulo:
#   1. Pesquisa (sessão separada, só Parte II): confere os pontos arriscados
#      e salva notas curtas em notas/pesquisa/.
#   2. Escrita: escreve o capítulo, faz uma checagem mecânica (grep de marcas
#      de IA e contagem de palavras) e salva um resumo em notas/resumos/.
#
# Uso:
#   ./escrever-livro.sh              # escreve todos os capítulos que ainda não existem
#   INICIO=7 ./escrever-livro.sh     # começa a partir do capítulo 07
#   FIM=6 ./escrever-livro.sh        # para no capítulo 06
#   REESCREVER=1 ./escrever-livro.sh # reescreve mesmo se o capítulo já existir (reaproveita a pesquisa)
#   REPESQUISAR=1 ./escrever-livro.sh  # refaz também a pesquisa
#   PESQUISA_A_PARTIR=1 ./escrever-livro.sh  # pesquisa também a Parte I (padrão: só a partir do 07)
#   MODELO=opus MODELO_PESQUISA=sonnet ESFORCO=medium ./escrever-livro.sh

set -euo pipefail

cd "$(dirname "$0")"

INICIO="${INICIO:-1}"
FIM="${FIM:-24}"
REESCREVER="${REESCREVER:-0}"
REPESQUISAR="${REPESQUISAR:-0}"
MODELO="${MODELO:-opus}"
MODELO_PESQUISA="${MODELO_PESQUISA:-sonnet}"
ESFORCO="${ESFORCO:-medium}"
PESQUISA_A_PARTIR="${PESQUISA_A_PARTIR:-7}"

CAPITULOS=(
  01-do-notebook-para-o-mundo
  02-dns-https-e-tls
  03-servidores-containers-e-kubernetes
  04-arquitetura-que-escala
  05-filas-eventos-e-sistemas-distribuidos
  06-producao-de-verdade
  07-bem-vindo-a-aws
  08-iam-quem-pode-fazer-o-que
  09-ec2-seu-primeiro-servidor
  10-vpc-a-rede-na-aws
  11-s3-armazenamento-de-objetos
  12-rds-banco-de-dados-gerenciado
  13-load-balancer-e-auto-scaling
  14-route-53-cloudfront-e-certificados
  15-infraestrutura-como-codigo-com-cdk
  16-segredos-e-criptografia
  17-containers-com-ecr-ecs-e-fargate
  18-ci-cd-na-aws
  19-serverless-com-lambda-e-api-gateway
  20-dynamodb
  21-sqs-sns-eventbridge-e-step-functions
  22-observabilidade-com-cloudwatch
  23-seguranca-em-producao
  24-custos-e-arquitetura
)

# Opções comuns: sem plugins/hooks/configurações do usuário (só as do projeto),
# sem servidores MCP, sem skills, esforço reduzido.
OPCOES_COMUNS=(
  --setting-sources project
  --strict-mcp-config
  --disable-slash-commands
  --effort "$ESFORCO"
  --output-format text
)

FERRAMENTAS_PESQUISA="Read,Write,Glob,WebSearch,WebFetch"
FERRAMENTAS_ESCRITA="Read,Write,Edit,Glob,Grep,WebSearch,WebFetch,Bash"
PERMISSOES_ESCRITA="Read,Write,Edit,Glob,Grep,WebSearch,WebFetch,Bash(wc:*),Bash(sed:*),Bash(grep:*),Bash(ls:*)"

mkdir -p capitulos notas/pesquisa notas/resumos logs

# Conta palavras excluindo blocos de código.
contar_palavras() {
  sed '/^```/,/^```/d' "$1" | wc -w | tr -d ' '
}

# ---------------------------------------------------------------------------
# Prompt da pesquisa
# ---------------------------------------------------------------------------
read -r -d '' PROMPT_PESQUISA <<'EOF' || true
Tarefa: conferir na internet os pontos arriscados do capítulo __NUM__ do livro e salvar notas curtas em `notas/pesquisa/__ARQUIVO__.md`. Não escreva o capítulo. Não crie nem altere nenhum outro arquivo.

1. Leia `instrucoes/livro.md` (público e as linhas do capítulo __NUM__, do anterior e do próximo no sumário) e `instrucoes/pesquisa.md`.
2. Liste para si o que o capítulo vai afirmar e escolha só o que tem risco de erro: o que pode ter mudado recentemente, números exatos (preços, limites, cotas), pontos com nuance, sintaxe que você não sabe de cor com segurança, detalhes dos casos reais. Não pesquise conceito estável que você domina.
3. Pesquise só isso: no máximo 6 buscas e 3 páginas lidas.
4. Salve as notas no formato de `instrucoes/pesquisa.md`: 15 a 40 itens, telegráfico, URL em cada item, números e comandos exatos.

Responda apenas: "ok" e o número de itens salvos.
EOF

# ---------------------------------------------------------------------------
# Prompt da escrita
# ---------------------------------------------------------------------------
read -r -d '' PROMPT_ESCRITA <<'EOF' || true
Tarefa: escrever o capítulo __NUM__ do livro em `capitulos/__ARQUIVO__.md`. Escreva apenas este capítulo. Além dele, só crie `notas/resumos/__ARQUIVO__.md`.

## Etapa 1: contexto

Leia:
- `instrucoes/livro.md`, `instrucoes/estrutura-do-capitulo.md`, `instrucoes/estilo.md`, `instrucoes/rigor-e-formatacao.md` e `instrucoes/resumos.md`.
__NOTAS__
- Todos os resumos de capítulos anteriores em `notas/resumos/`. Eles dizem o que já foi explicado, o estado do Rangô e o que o capítulo anterior prometeu na ponte. Não leia os capítulos anteriores inteiros. Se precisar conferir um detalhe pontual, use Grep neles.

## Etapa 2: escrita

Escreva o capítulo completo com Write, de uma vez, com 3.000 a 5.000 palavras sem contar blocos de código. A recapitulação precisa bater com o resumo do capítulo anterior, e o Rangô começa no estado em que ele terminou. Cumpra a promessa da ponte anterior. Escreva com o seu conhecimento. Onde houver notas de pesquisa, elas prevalecem; o que estiver em "Não confirmado" não entra como fato. Se surgir dúvida real sobre um número, versão, comportamento recente ou caso real, faça no máximo 3 buscas. Caso real só com detalhes de que você tenha certeza; na dúvida, use cenário hipotético e diga que é hipotético. Confira a contagem:

    sed '/^```/,/^```/d' capitulos/__ARQUIVO__.md | wc -w

## Etapa 3: checagem mecânica

Sem reler o capítulo inteiro:
1. Rode Grep no capítulo por "—", "não é", "não apenas", "mas também", "não se trata" e pelas palavras e expressões proibidas de `instrucoes/estilo.md`. Corrija com Edit cada ocorrência que caia num padrão proibido.
2. Se a contagem ficou fora de 3.000 a 5.000 palavras, ajuste com Edit. Nunca reescreva o arquivo inteiro.

## Etapa 4: resumo

Salve `notas/resumos/__ARQUIVO__.md` no formato de `instrucoes/resumos.md`, em estilo telegráfico, com no máximo ~300 palavras.

## Resposta final

No máximo 2 linhas, telegráfico: palavras finais; pendências para o autor (ou "nenhuma").
EOF

total="${#CAPITULOS[@]}"

for ((i = INICIO; i <= FIM && i <= total; i++)); do
  num=$(printf '%02d' "$i")
  arquivo="${CAPITULOS[$((i - 1))]}"
  capitulo="capitulos/${arquivo}.md"
  pesquisa="notas/pesquisa/${arquivo}.md"
  resumo="notas/resumos/${arquivo}.md"

  if [[ -f "$capitulo" && "$REESCREVER" != "1" ]]; then
    echo ">> [$num/$total] $capitulo já existe, pulando."
    continue
  fi

  # --- 1. Pesquisa (só a partir de PESQUISA_A_PARTIR) -------------------------
  if ((i < PESQUISA_A_PARTIR)); then
    echo ">> [$num/$total] Parte I: sem pesquisa."
  elif [[ -f "$pesquisa" && "$REPESQUISAR" != "1" ]]; then
    echo ">> [$num/$total] Pesquisa já existe ($pesquisa), reaproveitando."
  else
    prompt="${PROMPT_PESQUISA//__NUM__/$num}"
    prompt="${prompt//__ARQUIVO__/$arquivo}"
    log="logs/${arquivo}.pesquisa.log"
    echo ">> [$num/$total] Pesquisando ($(date '+%H:%M:%S')). Log: $log"

    if ! claude -p "$prompt" \
        "${OPCOES_COMUNS[@]}" \
        --model "$MODELO_PESQUISA" \
        --tools "$FERRAMENTAS_PESQUISA" \
        --allowedTools "$FERRAMENTAS_PESQUISA" \
        2>&1 | tee "$log"; then
      echo "!! Falha na pesquisa do capítulo $num. Parando." >&2
      exit 1
    fi

    if [[ ! -f "$pesquisa" ]]; then
      echo "!! As notas de pesquisa do capítulo $num não foram criadas ($pesquisa). Parando." >&2
      exit 1
    fi
  fi

  # --- 2. Escrita, checagem e resumo -----------------------------------------
  if [[ -f "$pesquisa" ]]; then
    notas="- \`$pesquisa\`: notas de pesquisa com os pontos arriscados do capítulo, já conferidos. Não pesquise de novo o que está lá."
  else
    notas="- Este capítulo não tem notas de pesquisa."
  fi
  prompt="${PROMPT_ESCRITA//__NOTAS__/$notas}"
  prompt="${prompt//__NUM__/$num}"
  prompt="${prompt//__ARQUIVO__/$arquivo}"
  log="logs/${arquivo}.escrita.log"
  echo ">> [$num/$total] Escrevendo $capitulo ($(date '+%H:%M:%S')). Log: $log"

  if ! claude -p "$prompt" \
      "${OPCOES_COMUNS[@]}" \
      --model "$MODELO" \
      --tools "$FERRAMENTAS_ESCRITA" \
      --allowedTools "$PERMISSOES_ESCRITA" \
      2>&1 | tee "$log"; then
    echo "!! Falha na escrita do capítulo $num. Parando." >&2
    exit 1
  fi

  if [[ ! -f "$capitulo" ]]; then
    echo "!! O capítulo $num não foi criado ($capitulo). Parando." >&2
    exit 1
  fi

  if [[ ! -f "$resumo" ]]; then
    echo "!! O resumo do capítulo $num não foi criado ($resumo). O próximo capítulo depende dele. Parando." >&2
    exit 1
  fi

  palavras=$(contar_palavras "$capitulo")
  echo ">> [$num/$total] Concluído: $palavras palavras sem código."
  if ((palavras < 3000 || palavras > 5000)); then
    echo "!! Atenção: capítulo $num fora da faixa de 3.000 a 5.000 palavras." >&2
  fi
  echo
done

echo ">> Fim. Capítulos em capitulos/, notas em notas/, logs em logs/."
