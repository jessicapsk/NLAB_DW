#import "lib.typ": *

#show: slides.with(
  title: "Data Warehouse Para O Banco do NLab",
  subtitle: "Modelagem dimensional, pipeline de ETL e análise comparativa com OLTP",
  date: "Novembro de 2026",
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
    #text(1.25em, weight: "bold", fill: navy)[#valor] \
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
    #text(0.86em, weight: "bold", fill: navy)[#titulo] \
    #v(-3pt)
    #text(0.72em)[#subtitulo]
  ]
]

#let box-entity(nome, campos, cor-fundo: soft-blue, cor-borda: mid-blue) = block(
  width: 100%,
  fill: cor-fundo,
  stroke: 1pt + cor-borda,
  radius: 4pt,
  inset: (x: 6pt, y: 5pt),
)[
  #align(left)[
    #text(0.82em, weight: "bold", fill: navy)[#nome] \
    #v(-4pt)
    #text(0.68em)[#campos]
  ]
]

= Contexto e Banco Operacional (OLTP)

== O Dataset do nLab e o Problema Analítico

#[
  #set text(0.86em)

  O *nLab* é uma enciclopédia colaborativa aberta de Matemática, Física Teórica e Teoria das Categorias. O banco operacional original foi projetado para edição concorrente de artigos no dia a dia, tornando consultas históricas e relatórios muito custosos.

  #v(0.3em)

  #grid(
    columns: (1fr, 1fr, 1fr, 1fr),
    gutter: 0.6em,
    kpi("1.000.000", "Páginas (pages)"),
    kpi("1.536.920", "Revisões (revisions)"),
    kpi("5.931.831", "Links e Referências"),
    kpi("3.326 / 54", "Autores / Categorias"),
  )

  #v(0.35em)

  #grid(
    columns: (1.05fr, 0.95fr),
    gutter: 1em,
    [
      *Questões analíticas a serem respondidas:*
      - Como o volume de edições cresceu ao longo dos anos?
      - Quem são os autores que mais produzem na wiki?
      - Quais categorias temáticas concentram mais artigos?
      - Quais são os verbetes mais citados e conectados?
    ],
    [
      #quote[
        *Gargalo de análises no banco operacional:* O modelo transacional é eficiente para edições pontuais de artigos. Contudo, ao executar consultas analíticas que varrem o histórico, o banco é obrigado a carregar gigabytes de texto na memória, tornando relatórios gerenciais inviáveis sem comprometer o sistema operacional.
      ]
    ]
  )
]

== Modelagem Relacional de Origem (OLTP em 3NF)

#[
  #set text(0.80em)

  O banco operacional original é normalizado em *3ª Forma Normal*, estruturado em torno das seguintes entidades e relacionamentos transacionais:

  #v(0.25em)

  #grid(
    columns: (1fr, 1.25fr, 1fr),
    gutter: 0.7em,
    align: horizon,
    stack(
      spacing: 0.5em,
      box-entity("categories (54)", "• id (PK)\n• name"),
      box-entity("users (3.326)", "• id (PK)\n• name\n• total_revisions"),
    ),
    stack(
      spacing: 0.5em,
      box-entity("pages (1.000.000)", "• id (PK)\n• name, slug\n• category_id (FK)\n• author_id (FK)", cor-fundo: rgb("#fef8ea"), cor-borda: rgb("#d4a017")),
      box-entity("revisions (1.536.920)", "• id (PK)\n• page_id (FK)\n• author_id (FK)\n• content (MEDIUMTEXT)\n• created_at", cor-fundo: rgb("#fef8ea"), cor-borda: rgb("#d4a017")),
    ),
    stack(
      spacing: 0.5em,
      box-entity("wiki_references (5.931.831)", "• id (PK)\n• page_id (FK)\n• link_type (L, C, R, I, W, F)\n• referenced_name\n• target_page_id (FK)"),
      block(
        width: 100%,
        fill: soft-blue,
        radius: 4pt,
        inset: 6pt,
      )[
        #text(0.72em)[
          *Gargalo de Junções:* \
          Descobrir a categoria de uma página exigia cruzar `revisions` (1,5M) com `wiki_references` (5,9M linhas) com `link_type = 'C'`, degradando o tempo de resposta.
        ]
      ]
    ),
  )
]

= Modelagem Dimensional (Kimball)

== Arquitetura: Constelação de Fatos (Star Schema)

#[
  #set text(0.83em)

  Adotou-se uma *Constelação de Fatos* (*Fact Constellation*) em *Star Schema*: duas tabelas fato compartilham a dimensão conformada de páginas.

  #v(0.25em)

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
        #text(0.76em)[
          *Por que Star e NÃO Snowflake?* \
          No Snowflake, as 54 categorias ficariam em uma tabela separada, forçando mais um `JOIN` a cada consulta. No Star Schema, a categoria fica na própria página, dando velocidade máxima sem desperdício de espaço.
        ]
      ]
    ),
  )
]

== Tabelas Fato, Grão e Aditividade

#[
  #set text(0.82em)

  #grid(
    columns: (1.15fr, 0.85fr),
    gutter: 1em,
    [
      *1. `fato_revisao` (1.536.920 linhas)*
      - *Grão:* 1 edição de uma página por um autor em dada data/hora.
      - *Aditivas (podem ser somadas):* quantidade de revisões, se é a criação da página e variação de caracteres (`delta_tamanho`).
      - *Semi-aditiva:* tamanho total do texto (`tamanho_conteudo` — usar média ou valor máximo; não somar no tempo).
      - *Não aditiva:* número da versão da edição (`numero_revisao`).
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

  #v(0.15em)
  - *Auditoria de Qualidade:* 7 regras automáticas de reconciliação com *100% de integridade* e *0 registros rejeitados*.
]

= Consultas Analíticas (OLAP)

== Consultas Analíticas Executadas no DW

#[
  #set text(0.76em)

  Foram desenvolvidas *10 consultas analíticas* (`sql/02_queries_olap.sql`), mapeando perguntas de negócio a recursos nativos de DW:

  #v(0.15em)

  #table(
    columns: (0.4fr, 1.35fr, 1.15fr, 1.6fr),
    align: (center, left, left, left),
    [ ID ], [ Pergunta de Negócio ], [ Recurso OLAP ], [ O que a consulta realiza? ],
    [ *Q1* ], [ Evolução histórica das edições ], [ `WITH ROLLUP` ], [ Subtotais automáticos por Ano e Trimestre em passada única ],
    [ *Q2* ], [ Concentração e ranking de autoria ], [ `DENSE_RANK()`, Pareto ], [ Classifica autores e calcula percentual acumulado de produção ],
    [ *Q3* ], [ Engajamento por área temática ], [ Agregação Dimensional ], [ Média de edições e tamanho dos textos por categoria ],
    [ *Q4* ], [ Sazonalidade semanal ], [ `SUM() OVER ()` ], [ Distribuição percentual entre dias úteis e finais de semana ],
    [ *Q5* ], [ Tendência histórica de produção ], [ Média Móvel (`ROWS`) ], [ Janela deslizante de 3 meses suavizando variações temporais ],
    [ *Q6* ], [ Variação periódica de crescimento ], [ `LAG()` / `LEAD()` ], [ Compara o volume de revisões mês a mês (MoM) e ano a ano (YoY) ],
    [ *Q9* ], [ Identificação dos artigos centrais ], [ Junção de Fatos ], [ Mapeia os verbetes de destino mais citados em `fato_referencia` ],
  )
]

== Principais Resultados e Insights Extraídos

#[
  #set text(0.77em)

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
  - *Padrão temporal (Q4, Q8, Q10):* distribuição semanal uniforme (\~14,3%/dia), pico histórico em `2022-07` (10.419 edições) e maior volume na *Madrugada* (`35,08%`, com média de `5.549` caracteres vs. `801` nos demais turnos).
]

= Benchmark: Banco Original vs. Data Warehouse

== Metodologia e Resultados dos Testes (20x)

#[
  #set text(0.79em)

  Comparativo estatístico com *20 execuções consecutivas* por consulta no mesmo servidor MariaDB, extraindo Média, Mediana e P95 (pico de lentidão):

  #v(0.15em)

  *Cenário A — Banco Original sem índices secundários (Impacto direto do DW):*
  #table(
    columns: (1.6fr, 0.7fr, 0.7fr, 0.7fr, 0.65fr, 0.65fr, 0.75fr, 0.75fr),
    align: (left, right, right, right, right, right, right, right),
    [ Consulta ], [ Orig. Méd. ], [ Orig. Med. ], [ Orig. P95 ], [ DW Med. ], [ DW P95 ], [ Ganho Med. ], [ Ganho P95 ],
    [ *B1 — Ano/Mês* ], [ 9,05 s ], [ 4,64 s ], [ 25,07 s ], [ 2,76 s ], [ 3,31 s ], [ *1,7x* ], [ *7,6x* ],
    [ *B2 — Categoria* ], [ > 300 s ], [ > 300 s ], [ > 300 s ], [ 4,17 s ], [ 4,69 s ], [ *> 72x* ], [ *> 64x* ],
    [ *B3 — Autor* ], [ 11,37 s ], [ 7,89 s ], [ 25,15 s ], [ 2,65 s ], [ 2,95 s ], [ *3,0x* ], [ *8,5x* ],
  )

  #v(0.1em)
  *Cenário B — Banco Original com índices secundários ativos:*
  - Em contagens simples de uma coluna (*B1* e *B3*), o banco original é rápido (`~0,4 s`) porque lê direto a árvore do índice (`COUNT(*)`). No DW, agregam-se métricas de negócio sobre a tabela inteira em tempo constante (`~2,5 s`).
  - Na consulta com cruzamento de categorias (*B2*), o DW continua superior: a frio, o banco original levou *25,72 s* cruzando dados de links, contra *8,73 s* no DW, mantendo o DW *1,3x melhor na média e no P95*.
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
