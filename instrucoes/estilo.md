# Tom e estilo

## A voz

- **Linguagem natural, como se fosse falada.** O texto deve soar como uma pessoa experiente explicando em voz alta para um colega: claro, fluido, próximo. Nada formal, acadêmico ou engessado, e também **nada informal**.
- **Sem gírias**, sem expressões de internet, sem palavrões, sem abreviações de conversa ("pra", "tá", "vc"). Português correto, com a naturalidade da fala.
- **Frases curtas na maior parte do tempo**, mas com ritmo variado: alternar frases curtas e médias, como numa conversa real. Parágrafos curtos.
- **Direto ao ponto.** Nada de introdução genérica do tipo "No mundo atual da tecnologia...". Cada parágrafo precisa entregar algo.
- **Preciso e rigoroso.** A fluidez nunca sacrifica a exatidão técnica.
- **Envolvente.** Cada seção deve deixar uma pergunta no ar ou uma recompensa logo à frente. O leitor não pode ter sono. O interesse vem de boas histórias, problemas concretos e revelações.
- Bom humor é permitido de forma **leve e pontual**, por meio de situações e ironia sutil (o deploy de sexta-feira, a fatura inesperada). Nunca com gíria ou piada forçada.

## Faça

- Falar com o leitor em segunda pessoa ("você").
- Usar perguntas retóricas de vez em quando para conduzir o raciocínio, como em uma conversa (com moderação; ver a seção sobre marcas de texto de IA).
- Usar analogias do mundo de desenvolvimento (Python, React, git, banco de dados) e do cotidiano.
- Contar casos reais (incidentes públicos, postmortems conhecidos), sempre verificados.
- Mostrar o erro antes do acerto quando isso ensinar algo ("veja o que acontece se...").
- Usar destaques curtos:
  - `> **Armadilha:** ...` para erros comuns e custos escondidos.
  - `> **Na vida real:** ...` para casos reais e práticas de mercado.
  - `> **Dica:** ...` para atalhos e boas práticas.

## Não faça

- Gírias, linguagem coloquial demais ou tom de rede social.
- Parágrafos longos ou blocos de teoria sem exemplo.
- Jargão sem explicação na primeira aparição.
- Linguagem de marketing ("serviço altamente escalável e resiliente que..."). Explicar o que faz, sem vender.
- Listas enormes de recursos. Escolher o que importa para o leitor e para o Rangô.
- Fingir que a AWS é perfeita: apontar custos, complexidade e alternativas quando for relevante.

## Evitar marcas de texto escrito por IA

O texto precisa parecer escrito por uma pessoa. Os padrões abaixo denunciam texto gerado por IA e **não devem aparecer** no livro. Escrever já evitando esses padrões; a checagem mecânica abaixo pega o que escapar.

### Pontuação e construções

- **Travessão (—) para intercalar explicação no meio da frase.** Usar vírgula, parênteses ou dois-pontos. Travessão só em diálogo, se houver.
- **"Não é X, é Y"** e variações: "isso não é um bug, é uma feature", "não se trata de X, mas de Y", "X não é apenas Y". Afirmar diretamente o que a coisa é.
- **"Não apenas X, mas também Y."**
- **Pergunta seguida de resposta de efeito**: "O resultado? Caos.", "A solução? Simples.", "O motivo? ...". No máximo uma ocorrência rara por capítulo.
- **Sequências de frases-fragmento para dar drama**: "Rápido. Barato. Seguro.", "Sem servidor. Sem dor de cabeça."
- **Grupos de três** recorrentes (três adjetivos, três exemplos, três itens em toda lista). Usar a quantidade que o conteúdo pedir: dois, quatro, um.
- **Fechar todo parágrafo ou seção com uma frase de efeito** ou moral da história.
- **Dois-pontos em todo título** ("Lambda: o poder do serverless").
- **Excesso de negrito** no meio do texto. Negrito só para termos sendo definidos ou avisos importantes.
- **Emojis.** Nenhum.

### Vocabulário e expressões

- Palavras-tique: "mergulhar", "jornada", "robusto", "crucial", "fundamental", "essencial", "poderoso", "potencializar", "alavancar", "desvendar", "explorar" (no sentido de "vamos explorar"), "navegar", "ecossistema", "cenário", "panorama", "fascinante", "divisor de águas", "verdadeiro" (como em "um verdadeiro desafio").
- Expressões de transição e preenchimento: "vale ressaltar", "vale destacar", "é importante notar que", "em resumo", "em suma", "em última análise", "no fim das contas", "no final do dia", "dito isso", "nesse sentido", "de fato", "certamente", "sem dúvida".
- Aberturas e fechamentos de manual: "Neste capítulo, vamos explorar...", "Vamos mergulhar...", "Agora que você já sabe X, vamos ver Y", "E é exatamente aí que entra o X", "Spoiler:", "Parabéns!", "Pronto!".
- Abrir várias seções com "Imagine que...".
- Traduções literais do inglês: "endereçar um problema", "fazer sentido" em excesso, "no final do dia", "isso dito".

### Estrutura e conteúdo

- **Simetria artificial**: todas as seções do mesmo tamanho, todos os parágrafos com o mesmo número de frases, toda lista com o mesmo número de itens. Variar.
- **Listas onde caberia prosa.** Usar listas para passos, comparações e itens realmente enumeráveis. Raciocínio vai em parágrafo.
- **Listas no formato "**Termo:** explicação"** em sequência, repetidas ao longo do capítulo.
- **Resumir o que acabou de ser dito** no fim de cada seção. O resumo existe uma vez, no fim do capítulo.
- **Ressalvas e avisos genéricos repetidos** ("lembre-se de sempre seguir as boas práticas", "consulte a documentação"). Avisar uma vez, de forma específica, onde importa.
- **Entusiasmo artificial** e elogios ao leitor ou à tecnologia.
- **Metáforas grandiosas e personificação** ("a AWS abraça sua aplicação", "o coração da sua infraestrutura").
- **Generalidades sem detalhe concreto.** Pessoas escrevem com números, nomes, mensagens de erro reais e situações específicas. Preferir sempre o detalhe concreto ("a requisição levou 4,2 segundos") ao genérico ("a performance ficou ruim").

### Checagem mecânica

Antes de dar o capítulo por pronto, rodar Grep no arquivo por: `—`, `não é`, `não apenas`, `mas também`, `não se trata`, e cada palavra e expressão listada acima. Corrigir cada ocorrência que caia num dos padrões proibidos.
