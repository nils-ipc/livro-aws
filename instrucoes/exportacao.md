# Exportação

Requer [Pandoc](https://pandoc.org) (`brew install pandoc`). Para PDF, usa WeasyPrint (já instalado) ou um motor LaTeX.

EPUB:

```bash
pandoc capitulos/*.md -o exportacao/livro.epub \
  --toc --toc-depth=2 --resource-path=capitulos \
  --metadata title="Título do Livro" \
  --metadata author="Autor" \
  --metadata lang=pt-BR
```

PDF:

```bash
pandoc capitulos/*.md -o exportacao/livro.pdf \
  --pdf-engine=weasyprint \
  --toc --toc-depth=2 --resource-path=capitulos \
  --metadata title="Título do Livro" \
  --metadata author="Autor" \
  --metadata lang=pt-BR
```

Executar os comandos a partir da raiz do projeto. O glob `capitulos/*.md` respeita a ordem dos prefixos numéricos.

Não editar arquivos em `exportacao/` manualmente; eles são gerados.
