#import "lib.typ": *

#show: slides.with(
  title: "Data Warehouse Para O Banco do NLab",
  subtitle: "Modelagem Dimensional, Pipeline ETL e Consultas Analíticas (OLAP)",
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

= Contexto e Banco Operacional (OLTP)

== O Dataset do nLab e o Problema Analítico

#[
  #set text(0.88em)

  O *nLab* é uma wiki acadêmica colaborativa de Matemática, Física Teórica e Teoria das Categorias. O banco relacional (`nlab_db`) registra verbetes, histórico de edições, autores e referências cruzadas.

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
      *Questões analíticas investigadas:*
      - Como evoluiu o volume de edições e novos artigos por ano e trimestre?
      - Qual é o grau de concentração de autoria (Pareto) na comunidade?
      - Quais categorias temáticas reúnem mais artigos e revisões?
      - Quais verbetes atuam como _hubs_ mais citados na rede de links?
    ],
    [
      #quote[
        *Gargalo em consultas analíticas (OLAP):* O banco operacional é eficiente para transações pontuais de leitura e edição, mas agregações históricas exigem varrer milhões de linhas contendo o texto completo (`content`) e executar junções pesadas.
      ]
    ]
  )
]

== Modelagem Relacional do Banco Operacional (`nlab_db`)

#[
  #set text(0.78em)
  Esquema relacional normalizado (3FN) composto por 6 tabelas principais no MariaDB:
  #v(0.15em)
  #align(center)[
    #image("oltp_schema.svg", width: 97%)
  ]
]

== Desafios e Anomalias Encontrados no Banco Operacional

#[
  #set text(0.82em)

  A inspeção do banco operacional revelou desafios estruturais tratados durante a transformação para o Data Warehouse:

  #v(0.2em)

  #table(
    columns: (1.1fr, 1.35fr, 1.3fr),
    align: (left, left, left),
    [ Desafio no Banco Original ], [ Impacto nas Consultas ], [ Solução Adotada no DW ],
    [ Categorias fora da tabela `pages` (`category_id` nulo) ], [ Exigia cruzar 5,9M de linhas em `wiki_references` (`link_type = 'C'`) para obter a categoria ], [ Desnormalização da categoria temática diretamente em `dim_pagina` ],
    [ Texto bruto (`LONGTEXT`) salvo em `revisions.content` ], [ Leitura de gigabytes de texto em disco/memória durante varreduras analíticas ], [ Extração apenas do tamanho (`CHAR_LENGTH`) e variação (`delta_tamanho`) ],
    [ Coluna `revisions.number` com valor fixo igual a `1` ], [ Impedia identificar a revisão de criação da página e a sequência real de edições ], [ Recálculo de `numero_revisao` e `eh_primeira_revisao` via `ROW_NUMBER()` ],
    [ Links sem chave de destino (`target_page_id` nulo) e títulos _case-sensitive_ ], [ Impedia junções diretas entre páginas de origem e destino e misturava termos (`cat` vs. `Cat`) ], [ Resolução da chave substituta de destino pelo título com ordenação binária (`utf8mb4_bin`) ],
  )
]

= Modelagem Dimensional (Kimball)

== Arquitetura Proposta: Constelação de Fatos (Star Schema)

#[
  #set text(0.78em)
  Modelagem em *Constelação de Fatos* (*Fact Constellation*) com duas tabelas fato compartilhando a dimensão conformada `dim_pagina`:
  #v(0.15em)
  #align(center)[
    #image("dw_schema.svg", width: 98%)
  ]
]

== Tabelas Fato, Grão e Aditividade das Medidas

#[
  #set text(0.82em)

  #grid(
    columns: (1.12fr, 0.88fr),
    gutter: 1em,
    [
      *1. `fato_revisao` (1.536.920 linhas)*
      - *Grão:* 1 edição de uma página por um autor em determinada data e hora.
      - *Medidas aditivas:* `qtd_revisoes` (contador unitário), `eh_primeira_revisao` (`1` na criação da página) e `delta_tamanho` (variação de caracteres).
      - *Medida semi-aditiva:* `tamanho_conteudo` (agregada com `AVG`/`MAX`; não somável ao longo do tempo).
      - *Medidas não aditivas:* `numero_revisao` e `dias_desde_rev_anterior`.
      - *Dimensão degenerada:* `id_revisao_oltp` (rastreabilidade).
    ],
    [
      *2. `fato_referencia` (5.931.831 linhas)*
      - *Grão:* 1 referência ou link emitido por uma página da wiki.
      - *Role-playing dimensions:* `sk_pagina_origem` e `sk_pagina_destino` referenciam a mesma dimensão conformada `dim_pagina`.
      - *Medidas aditivas:* `qtd_links` e `eh_destino_resolvido` (`1` quando o verbete de destino existe no banco).
      - *Dimensão degenerada:* `id_referencia_oltp`.
    ]
  )

  #v(0.2em)

  #quote[
    *Justificativa Star Schema vs. Snowflake:* como existem apenas 54 categorias temáticas, desnormalizar `categoria_nome` em `dim_pagina` elimina um `JOIN` adicional em todas as consultas por tema, com custo de armazenamento desprezível.
  ]
]

= Pipeline de ETL e Qualidade de Dados

== Processo de Carga (`src/etl.py`) e Reconciliação OLTP vs. DW

#[
  #set text(0.71em)
  #set par(spacing: 0.42em, leading: 0.45em)
  #set table(inset: (x: 5pt, y: 3.2pt))

  Pipeline em Python + SQL (`INSERT ... SELECT` em lotes de 500k linhas), concluindo a carga de \~8,5M registros em \~14 min:

  #v(0.08em)

  #grid(
    columns: (1fr, 1fr, 1fr),
    gutter: 0.55em,
    [
      / 1. DDL (`0,2 s`): Recria `01_schema_dw.sql` sem índices secundários para acelerar a escrita.
      / 2. Staging (`107,5 s`): Extrai `CHAR_LENGTH(content)` em lotes e mapeia categorias por página.
    ],
    [
      / 3. Dimensões (`28,8 s`): Gera `dim_tempo` (10.170 dias) e `dim_hora`; popula `dim_autor`, `dim_pagina` e `dim_tipo_link`.
      / 4. Fatos (`120,2 s`): Calcula versão/deltas (`ROW_NUMBER`, `LAG`) e resolve destinos via `utf8mb4_bin`.
    ],
    [
      / 5. Pós-carga (`555,9 s`): Cria índices secundários e FKs ao final (`01b_post_load.sql`) e atualiza `dim_autor` (SCD 1).
      / 6. Validação: Executa 7 testes de reconciliação; interrompe com erro se houver divergência.
    ]
  )

  #v(0.08em)

  #table(
    columns: (1.55fr, 0.65fr, 0.45fr, 1.65fr, 0.65fr, 0.45fr),
    align: (left, right, center, left, right, center),
    [ Regra de Reconciliação (7 Testes) ], [ Valor ], [ Status ], [ Regra de Reconciliação ], [ Valor ], [ Status ],
    [ `revisions = fato_revisao` ], [ 1.536.920 ], [ *OK* ], [ `SUM(eh_primeira_revisao) = páginas` ], [ 1.000.000 ], [ *OK* ],
    [ `pages = dim_pagina` ], [ 1.000.000 ], [ *OK* ], [ Fatos órfãs de FK (`LEFT JOIN IS NULL`) ], [ 0 ], [ *OK* ],
    [ `wiki_references = fato_referencia` ], [ 5.931.831 ], [ *OK* ], [ `dim_tempo` contínua / `etl_rejeitados` ], [ 10.170 / 0 ], [ *OK* ],
  )
]

= Consultas Analíticas (OLAP)

== Catálogo das Consultas Analíticas Executadas (`02_queries_olap.sql`)

#[
  #set text(0.67em)
  #set table(inset: (x: 5pt, y: 3.1pt))

  Foram implementadas *10 consultas analíticas* cobrindo _roll-up_ hierárquico, funções de janela, séries temporais e constelação de fatos:

  #v(0.08em)

  #table(
    columns: (0.28fr, 1.42fr, 1.7fr),
    align: (center, left, left),
    [ ID ], [ Objetivo da Consulta ], [ Operações OLAP e Recursos SQL Utilizados ],
    [ *Q1* ], [ Evolução de revisões e novas páginas (Ano > Trimestre) ], [ _Roll-up_ hierárquico com `GROUP BY t.ano, t.trimestre WITH ROLLUP` ],
    [ *Q2* ], [ Ranking de produtividade de autores e curva de Pareto ], [ `DENSE_RANK()` + soma acumulada `SUM() OVER (ROWS UNBOUNDED PRECEDING)` ],
    [ *Q3* ], [ Engajamento, extensão média e periodicidade por categoria ], [ Medidas aditiva (`SUM`), semi-aditiva (`AVG(tamanho)`) e não aditiva (`MAX`) ],
    [ *Q4* ], [ Sazonalidade semanal (dias úteis vs. fim de semana) ], [ _Slice/Dice_ em `dim_tempo` + proporção com `SUM(SUM()) OVER ()` ],
    [ *Q5* ], [ Tendência suavizada do volume mensal de edições ], [ Média móvel de 3 meses (`AVG() OVER (ROWS 2 PRECEDING AND CURRENT ROW)`) ],
    [ *Q6* ], [ Taxa de variação mensal (MoM) e interanual (YoY) ], [ Comparação temporal com `LAG(revisoes, 1)`, `LEAD` e `LAG(revisoes, 12)` ],
    [ *Q7* ], [ Categorias temáticas mais ativas em cada ano ], [ Ranking particionado `RANK() OVER (PARTITION BY ano ORDER BY revisoes DESC)` ],
    [ *Q8* ], [ Classificação dos meses por quartil de intensidade ], [ Distribuição empírica com `NTILE(4)` e `PERCENT_RANK()` ],
    [ *Q9* ], [ Verbetes mais referenciados globalmente e por categoria ], [ 2ª fato (`fato_referencia` + `dim_pagina` destino) com `DENSE_RANK` e `ROW_NUMBER` ],
    [ *Q10* ], [ Distribuição de edições e tamanho médio por turno do dia ], [ _Drill-down_ horário via `dim_hora` (`Madrugada`, `Manhã`, `Tarde`, `Noite`) ],
  )
]

== Principais Resultados das Consultas Analíticas

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

  #v(0.15em)
  - *Sazonalidade e turnos (Q4, Q8, Q10):* distribuição semanal equilibrada (\~14,3%/dia), pico histórico em `2022-07` (`10.419` edições, 4º quartil) e maior volume na *Madrugada* (`35,08%` das revisões, com média de `5.549` caracteres contra `801` nos demais turnos).
]

= Desempenho e Conclusões

== Benchmark Experimental (`src/benchmark.py`): Consultas e Tempos

#[
  #set text(0.68em)
  #set table(inset: (x: 5pt, y: 3.4pt))

  Comparativo no mesmo servidor MariaDB (*20 execuções consecutivas por consulta*, timeout de `300 s`), avaliando equivalentes SQL no OLTP (`nlab_db`, sem índices via `IGNORE INDEX` e com índices secundários) e no DW (`nlab_dw`):

  #v(0.08em)

  #table(
    columns: (0.28fr, 0.95fr, 1.45fr, 1.42fr),
    align: (center, left, left, left),
    [ ID ], [ Objetivo da Consulta ], [ Consulta no OLTP (`nlab_db`) ], [ Consulta Equivalente no DW (`nlab_dw`) ],
    [ *B1* ], [ Total de revisões por ano e mês ], [ `COUNT(*)` em `revisions` (`1,54M` linhas) calculando `YEAR(created_at)` e `MONTH(created_at)` ], [ `SUM(qtd_revisoes)` em `fato_revisao` + `JOIN dim_tempo` agrupando por `t.ano, t.mes` ],
    [ *B2* ], [ Total de revisões por categoria temática ], [ `COUNT(*)` com `JOIN` triplo: `revisions` × `wiki_references` (`link_type = 'C'`, `5,93M`) × `categories` ], [ `SUM(qtd_revisoes)` em `fato_revisao` + `JOIN` único em `dim_pagina` por `p.categoria_nome` ],
    [ *B3* ], [ Total de revisões por autor ], [ `COUNT(*)` em `revisions` + `JOIN users` (`u.id = r.author_id`) agrupando por `u.name` ], [ `SUM(qtd_revisoes)` em `fato_revisao` + `JOIN dim_autor` (`sk_autor`) agrupando por `a.nome_autor` ],
  )

  #v(0.12em)

  #table(
    columns: (1.46fr, 0.62fr, 0.62fr, 0.56fr, 0.56fr, 0.85fr, 0.62fr, 0.56fr, 0.64fr),
    align: (left, right, right, right, right, right, right, right, right),
    [ Consulta ], [ OLTP s/ Índ. Med. ], [ OLTP s/ Índ. P95 ], [ DW Med. ], [ DW P95 ], [ Speedup s/ Índ. (Med. / P95) ], [ OLTP c/ Índ. Méd. ], [ DW Méd. ], [ Speedup c/ Índ. ],
    [ *B1 — Revisões por Ano/Mês* ], [ 4,64 s ], [ 25,07 s ], [ 2,76 s ], [ 3,31 s ], [ *1,7x / 7,6x* ], [ 0,70 s ], [ 2,98 s ], [ 0,2x ],
    [ *B2 — Revisões por Categoria* ], [ > 300 s ], [ > 300 s ], [ 4,17 s ], [ 4,69 s ], [ *> 72x / > 64x* ], [ 5,04 s ], [ 4,02 s ], [ *1,3x* ],
    [ *B3 — Revisões por Autor* ], [ 7,89 s ], [ 25,15 s ], [ 2,65 s ], [ 2,95 s ], [ *3,0x / 8,5x* ], [ 0,44 s ], [ 2,54 s ], [ 0,2x ],
  )
]

== Análise de Desempenho e Conclusões do Projeto

#[
  #set text(0.79em)

  #grid(
    columns: (1.14fr, 0.86fr),
    gutter: 0.95em,
    [
      *Análise dos Resultados do Benchmark:*
      - *Junções multi-tabela (`B2` — Categoria):* sem índices secundários, o `JOIN` triplo passando por `wiki_references` (`5,93M` linhas) excede `300 s` no OLTP; no DW responde em `4,17 s` (*> 72x mais rápido*). Com índices, a 1ª execução a frio custa `25,72 s` no OLTP contra `8,73 s` no DW (*1,3x melhor na média e no P95*).
      - *Estabilidade de P95 (`B1` e `B3` sem índices):* sem o texto bruto (`content`) na fato, o DW evita estouro de _buffer pool_ (`P95 < 3,3 s` vs. `~25,1 s` no OLTP — *7,6x a 8,5x mais rápido*).
      - *`COUNT(*)` em índice vs. medidas explícitas (`B1` e `B3` c/ índices):* o OLTP varre apenas a árvore do índice secundário (_index-only scan_), enquanto o DW soma `SUM(qtd_revisoes)` na tabela fato em tempo constante (`~2,6 s`), mantendo o mesmo custo ao agregar múltiplas medidas.
    ],
    [
      *Conclusões do Projeto:*
      - *Modelagem Dimensional:* Constelação de fatos (`fato_revisao` + `fato_referencia`) com `dim_pagina` conformada em Star Schema, eliminando junções caras por categoria e tempo.
      - *Qualidade e Confiabilidade:* \~7,5M de fatos carregados em \~14 min com *100% de reconciliação* nos 7 testes automatizados e *0 rejeições*.
      - *Capacidade Analítica:* Suporte direto a análises multidimensionais complexas (`WITH ROLLUP`, médias móveis, MoM/YoY, Pareto e centralidade de links).
    ]
  )
]
