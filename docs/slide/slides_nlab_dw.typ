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

  O *nLab* é uma wiki colaborativa de Matemática, Física Teórica e Teoria das Categorias. O banco transacional (`nlab_db`) prioriza escrita e versionamento de artigos, tornando agregações históricas custosas.

  #v(0.3em)

  #grid(
    columns: (1fr, 1fr, 1fr, 1fr),
    gutter: 0.6em,
    kpi("1.000.000", "Páginas (pages)"),
    kpi("1.536.920", "Revisões (revisions)"),
    kpi("5.931.831", "Referências / Links"),
    kpi("3.326 / 54", "Autores / Categorias"),
  )

  #v(0.35em)

  #grid(
    columns: (1.05fr, 0.95fr),
    gutter: 1em,
    [
      *Perguntas analíticas alvo:*
      - Evolução temporal de edições e criação de verbetes
      - Concentração de autoria (Pareto) e faixas de atividade
      - Engajamento e tamanho médio por categoria temática
      - Rede de referências internas (verbetes *hub*)
    ],
    [
      #quote[
        *Gargalo no OLTP:* `revisions` armazena o texto completo em `content MEDIUMTEXT` (gigabytes em páginas InnoDB), penalizando varreduras analíticas.
      ]
    ]
  )
]

== Desafios e Anomalias Encontrados no OLTP

#[
  #set text(0.82em)

  A inspeção do schema operacional (`nlab_db` no MariaDB 12.3) revelou particularidades estruturais resolvidas pelo ETL:

  #v(0.2em)

  #table(
    columns: (1.05fr, 1.3fr, 1.35fr),
    align: (left, left, left),
    [ Problema no `nlab_db` ], [ Impacto Analítico ], [ Solução no ETL / DW ],
    [ Categoria fora de `pages` ], [ Exige `JOIN` com 5,93 M linhas de `wiki_references` (`link_type = 'C'`) ], [ Desnormalização em `dim_pagina.categoria_nome` via staging ],
    [ `content MEDIUMTEXT` em `revisions` ], [ Estoura o *buffer pool* em *full scans* de agregação ], [ Extrai apenas `CHAR_LENGTH(content)` para `fato_revisao` ],
    [ Títulos binários (`utf8mb3_bin`) ], [ 631 colisões *case-insensitive* (ex.: `cat` vs. `Cat`) ], [ `dim_pagina.titulo` com collation `utf8mb4_bin` ],
    [ `target_page_id` parcial ], [ Links `R` e parte dos `L`/`I` trazem só `referenced_name` ], [ `COALESCE` entre `target_page_id` e busca exata por título ],
  )
]

= Modelagem Dimensional (Kimball)

== Arquitetura: Constelação de Fatos

#[
  #set text(0.84em)

  Adotou-se uma *Constelação de Fatos* (*Fact Constellation*) em *Star Schema*: duas tabelas fato compartilham a dimensão conformada `dim_pagina`, evitando *Snowflake* desnecessário para 54 categorias.

  #v(0.3em)

  #grid(
    columns: (1fr, 1.25fr, 1fr),
    gutter: 0.7em,
    align: horizon,
    stack(
      spacing: 0.5em,
      box-schema("dim_tempo", "10.170 dias (2008–2035)"),
      box-schema("dim_hora", "24 horas / 4 turnos"),
      box-schema("dim_autor", "3.327 autores (SCD Tipo 1)"),
    ),
    stack(
      spacing: 0.5em,
      box-schema("FATO_REVISAO", "1.536.920 linhas • Grão: 1 edição\nMedidas: qtd, tamanho, delta, intervalo", cor-fundo: navy.lighten(78%), cor-borda: navy),
      box-schema("dim_pagina (Conformada)", "1.000.000 páginas • categoria desnormalizada", cor-fundo: rgb("#eef6ee"), cor-borda: green-ok),
      box-schema("FATO_REFERENCIA", "5.931.831 linhas • Grão: 1 referência\nFK dupla: origem e destino em dim_pagina", cor-fundo: navy.lighten(78%), cor-borda: navy),
    ),
    stack(
      spacing: 0.5em,
      box-schema("dim_tipo_link", "6 tipos: L, C, R, I, W, F"),
      block(
        width: 100%,
        fill: soft-blue,
        radius: 4pt,
        inset: 7pt,
      )[
        #text(0.8em)[
          *Por que Estrela?* \
          Desnormalizar `categoria_nome` em `dim_pagina` elimina 2 `JOIN`s em toda consulta temática sem custo relevante de espaço.
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
      - *Grão:* 1 revisão de uma página por um autor em dada data/hora.
      - *Aditivas:* `qtd_revisoes` (unitária), `eh_primeira_revisao` (criação), `delta_tamanho` (variação de caracteres).
      - *Semi-aditiva:* `tamanho_conteudo` (usar `AVG`/`MAX`, não somar no tempo).
      - *Não aditivas:* `numero_revisao` e `dias_desde_rev_anterior`.
      - *Degenerada:* `id_revisao_oltp` (rastreabilidade 1:1).
    ],
    [
      *2. `fato_referencia` (5.931.831 linhas)*
      - *Grão:* 1 link/referência partindo de uma página.
      - *Role-playing FK:* `sk_pagina_origem` e `sk_pagina_destino` apontam para `dim_pagina`.
      - *Aditivas:* `qtd_links` e `eh_destino_resolvido`.
      - *Degenerada:* `id_referencia_oltp`.
    ]
  )

  #v(0.25em)

  #quote[
    Separar revisões e referências em duas fatos preserva o grão exato de cada processo de negócio e evita explosão cartesiana (`1,54 M × 5,93 M`).
  ]
]

= Pipeline de ETL e Qualidade de Dados

== Fluxo de Carga e Otimizações (`src/etl.py`)

#[
  #set text(0.79em)

  Pipeline idempotente em Python + SQL *pushdown* no MariaDB, concluído em *862,6 s* (\~14,4 min) para \~8,5 milhões de registros totais:

  #v(0.2em)

  #grid(
    columns: (1fr, 1fr, 1fr),
    gutter: 0.6em,
    [
      / 1. DDL Limpo (`0,2 s`): Recria tabelas sem índices secundários nem FKs (`01_schema_dw.sql`).
      / 2. Staging (`107,5 s`): Extrai `stg_revisao` em lotes de 500k (sem texto) e `stg_categoria_pagina` (986.748 links `C`).
    ],
    [
      / 3. Dimensões (`28,8 s`): Calendário contínuo (`dim_tempo`), `dim_hora`, `dim_autor` (`idx_autor_oltp`), `dim_pagina` e `dim_tipo_link`.
      / 4. Fatos (`120,2 s`): Window functions (`ROW_NUMBER`, `LAG`) em `fato_revisao` + 12 lotes em `fato_referencia`.
    ],
    [
      / 5. Pós-carga (`555,9 s`): Criação em lote de índices secundários e 7 FKs (`01b_post_load.sql`) + recálculo SCD1 de `dim_autor`.
      / 6. Reconciliação: `validate_load()` audita contagens, somas, órfãos e calendário; aborta (`exit 1`) se divergir.
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

= Benchmark: OLTP vs. OLAP

== Metodologia Experimental (`src/benchmark.py`)

#[
  #set text(0.82em)

  #grid(
    columns: (1fr, 1fr),
    gutter: 1em,
    [
      *Protocolo de medição:*
      - *Mesmo servidor:* MariaDB `12.3.3` (`nlab_mariadb`)
      - *Amostragem:* *20 execuções consecutivas* no OLTP e *20 no DW* por consulta (sem concorrência)
      - *Timeout:* `300 s` por consulta (`max_statement_time`)
      - *Dois cenários avaliados:*
        1. *Cenário A:* OLTP sem índices secundários (`IGNORE INDEX`)
        2. *Cenário B:* OLTP com todos os índices secundários nativos
    ],
    [
      *Por que Média, Mediana e P95?*
      / Média: Captura o impacto combinado de aquecimento e regime estável.
      / Mediana (P50): Representa o desempenho típico com *cache* aquecido.
      / P95 (Percentil 95): Mede a *latência de cauda* e a previsibilidade sob pressão de I/O.
    ]
  )

  #v(0.15em)
  - *Consultas comparadas:* *B1* — Revisões por ano/mês | *B2* — Revisões por categoria temática | *B3* — Revisões por autor.
]

== Cenário A: OLTP sem Índices Secundários (20x)

#[
  #set text(0.79em)

  Com apenas chaves `PRIMARY` no OLTP, o SGBD precisa varrer `revisions` (com `MEDIUMTEXT`) e cruzar `wiki_references` via *Block Nested Loop*:

  #v(0.2em)

  #table(
    columns: (1.4fr, 0.7fr, 0.7fr, 0.7fr, 0.65fr, 0.65fr, 0.65fr, 0.75fr, 0.75fr),
    align: (left, right, right, right, right, right, right, right, right),
    [ Consulta ], [ OLTP Méd. ], [ OLTP Med. ], [ OLTP P95 ], [ DW Méd. ], [ DW Med. ], [ DW P95 ], [ Ganho Med. ], [ Ganho P95 ],
    [ *B1 — Ano/Mês* ], [ 9,05 s ], [ 4,64 s ], [ 25,07 s ], [ 3,26 s ], [ 2,76 s ], [ 3,31 s ], [ *1,7x* ], [ *7,6x* ],
    [ *B2 — Categoria* ], [ > 300 s ], [ > 300 s ], [ > 300 s ], [ 4,49 s ], [ 4,17 s ], [ 4,69 s ], [ *> 72x* ], [ *> 64x* ],
    [ *B3 — Autor* ], [ 11,37 s ], [ 7,89 s ], [ 25,15 s ], [ 2,79 s ], [ 2,65 s ], [ 2,95 s ], [ *3,0x* ], [ *8,5x* ],
  )

  #v(0.2em)

  - *Previsibilidade (P95):* em B1 e B3, o OLTP sofre picos de *37–40 s* nas primeiras execuções (`P95 ~ 25,1 s`) por estourar o *buffer pool*, enquanto `fato_revisao` mantém `P95` entre *2,95 s e 3,31 s* (*7,6x a 8,5x mais rápido*).
  - *Eliminação de `JOIN` (B2):* o cruzamento `w:ALL × r:ALL` excede 300 s no OLTP; no DW conclui em *4,17 s* (*> 72x*).
]

== Cenário B: OLTP com Índices Secundários Nativos (20x)

#[
  #set text(0.79em)

  Com índices secundários ativos em `revisions(created_at)`, `revisions(page_id)` e `revisions(author_id)`:

  #v(0.2em)

  #table(
    columns: (1.4fr, 0.7fr, 0.7fr, 0.7fr, 0.65fr, 0.65fr, 0.65fr, 0.75fr, 0.75fr),
    align: (left, right, right, right, right, right, right, right, right),
    [ Consulta ], [ OLTP Méd. ], [ OLTP Med. ], [ OLTP P95 ], [ DW Méd. ], [ DW Med. ], [ DW P95 ], [ Ganho Méd. ], [ Ganho Med. ],
    [ *B1 — Ano/Mês* ], [ 0,70 s ], [ 0,43 s ], [ 0,73 s ], [ 2,98 s ], [ 2,61 s ], [ 3,22 s ], [ 0,2x ], [ 0,2x ],
    [ *B2 — Categoria* ], [ 5,04 s ], [ 3,92 s ], [ 5,33 s ], [ 4,02 s ], [ 3,78 s ], [ 4,12 s ], [ *1,3x* ], [ *1,0x* ],
    [ *B3 — Autor* ], [ 0,44 s ], [ 0,29 s ], [ 0,45 s ], [ 2,54 s ], [ 2,53 s ], [ 2,60 s ], [ 0,2x ], [ 0,1x ],
  )

  #v(0.2em)

  - *Leitura crítica de B1 e B3:* como o SQL OLTP faz apenas `COUNT(*)` sobre uma coluna indexada, o InnoDB executa *index-only scan* (`Using index`, `0,29–0,43 s`) sem tocar nas linhas de `revisions`. No DW, `SUM(f.qtd_revisoes)` lê os registros da tabela fato (`~2,5 s`).
  - *Vantagem do DW em B2 mesmo contra OLTP indexado:* na 1ª execução a frio, o OLTP levou *25,72 s* varrendo 5,93 M linhas de `wiki_references` (contra *8,73 s* no DW), mantendo o DW *1,3x melhor na média e no P95*.
]

== Síntese Comparativa e Conclusões

#[
  #set text(0.81em)

  #grid(
    columns: (1.08fr, 0.92fr),
    gutter: 1em,
    [
      *Quando o modelo dimensional (OLAP) se destaca:*
      1. *Consultas multi-tabela e atributos desnormalizados (B2):* reduz uma junção de 3 tabelas (> 300 s s/ índice; 25,7 s a frio c/ índice) para `~3,8–4,2 s` constantes.
      2. *Estabilidade de latência (P95):* separar o texto bruto (`MEDIUMTEXT`) das medidas numéricas mantém a tabela fato no *buffer pool* (`P95 < 4,7 s` em todos os testes).
      3. *Múltiplas medidas simultâneas:* diferente do *index-only scan* de `COUNT(*)`, o DW agrega `tamanho_conteudo`, `delta_tamanho` e `eh_primeira_revisao` no mesmo passe de `~2,5 s`.
    ],
    [
      *Resumo do Projeto:*
      / Modelagem: Constelação de fatos (`fato_revisao` + `fato_referencia`) e 5 dimensões conformadas.
      / Carga Verificada: `7.468.751` fatos carregados com *100% de reconciliação* e *0 rejeições*.
      / Ganhos Medidos (20x): Até *> 72x na mediana* (B2) e *7,6x–8,5x no P95* (B1/B3) frente ao OLTP sem índices secundários.
    ]
  )
]
