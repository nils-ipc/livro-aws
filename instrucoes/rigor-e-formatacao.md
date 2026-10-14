# Rigor técnico e formatação

## Rigor técnico

- Todo código e todo comando devem ser **corretos e executáveis** como estão. Indicar os pré-requisitos.
- Usar AWS CLI v2, Python 3.12+, CDK v2 e as versões atuais dos serviços (na Parte II, conferidas na pesquisa quando houver dúvida).
- Preços, limites e cotas mudam: quando citados, informar que são **aproximados e de referência**, a região (`us-east-1`, salvo indicação) e o mês/ano da consulta, e incentivar a consulta à página oficial.
- Região padrão dos exemplos: `us-east-1`. Mencionar `sa-east-1` (São Paulo) quando latência ou custo forem relevantes para o leitor brasileiro.
- Segurança por padrão: menor privilégio, nada público sem motivo, nenhuma chave no código, nem em exemplo "rápido".
- Ao final de demonstrações que criam recursos pagos, **mostrar como destruí-los** (ou avisar que serão reaproveitados no próximo capítulo).
- Não recomendar serviço descontinuado ou em vias de descontinuação.

## Formatação

- Idioma: **português do Brasil**.
- Nome do arquivo: `NN-titulo-em-kebab-case.md`, conforme o sumário. O prefixo de dois dígitos define a ordem.
- Um único `#` por arquivo. Seções com `##` e `###`.
- Blocos de código sempre com a linguagem indicada (` ```bash `, ` ```python `, ` ```json `, ` ```tsx `, ` ```yaml `).
- Saídas de terminal em um bloco separado do comando quando forem longas.
- Nomes de serviços na forma oficial na primeira menção (Amazon S3, AWS Lambda, Amazon EC2); depois podem ser abreviados (S3, Lambda, EC2).
- Termos em inglês que são o jargão técnico do mercado (deploy, bucket, cold start) ficam em inglês, em itálico na primeira aparição. São vocabulário técnico da área.
- Imagens em `capitulos/imagens/`, referenciadas com caminho relativo (`![legenda](imagens/arquivo.png)`). Diagramas simples podem ser em ASCII dentro de um bloco de código.
- Contagem de palavras sem blocos de código: `sed '/^```/,/^```/d' capitulos/ARQUIVO.md | wc -w`.
