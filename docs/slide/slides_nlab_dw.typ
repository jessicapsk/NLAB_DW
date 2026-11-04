#import "lib.typ": *

#show: slides.with(
  title: "Data Warehouse Para O Banco do NLab",
  subtitle: "Modelagem e comparativo com banco relacional OLTP",
  date: "05.10.2026",
  authors: ("Jéssica Pereira, Lucas Ramos",),

  ratio: 16/9,
  layout: "medium",
  title-color: blue.darken(60%),
  toc: true,
  first-slide: true,
  count: "number"
)

#let navy = blue.darken(60%)
#let soft-blue = navy.lighten(88%)
#let mid-blue = navy.lighten(65%)
#let green-ok = rgb("#1b6e32")

#let kpi(valor, rotulo) = block(
  width: 100%,
  fill: soft-blue,
  stroke: 0.8pt + mid-blue,
  radius: 4pt,
  inset: (x: 8pt, y: 7pt),
)[
  #align(center)[
    #text(1.3em, weight: "bold", fill: navy)[#valor] \
    #v(-3pt)
    #text(0.78em)[#rotulo]
  ]
]

#let box-schema(titulo, subtitulo, cor-fundo: soft-blue, cor-borda: mid-blue) = block(
  width: 100%,
  fill: cor-fundo,
  stroke: 1pt + cor-borda,
  radius: 4pt,
  inset: (x: 7pt, y: 6pt),
)[
  #align(center)[
    #text(0.88em, weight: "bold", fill: navy)[#titulo] \
    #v(-3pt)
    #text(0.74em)[#subtitulo]
  ]
]

= Contexto e Banco Operacional (OLTP)

== O Dataset do nLab e o Problema Analítico

#[
  #set text(0.88em)

  O *nLab* é uma wiki colaborativa de Matemática, Física Teórica e Teoria das Categorias. O banco operacional original foi projetado para edição concorrente de artigos no dia a dia, tornando consultas históricas e relatórios muito custosos.

  #v(0.3em)

  #grid(
    columns: (1fr, 1fr, 1fr, 1fr),
    gutter: 0.6em,
    kpi("1.000.000", "Páginas"),
    kpi("1.536.920", "Revisões / Edições"),
    kpi("5.931.831", "Links e Referências"),
    kpi("3.326 / 54", "Autores / Categorias"),
  )

  #v(0.35em)

  #grid(
    columns: (1.05fr, 0.95fr),
    gutter: 1em,
    [
      *Perguntas analíticas que queríamos responder:*
      - Como o volume de edições cresceu ao longo dos anos?
      - Quem são os autores que mais produzem na wiki?
      - Quais categorias temáticas concentram mais artigos?
      - Quais são os verbetes mais citados e conectados?
    ],
    [
      #quote[
        *Gargalo do banco operacional:* A tabela de edições guarda o texto completo de cada artigo. Para gerar relatórios simples, o banco precisava carregar gigabytes de texto na memória, tornando as consultas extremamente lentas ou inviáveis.
      ]
    ]
  )
]

== Desafios e Anomalias Encontrados no Banco Operacional

#[
  #set text(0.82em)

  A análise do banco de dados operacional revelou desafios estruturais que foram resolvidos durante a migração para o DW:

  #v(0.2em)

  #table(
    columns: (1.1fr, 1.35fr, 1.25fr),
    align: (left, left, left),
    [ Desafio no Banco Original ], [ Problema Gerado ], [ Como Resolvemos no DW ],
    [ Categorias fora da tabela de páginas ], [ Exigia cruzar milhões de links para descobrir a categoria de um artigo ], [ Gravamos a categoria diretamente na dimensão de páginas ],
    [ Texto completo salvo nas edições ], [ Carregava gigabytes de texto na memória para contas simples ], [ Guardamos apenas o tamanho do texto (caracteres) e a variação ],
    [ Títulos que diferem só por maiúscula/minúscula ], [ O banco original misturava termos matemáticos distintos (ex.: `cat` vs. `Cat`) ], [ Configuramos distinção exata entre maiúsculas e minúsculas ],
    [ Links sem o código da página de destino ], [ Links da wiki ficavam sem chave de destino associada ], [ O ETL busca e associa a página certa pelo título exato ],
  )
]

= Modelagem Dimensional (Kimball)

== Arquitetura: Constelação de Fatos (Star Schema)

#[
  #set text(0.84em)

  Adotou-se uma *Constelação de Fatos* (*Fact Constellation*) em *Star Schema*: duas tabelas fato compartilham a dimensão conformada de páginas.

  #v(0.3em)

  #grid(
    columns: (1fr, 1.25fr, 1fr),
    gutter: 0.7em,
    align: horizon,
    stack(
      spacing: 0.5em,
      box-schema("dim_tempo", "10.170 dias (2008–2035)"),
      box-schema("dim_hora", "24 horas do dia / 4 turnos"),
      box-schema("dim_autor", "3.327 autores cadastrados"),
    ),
    stack(
      spacing: 0.5em,
      box-schema("FATO_REVISAO", "1.536.920 linhas • Grão: 1 edição\nMedidas: qtd, tamanho, delta de texto", cor-fundo: navy.lighten(78%), cor-borda: navy),
      box-schema("dim_pagina (Conformada)", "1.000.000 páginas • categoria desnormalizada", cor-fundo: rgb("#eef6ee"), cor-borda: green-ok),
      box-schema("FATO_REFERENCIA", "5.931.831 linhas • Grão: 1 referência\nFK dupla: origem e destino em dim_pagina", cor-fundo: navy.lighten(78%), cor-borda: navy),
    ),
    stack(
      spacing: 0.5em,
      box-schema("dim_tipo_link", "6 tipos: link, categoria, imagem, etc."),
      block(
        width: 100%,
        fill: soft-blue,
        radius: 4pt,
        inset: 7pt,
      )[
        #text(0.78em)[
          *Por que Star e NÃO Snowflake?* \
          No Snowflake, as 54 categorias ficariam em uma tabela separada, forçando mais um `JOIN` a cada consulta. No Star Schema, a categoria fica na própria página, dando velocidade máxima sem desperdício de espaço.
        ]
      ]
    ),
  )
]

== Tabelas Fato, Grão e Aditividade

#[
  #set text(0.83em)

  #grid(
    columns: (1.15fr, 0.85fr),
    gutter: 1em,
    [
      *1. `fato_revisao` (1.536.920 linhas)*
      - *Grão:* 1 edição de uma página por um autor em dada data/hora.
      - *Aditivas (podem ser somadas):* quantidade de revisões, se é a criação da página e variação de caracteres.
      - *Semi-aditiva:* tamanho total do texto (usar média ou valor máximo; não somar no tempo).
      - *Não aditiva:* número da versão da edição.
      - *Rastreabilidade:* código original da revisão no banco antigo.
    ],
    [
      *2. `fato_referencia` (5.931.831 linhas)*
      - *Grão:* 1 link de citação partindo de uma página.
      - *Chave dupla:* página de origem e página de destino apontam para a dimensão de páginas.
      - *Aditivas:* quantidade de links e se o destino foi resolvido.
      - *Rastreabilidade:* código original do link no banco antigo.
    ]
  )

  #v(0.25em)

  #quote[
    Separar revisões e links em duas tabelas fatos preserva o objetivo de cada processo e evita multiplicar milhões de linhas sem necessidade.
  ]
]

= Pipeline de ETL e Qualidade de Dados

== Fluxo de Carga e Otimizações (`src/etl.py`)

#[
  #set text(0.79em)

  Pipeline automatizado em Python executando as operações pesadas direto no banco de dados (carga total em \~14 minutos para 8,5 milhões de registros):

  #v(0.2em)

  #grid(
    columns: (1fr, 1fr, 1fr),
    gutter: 0.6em,
    [
      / 1. Preparação (`0,2 s`): Recria as tabelas limpas sem índices secundários para acelerar a carga.
      / 2. Staging / Rascunho (`107,5 s`): Limpa as categorias e calcula o tamanho do texto em lotes.
    ],
    [
      / 3. Dimensões (`28,8 s`): Popula autores, páginas e o calendário contínuo de datas (2008 a 2035).
      / 4. Fatos (`120,2 s`): Carrega as 1,5M revisões e quase 6M links com versões e deltas calculados.
    ],
    [
      / 5. Pós-carga (`555,9 s`): *Otimização essencial:* cria todos os índices secundários só no final, poupando horas.
      / 6. Validação: Checa contagens, somas e integridade; interrompe se houver divergência.
    ]
  )
]

== Validação e Reconciliação OLTP vs. DW

#[
  #set text(0.8em)

  Todos os 7 testes automáticos de integridade passaram com *0 registros em `etl_rejeitados`*:

  #v(0.15em)

  #table(
    columns: (1.75fr, 0.8fr, 0.8fr, 0.45fr),
    align: (left, right, right, center),
    [ Regra de Reconciliação (`validate_load`) ], [ Esperado (OLTP) ], [ Obtido (DW) ], [ Status ],
    [ `revisions = fato_revisao + rejeitadas` ], [ 1.536.920 ], [ 1.536.920 ], [ *OK* ],
    [ `pages = dim_pagina` ], [ 1.000.000 ], [ 1.000.000 ], [ *OK* ],
    [ `wiki_references = fato_referencia + rejeitadas` ], [ 5.931.831 ], [ 5.931.831 ], [ *OK* ],
    [ `SUM(qtd_revisoes) = COUNT(fato_revisao)` ], [ 1.536.920 ], [ 1.536.920 ], [ *OK* ],
    [ `SUM(eh_primeira_revisao) = páginas c/ revisão` ], [ 1.000.000 ], [ 1.000.000 ], [ *OK* ],
    [ Fatos órfãs de dimensão (`LEFT JOIN ... IS NULL`) ], [ 0 ], [ 0 ], [ *OK* ],
    [ Continuidade de `dim_tempo` (`DATEDIFF + 1`) ], [ 10.170 ], [ 10.170 ], [ *OK* ],
  )
]

= Consultas Analíticas (OLAP)

== Consultas Analíticas e Principais Insights

#[
  #set text(0.77em)

  Foram executadas *10 consultas OLAP* (`sql/02_queries_olap.sql`) explorando `WITH ROLLUP`, `DENSE_RANK`, `LAG`/`LEAD`, médias móveis, `NTILE(4)` e a constelação de fatos:

  #v(0.15em)

  #grid(
    columns: (1fr, 1fr),
    gutter: 0.85em,
    [
      *Concentração de Autoria (Pareto — Q2)*
      #table(
        columns: (1.3fr, 0.7fr, 0.55fr, 0.6fr),
        align: (left, right, right, right),
        [ Autor ], [ Revisões ], [ % ], [ Acum. ],
        [ Urs Schreiber ], [ 828.358 ], [ 53,9% ], [ 53,9% ],
        [ nlab-content-mirror ], [ 154.573 ], [ 10,1% ], [ 64,0% ],
        [ Anonymous ], [ 65.428 ], [ 4,3% ], [ 68,2% ],
        [ Zoran Škoda ], [ 49.262 ], [ 3,2% ], [ 71,4% ],
        [ Top 10 (de 3.326) ], [ 1.279.167 ], [ 83,2% ], [ 83,2% ],
      )
    ],
    [
      *Verbetes Mais Referenciados (2ª Fato — Q9)*
      #table(
        columns: (1.4fr, 0.85fr, 0.7fr),
        align: (left, left, right),
        [ Página Destino ], [ Categoria ], [ Links (`L`) ],
        [ Differential Geometry ], [ geometry ], [ 39.487 ],
        [ Geometric Group Theory ], [ probability ], [ 39.436 ],
        [ Quantum Field Theory ], [ probability ], [ 39.377 ],
        [ Noncommutative Geometry ], [ reference ], [ 39.259 ],
        [ Higher Category Theory ], [ probability ], [ 39.233 ],
      )
    ]
  )

  #v(0.1em)
  - *Padrão temporal (Q4, Q8, Q10):* distribuição semanal uniforme (\~14,3%/dia), pico em `2022-07` (10.419 edições) e maior volume na *Madrugada* (`35,08%`, média de `5.549` caracteres vs. `801` nos demais turnos).
]

= Benchmark: Banco Original vs. Data Warehouse

== Metodologia Experimental do Teste

#[
  #set text(0.82em)

  #grid(
    columns: (1fr, 1fr),
    gutter: 1em,
    [
      *Protocolo de medição:*
      - *Mesmo ambiente:* Testes rodando no mesmo servidor para garantir igualdade
      - *Amostragem:* *20 execuções consecutivas* em cada banco por consulta (para validar estabilidade)
      - *Tempo limite:* `300 s` (5 minutos) por consulta
      - *Dois cenários avaliados:*
        1. *Cenário A:* Banco original sem índices secundários
        2. *Cenário B:* Banco original com todos os índices secundários ativos
    ],
    [
      *Por que Média, Mediana e P95?*
      / Média: O tempo médio de todas as 20 rodadas.
      / Mediana (P50): O tempo típico do sistema no dia a dia.
      / P95: O pico de lentidão (mostra a estabilidade sob pressão de memória).
    ]
  )

  #v(0.15em)
  - *Consultas comparadas:* *B1* — Revisões por ano/mês | *B2* — Revisões por categoria temática | *B3* — Revisões por autor.
]

== Cenário A: Banco Original sem Índices Secundários (20x)

#[
  #set text(0.79em)

  Sem índices secundários no banco original, consultas que cruzam tabelas grandes sofrem lentidão extrema:

  #v(0.2em)

  #table(
    columns: (1.4fr, 0.7fr, 0.7fr, 0.7fr, 0.65fr, 0.65fr, 0.65fr, 0.75fr, 0.75fr),
    align: (left, right, right, right, right, right, right, right, right),
    [ Consulta ], [ Original Méd. ], [ Original Med. ], [ Original P95 ], [ DW Méd. ], [ DW Med. ], [ DW P95 ], [ Ganho Med. ], [ Ganho P95 ],
    [ *B1 — Ano/Mês* ], [ 9,05 s ], [ 4,64 s ], [ 25,07 s ], [ 3,26 s ], [ 2,76 s ], [ 3,31 s ], [ *1,7x* ], [ *7,6x* ],
    [ *B2 — Categoria* ], [ > 300 s ], [ > 300 s ], [ > 300 s ], [ 4,49 s ], [ 4,17 s ], [ 4,69 s ], [ *> 72x* ], [ *> 64x* ],
    [ *B3 — Autor* ], [ 11,37 s ], [ 7,89 s ], [ 25,15 s ], [ 2,79 s ], [ 2,65 s ], [ 2,95 s ], [ *3,0x* ], [ *8,5x* ],
  )

  #v(0.2em)

  - *Eliminação de junções custosas (B2):* cruzar 3 tabelas estoura o limite de 5 minutos (> 300 s) no banco original; no DW responde em *4,17 s* (*mais de 72x mais rápido*).
  - *Estabilidade previsível (P95):* nas outras consultas, o banco original teve picos de até 40 s; no DW a resposta é sempre estável abaixo de *3,3 s* (*7,6x a 8,5x mais rápido*).
]

== Cenário B: Banco Original com Índices Secundários (20x)

#[
  #set text(0.79em)

  Com índices secundários ativos no banco original:

  #v(0.2em)

  #table(
    columns: (1.4fr, 0.7fr, 0.7fr, 0.7fr, 0.65fr, 0.65fr, 0.65fr, 0.75fr, 0.75fr),
    align: (left, right, right, right, right, right, right, right, right),
    [ Consulta ], [ Original Méd. ], [ Original Med. ], [ Original P95 ], [ DW Méd. ], [ DW Med. ], [ DW P95 ], [ Ganho Méd. ], [ Ganho Med. ],
    [ *B1 — Ano/Mês* ], [ 0,70 s ], [ 0,43 s ], [ 0,73 s ], [ 2,98 s ], [ 2,61 s ], [ 3,22 s ], [ 0,2x ], [ 0,2x ],
    [ *B2 — Categoria* ], [ 5,04 s ], [ 3,92 s ], [ 5,33 s ], [ 4,02 s ], [ 3,78 s ], [ 4,12 s ], [ *1,3x* ], [ *1,0x* ],
    [ *B3 — Autor* ], [ 0,44 s ], [ 0,29 s ], [ 0,45 s ], [ 2,54 s ], [ 2,53 s ], [ 2,60 s ], [ 0,2x ], [ 0,1x ],
  )

  #v(0.2em)

  - *Entendendo B1 e B3:* em contagens simples de uma coluna, o banco original é rápido porque conta direto no índice (`COUNT(*)`). No DW, estamos somando métricas de negócio em cima da tabela inteira em tempo constante (\~2,5 s).
  - *Vantagem do DW na análise temática (B2):* na primeira execução, o banco original levou *25,72 s* cruzando dados de links, contra *8,73 s* no DW, mantendo o DW *1,3x melhor na média e no P95*.
]

== Síntese Comparativa e Conclusões

#[
  #set text(0.81em)

  #grid(
    columns: (1.08fr, 0.92fr),
    gutter: 1em,
    [
      *Quando o Data Warehouse se destaca de verdade:*
      1. *Consultas com junções entre tabelas (B2):* Reduz uma consulta que demorava mais de 5 minutos (ou 25 s no banco com índice) para `~4 segundos` constantes.
      2. *Estabilidade de tempo de resposta:* Descartar o texto bruto mantém as tabelas fatos leves na memória, eliminando picos de travamento.
      3. *Cálculo de várias métricas juntas:* Permite calcular tamanho, variações e contagens no mesmo passe de `~2,5 s`.
    ],
    [
      *Resumo do Projeto:*
      / Modelagem: Constelação de fatos (`fato_revisao` + `fato_referencia`) com dimensão de páginas compartilhada.
      / Carga Verificada: Quase `7,5 milhões` de fatos carregados com *100% de reconciliação* e *0 rejeições*.
      / Ganhos Medidos: Até *> 72x mais rápido* na consulta temática e *7x a 8x mais estável* nos picos de lentidão.
    ]
  )
]
