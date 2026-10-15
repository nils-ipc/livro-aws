#Requires -Version 7
<#
.SYNOPSIS
  Escreve os capítulos do livro, um por vez, chamando o Claude Code em modo
  não interativo. Versão nativa para Windows (PowerShell 7) de escrever-livro.sh.

.DESCRIPTION
  Para cada capítulo:
    1. Pesquisa (sessão separada, só Parte II): confere os pontos arriscados
       e salva notas curtas em notas/pesquisa/.
    2. Escrita: escreve o capítulo, faz uma checagem mecânica (grep de marcas
       de IA e contagem de palavras) e salva um resumo em notas/resumos/.

  Cada opção pode vir como parâmetro ou como variável de ambiente com o mesmo
  nome do script .sh (INICIO, FIM, REESCREVER, ...). O parâmetro tem prioridade.

.EXAMPLE
  .\escrever-livro.ps1                        # escreve todos os capítulos que ainda não existem
.EXAMPLE
  .\escrever-livro.ps1 -Inicio 5 -Fim 8       # só do capítulo 05 ao 08
.EXAMPLE
  .\escrever-livro.ps1 -Reescrever            # reescreve mesmo se o capítulo já existir (reaproveita a pesquisa)
.EXAMPLE
  .\escrever-livro.ps1 -Repesquisar           # refaz também a pesquisa
.EXAMPLE
  .\escrever-livro.ps1 -PesquisaAPartir 1     # pesquisa também a Parte I (padrão: só a partir do 07)
.EXAMPLE
  .\escrever-livro.ps1 -Modelo opus -ModeloPesquisa sonnet -Esforco medium
.EXAMPLE
  .\escrever-livro.ps1 -Claude 'C:\caminho\para\claude.exe'   # se o claude não estiver no PATH
#>
[CmdletBinding()]
param(
  [int]$Inicio = $(if ($env:INICIO) { [int]$env:INICIO } else { 1 }),
  [int]$Fim = $(if ($env:FIM) { [int]$env:FIM } else { 24 }),
  [switch]$Reescrever = ($env:REESCREVER -eq '1'),
  [switch]$Repesquisar = ($env:REPESQUISAR -eq '1'),
  [string]$Modelo = $(if ($env:MODELO) { $env:MODELO } else { 'opus' }),
  [string]$ModeloPesquisa = $(if ($env:MODELO_PESQUISA) { $env:MODELO_PESQUISA } else { 'sonnet' }),
  [string]$Esforco = $(if ($env:ESFORCO) { $env:ESFORCO } else { 'medium' }),
  [int]$PesquisaAPartir = $(if ($env:PESQUISA_A_PARTIR) { [int]$env:PESQUISA_A_PARTIR } else { 7 }),
  # Caminho do executável do Claude Code, se ele não estiver no PATH.
  [string]$Claude = $(if ($env:CLAUDE_BIN) { $env:CLAUDE_BIN } else { 'claude' })
)

$ErrorActionPreference = 'Stop'

# Acentos corretos no prompt enviado ao claude e na saída lida dele.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)

Set-Location -LiteralPath $PSScriptRoot

if (-not (Get-Command $Claude -ErrorAction SilentlyContinue)) {
  Write-Error "!! Claude Code não encontrado ('$Claude'). Instale o CLI ou passe o caminho com -Claude."
}

$Capitulos = @(
  '01-do-notebook-para-o-mundo'
  '02-dns-https-e-tls'
  '03-servidores-containers-e-kubernetes'
  '04-arquitetura-que-escala'
  '05-filas-eventos-e-sistemas-distribuidos'
  '06-producao-de-verdade'
  '07-bem-vindo-a-aws'
  '08-iam-quem-pode-fazer-o-que'
  '09-ec2-seu-primeiro-servidor'
  '10-vpc-a-rede-na-aws'
  '11-s3-armazenamento-de-objetos'
  '12-rds-banco-de-dados-gerenciado'
  '13-load-balancer-e-auto-scaling'
  '14-route-53-cloudfront-e-certificados'
  '15-infraestrutura-como-codigo-com-cdk'
  '16-segredos-e-criptografia'
  '17-containers-com-ecr-ecs-e-fargate'
  '18-ci-cd-na-aws'
  '19-serverless-com-lambda-e-api-gateway'
  '20-dynamodb'
  '21-sqs-sns-eventbridge-e-step-functions'
  '22-observabilidade-com-cloudwatch'
  '23-seguranca-em-producao'
  '24-custos-e-arquitetura'
)

# Opções comuns: sem plugins/hooks/configurações do usuário (só as do projeto),
# sem servidores MCP, sem skills, esforço reduzido.
$OpcoesComuns = @(
  '--setting-sources', 'project'
  '--strict-mcp-config'
  '--disable-slash-commands'
  '--effort', $Esforco
  '--output-format', 'text'
)

$FerramentasPesquisa = 'Read,Write,Glob,WebSearch,WebFetch'
$FerramentasEscrita = 'Read,Write,Edit,Glob,Grep,WebSearch,WebFetch,Bash'
$PermissoesEscrita = 'Read,Write,Edit,Glob,Grep,WebSearch,WebFetch,Bash(wc:*),Bash(sed:*),Bash(grep:*),Bash(ls:*)'

foreach ($pasta in 'capitulos', 'notas/pesquisa', 'notas/resumos', 'logs') {
  New-Item -ItemType Directory -Force -Path $pasta | Out-Null
}

# Conta palavras excluindo blocos de código (equivale a: sed '/^```/,/^```/d' | wc -w).
function Get-ContagemPalavras([string]$Caminho) {
  $dentroDeCodigo = $false
  $total = 0
  foreach ($linha in Get-Content -LiteralPath $Caminho -Encoding utf8) {
    if ($linha.StartsWith('```')) {
      $dentroDeCodigo = -not $dentroDeCodigo
      continue
    }
    if (-not $dentroDeCodigo) {
      $total += @($linha -split '\s+' | Where-Object { $_ -ne '' }).Count
    }
  }
  return $total
}

# Roda o claude com o prompt via stdin (evita problemas de aspas na linha de
# comando do Windows), mostra a saída na tela e grava no log.
function Invoke-Claude([string]$Prompt, [string]$Log, [string[]]$Argumentos) {
  $Prompt | & $Claude -p @OpcoesComuns @Argumentos 2>&1 |
    ForEach-Object { "$_" } |
    Tee-Object -FilePath $Log |
    Out-Host
  return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------------
# Prompt da pesquisa
# ---------------------------------------------------------------------------
$PromptPesquisa = @'
Tarefa: conferir na internet os pontos arriscados do capítulo __NUM__ do livro e salvar notas curtas em `notas/pesquisa/__ARQUIVO__.md`. Não escreva o capítulo. Não crie nem altere nenhum outro arquivo.

1. Leia `instrucoes/livro.md` (público e as linhas do capítulo __NUM__, do anterior e do próximo no sumário) e `instrucoes/pesquisa.md`.
2. Liste para si o que o capítulo vai afirmar e escolha só o que tem risco de erro: o que pode ter mudado recentemente, números exatos (preços, limites, cotas), pontos com nuance, sintaxe que você não sabe de cor com segurança, detalhes dos casos reais. Não pesquise conceito estável que você domina.
3. Pesquise só isso: no máximo 6 buscas e 3 páginas lidas.
4. Salve as notas no formato de `instrucoes/pesquisa.md`: 15 a 40 itens, telegráfico, URL em cada item, números e comandos exatos.

Responda apenas: "ok" e o número de itens salvos.
'@

# ---------------------------------------------------------------------------
# Prompt da escrita
# ---------------------------------------------------------------------------
$PromptEscrita = @'
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
'@

$total = $Capitulos.Count

for ($i = $Inicio; $i -le $Fim -and $i -le $total; $i++) {
  $num = '{0:D2}' -f $i
  $arquivo = $Capitulos[$i - 1]
  $capitulo = "capitulos/$arquivo.md"
  $pesquisa = "notas/pesquisa/$arquivo.md"
  $resumo = "notas/resumos/$arquivo.md"

  if ((Test-Path -LiteralPath $capitulo) -and -not $Reescrever) {
    Write-Host ">> [$num/$total] $capitulo já existe, pulando."
    continue
  }

  # --- 1. Pesquisa (só a partir de PesquisaAPartir) ---------------------------
  if ($i -lt $PesquisaAPartir) {
    Write-Host ">> [$num/$total] Parte I: sem pesquisa."
  }
  elseif ((Test-Path -LiteralPath $pesquisa) -and -not $Repesquisar) {
    Write-Host ">> [$num/$total] Pesquisa já existe ($pesquisa), reaproveitando."
  }
  else {
    $prompt = $PromptPesquisa.Replace('__NUM__', $num).Replace('__ARQUIVO__', $arquivo)
    $log = "logs/$arquivo.pesquisa.log"
    Write-Host ">> [$num/$total] Pesquisando ($(Get-Date -Format 'HH:mm:ss')). Log: $log"

    $ok = Invoke-Claude $prompt $log @(
      '--model', $ModeloPesquisa
      '--tools', $FerramentasPesquisa
      '--allowedTools', $FerramentasPesquisa
    )
    if (-not $ok) {
      Write-Host "!! Falha na pesquisa do capítulo $num. Parando." -ForegroundColor Red
      exit 1
    }
    if (-not (Test-Path -LiteralPath $pesquisa)) {
      Write-Host "!! As notas de pesquisa do capítulo $num não foram criadas ($pesquisa). Parando." -ForegroundColor Red
      exit 1
    }
  }

  # --- 2. Escrita, checagem e resumo -----------------------------------------
  if (Test-Path -LiteralPath $pesquisa) {
    $notas = "- ``$pesquisa``: notas de pesquisa com os pontos arriscados do capítulo, já conferidos. Não pesquise de novo o que está lá."
  }
  else {
    $notas = '- Este capítulo não tem notas de pesquisa.'
  }
  $prompt = $PromptEscrita.Replace('__NOTAS__', $notas).Replace('__NUM__', $num).Replace('__ARQUIVO__', $arquivo)
  $log = "logs/$arquivo.escrita.log"
  Write-Host ">> [$num/$total] Escrevendo $capitulo ($(Get-Date -Format 'HH:mm:ss')). Log: $log"

  $ok = Invoke-Claude $prompt $log @(
    '--model', $Modelo
    '--tools', $FerramentasEscrita
    '--allowedTools', $PermissoesEscrita
  )
  if (-not $ok) {
    Write-Host "!! Falha na escrita do capítulo $num. Parando." -ForegroundColor Red
    exit 1
  }
  if (-not (Test-Path -LiteralPath $capitulo)) {
    Write-Host "!! O capítulo $num não foi criado ($capitulo). Parando." -ForegroundColor Red
    exit 1
  }
  if (-not (Test-Path -LiteralPath $resumo)) {
    Write-Host "!! O resumo do capítulo $num não foi criado ($resumo). O próximo capítulo depende dele. Parando." -ForegroundColor Red
    exit 1
  }

  $palavras = Get-ContagemPalavras $capitulo
  Write-Host ">> [$num/$total] Concluído: $palavras palavras sem código."
  if ($palavras -lt 3000 -or $palavras -gt 5000) {
    Write-Host "!! Atenção: capítulo $num fora da faixa de 3.000 a 5.000 palavras." -ForegroundColor Yellow
  }
  Write-Host ''
}

Write-Host '>> Fim. Capítulos em capitulos/, notas em notas/, logs em logs/.'
