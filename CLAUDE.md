# Livro de AWS — Instruções do Projeto

Esta pasta contém o manuscrito de um livro sobre **AWS** para devs sêniores full stack (Python + React) que sabem pouco de DevOps. Escrito em Markdown, em português do Brasil, e exportado para PDF e EPUB. São 24 capítulos: 6 de fundamentos de DevOps (Parte I) e 18 de AWS (Parte II), acompanhando um único projeto, o app de pedidos **Rangô** (FastAPI + React).

## Estrutura

```
.
├── CLAUDE.md            # Este arquivo: índice das instruções
├── instrucoes/          # Regras do livro, divididas por assunto
├── capitulos/           # Um arquivo .md por capítulo (o livro em si)
├── notas/
│   ├── pesquisa/        # Notas de pesquisa, só Parte II (estilo telegráfico)
│   └── resumos/         # Resumo de cada capítulo escrito (estilo telegráfico)
├── exportacao/          # Saída gerada: livro.pdf e livro.epub
├── logs/                # Logs do script de escrita
├── escrever-livro.sh    # Script que escreve os capítulos, um por vez
└── escrever-livro.ps1   # O mesmo script, nativo para Windows (PowerShell 7)
```

## Instruções

Leia apenas os arquivos de que a tarefa precisa.

| Arquivo | Conteúdo | Quem precisa |
|---------|----------|--------------|
| `instrucoes/livro.md` | Público-alvo, projeto Rangô, tamanho, sumário completo dos 24 capítulos | Todos |
| `instrucoes/estrutura-do-capitulo.md` | Esqueleto obrigatório de cada capítulo | Escrita |
| `instrucoes/estilo.md` | Tom, voz, faça/não faça, marcas de texto de IA a evitar | Escrita |
| `instrucoes/rigor-e-formatacao.md` | Rigor técnico (versões, preços, segurança) e formatação Markdown | Escrita |
| `instrucoes/pesquisa.md` | O que pesquisar (só pontos arriscados), fontes, limites e formato das notas | Pesquisa (só Parte II) |
| `instrucoes/resumos.md` | Formato dos resumos de capítulo em `notas/resumos/` | Escrita |
| `instrucoes/exportacao.md` | Comandos pandoc para gerar PDF e EPUB | Exportação |

## Regras que valem sempre

- O texto do livro (`capitulos/`) segue `instrucoes/estilo.md`: linguagem natural, como se fosse falada, sem gírias. O estilo telegráfico das `notas/` nunca vai para o livro.
- Quem escreve usa o próprio conhecimento. As notas de pesquisa (`notas/pesquisa/`, só na Parte II) conferem os pontos arriscados e, quando existem, prevalecem sobre a memória do modelo.
- Não editar `exportacao/` manualmente.
