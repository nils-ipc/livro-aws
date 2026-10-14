# Estrutura obrigatória de cada capítulo

Todo capítulo segue este esqueleto, nesta ordem:

1. **`# Título`**: título do capítulo (único `#` do arquivo).
2. **Recapitulação brevíssima**: 2 a 4 frases sobre o capítulo anterior, focando no que importa para este. O capítulo 01 substitui isso por uma abertura que apresenta o livro e o Rangô. O capítulo 07 recapitula a Parte I inteira em poucas frases e anuncia a Parte II.
3. **O problema**: apresentar a dor **antes** de qualquer solução. Concreta, de preferência acontecendo com o Rangô ou em um caso real conhecido. O leitor precisa sentir o problema e pensar "isso ia dar errado mesmo".
4. **A solução**: na Parte I, o conceito ou a técnica que resolve o problema. Na Parte II, o serviço que a AWS criou para isso: **por que** ele existe e como resolve exatamente aquele problema.
5. **Mão na massa**: demonstração prática com o Rangô (comandos, código, configuração, saídas esperadas). Na Parte I, demonstrações locais (terminal, `dig`, `curl`, `openssl`, Docker etc.).
6. **Armadilhas e casos reais**: erros comuns, custos escondidos, incidentes conhecidos, limites que surpreendem.
7. **Resumo**: lista curta do que ficou.
8. **Ponte para o próximo capítulo**: terminar com um gancho, o novo problema que surge a partir do que acabamos de construir. O leitor precisa querer virar a página. O capítulo 24 fecha o livro em vez de fazer ponte.
9. **Referências**: documentação oficial e fontes dos casos reais citados (postmortems, artigos), com links. Na Parte II, incluir as fontes das notas de pesquisa usadas. Só links de que você tenha certeza.

Seções intermediárias (`##`, `###`) podem ter títulos criativos; não precisam se chamar literalmente "O problema" ou "Mão na massa".
