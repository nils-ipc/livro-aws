# Pesquisa

Quem escreve o livro já conhece bem os assuntos. A pesquisa é uma garantia extra: serve para conferir só os pontos em que o conhecimento prévio do modelo tem mais chance de estar errado ou desatualizado. Ela não substitui esse conhecimento e não precisa cobrir o capítulo inteiro.

Só os capítulos da Parte II (07 a 24) têm etapa de pesquisa. O resultado fica em `notas/pesquisa/NN-nome-do-capitulo.md` e é usado apenas por quem escreve.

## O que pesquisar

Antes de buscar, liste mentalmente o que o capítulo vai afirmar e escolha só o que for arriscado:

- O que pode ter mudado recentemente: nomes de serviços e recursos, lançamentos, descontinuações, comportamentos padrão que a AWS alterou, versões (CLI, CDK, runtimes do Lambda, engines do RDS).
- Números exatos: preços, limites, cotas, free tier.
- Pontos com nuance, em que é fácil dizer algo quase certo: regras de cobrança, precedência de políticas, consistência, limites de tempo, o que é ou não incluído por padrão.
- Sintaxe de comandos e APIs que o capítulo vai usar e que você não sabe de cor com segurança.
- Detalhes dos casos reais que o capítulo vai contar (empresa, ano, números).

Não pesquise o que é conceito estável e que você domina.

## Fontes, nesta ordem de preferência

1. Documentação oficial da AWS (`docs.aws.amazon.com`), páginas de preço (`aws.amazon.com/.../pricing`) e o blog "What's New" da AWS.
2. Documentação oficial das demais ferramentas.
3. Postmortems públicos e relatos de incidentes de empresas reconhecidas, para os casos reais.

Se fontes divergirem, prevalece a documentação oficial mais recente.

## Limites

- No máximo **6 buscas** (WebSearch) e **3 páginas lidas** (WebFetch) por capítulo.
- Na escrita, no máximo 3 buscas extras, só para uma dúvida que surgir e que as notas não cubram.
- Preferir uma página oficial abrangente a várias páginas parciais.

## Formato das notas

Curtas: de 15 a 40 itens. Estilo telegráfico (caveman): sem artigos nem conectivos, uma informação por linha. Mas **manter exatos**: números, preços, datas, versões, nomes de serviços, flags, comandos, mensagens de erro e URLs. Cada item com a URL da fonte.

```markdown
# Pesquisa NN — Título

## Pontos conferidos
- fato curto (o que poderia sair errado sem conferir). fonte: URL

## Preços e limites (região, mês/ano da consulta)
- ...

## Casos reais
- empresa, ano, o que houve, número relevante. fonte: URL

## Não confirmado
- o que não deu para verificar (não usar no livro como fato)
```

Seção sem conteúdo pode ser omitida.
