-- =====================================================================
-- Data Warehouse nLab - Consultas Analíticas (OLAP)
-- Cada consulta começa com um marcador "-- @@QUERY <título>" (lido pelo
-- run_queries.py). Compatível com MariaDB >= 10.5.
-- =====================================================================
USE nlab_dw;

-- @@QUERY Consulta 1: Roll-up temporal (Ano > Trimestre) com WITH ROLLUP
-- Objetivo: volume de edições e páginas novas por trimestre, com subtotal
-- por ano e total geral (linhas com NULL = nível agregado do ROLLUP).
SELECT
    COALESCE(CAST(t.ano AS CHAR), 'TOTAL GERAL')            AS ano,
    COALESCE(CAST(t.trimestre AS CHAR), 'Subtotal ano')     AS trimestre,
    SUM(f.qtd_revisoes)                                     AS total_revisoes,
    SUM(f.eh_primeira_revisao)                              AS novas_paginas,
    ROUND(SUM(f.qtd_revisoes) / NULLIF(SUM(f.eh_primeira_revisao), 0), 2) AS revisoes_por_pagina_nova
FROM fato_revisao f
JOIN dim_tempo t ON f.sk_tempo = t.sk_tempo
GROUP BY t.ano, t.trimestre WITH ROLLUP;

-- @@QUERY Consulta 2: Ranking de autores e concentração (DENSE_RANK + acumulado)
-- Objetivo: ranking de colaboradores, % sobre o total e % acumulado
-- (Pareto) com SUM() OVER (ORDER BY ... ROWS UNBOUNDED PRECEDING).
WITH autor_stats AS (
    SELECT a.nome_autor, a.faixa_contribuicoes,
           SUM(f.qtd_revisoes)        AS total_revisoes_autor,
           SUM(f.eh_primeira_revisao) AS paginas_criadas_autor
    FROM fato_revisao f
    JOIN dim_autor a ON f.sk_autor = a.sk_autor
    GROUP BY a.sk_autor, a.nome_autor, a.faixa_contribuicoes
)
SELECT
    nome_autor, faixa_contribuicoes, total_revisoes_autor, paginas_criadas_autor,
    DENSE_RANK() OVER (ORDER BY total_revisoes_autor DESC) AS ranking,
    ROUND(100.0 * total_revisoes_autor / SUM(total_revisoes_autor) OVER (), 2) AS pct_total,
    ROUND(100.0 * SUM(total_revisoes_autor) OVER (
              ORDER BY total_revisoes_autor DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
          / SUM(total_revisoes_autor) OVER (), 2)           AS pct_acumulado
FROM autor_stats
ORDER BY ranking;

-- @@QUERY Consulta 3: Engajamento por categoria temática
-- Objetivo: revisões, páginas, tamanho médio do conteúdo e intervalo médio
-- entre revisões (apenas edições posteriores à criação) por categoria.
SELECT
    p.categoria_nome,
    COUNT(DISTINCT p.sk_pagina)                       AS paginas,
    SUM(f.qtd_revisoes)                               AS total_revisoes,
    ROUND(SUM(f.qtd_revisoes) / COUNT(DISTINCT p.sk_pagina), 3) AS revisoes_por_pagina,
    ROUND(AVG(f.tamanho_conteudo), 1)                 AS tamanho_medio_chars,
    ROUND(AVG(f.dias_desde_rev_anterior), 1)          AS dias_medios_entre_revisoes,
    MAX(f.numero_revisao)                             AS versao_mais_alta,
    ROUND(100.0 * SUM(f.qtd_revisoes) / SUM(SUM(f.qtd_revisoes)) OVER (), 2) AS pct_revisoes
FROM fato_revisao f
JOIN dim_pagina p ON f.sk_pagina = p.sk_pagina
GROUP BY p.categoria_nome
ORDER BY total_revisoes DESC;

-- @@QUERY Consulta 4: Sazonalidade semanal (dias úteis x fim de semana)
-- Objetivo: dias de maior intensidade colaborativa.
SELECT
    t.dia_semana, t.dia_semana_num,
    CASE WHEN t.eh_fim_de_semana = 1 THEN 'Fim de Semana' ELSE 'Dia Útil' END AS tipo_dia,
    SUM(f.qtd_revisoes) AS total_revisoes,
    ROUND(100.0 * SUM(f.qtd_revisoes) / SUM(SUM(f.qtd_revisoes)) OVER (), 2) AS pct_distribuicao_semanal
FROM fato_revisao f
JOIN dim_tempo t ON f.sk_tempo = t.sk_tempo
GROUP BY t.dia_semana, t.dia_semana_num, t.eh_fim_de_semana
ORDER BY t.dia_semana_num;

-- @@QUERY Consulta 5: Média móvel de 3 meses (janela deslizante)
-- Objetivo: suavizar ruído mensal. Parte do calendário (LEFT JOIN) para
-- que meses sem revisão apareçam com 0 e não distorçam a janela.
WITH mensal AS (
    SELECT t.ano, t.mes, COALESCE(SUM(f.qtd_revisoes), 0) AS revisoes_mes
    FROM dim_tempo t
    LEFT JOIN fato_revisao f ON f.sk_tempo = t.sk_tempo
    GROUP BY t.ano, t.mes
)
SELECT ano, mes, revisoes_mes,
       ROUND(AVG(revisoes_mes) OVER (
           ORDER BY ano, mes ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS media_movel_3_meses
FROM mensal
ORDER BY ano, mes;

-- @@QUERY Consulta 6: Crescimento mês a mês (MoM) e ano a ano (YoY) com LAG/LEAD
-- Objetivo: variação percentual do volume mensal; LEAD mostra o próximo mês.
WITH mensal AS (
    SELECT t.ano, t.mes, COALESCE(SUM(f.qtd_revisoes), 0) AS revisoes
    FROM dim_tempo t
    LEFT JOIN fato_revisao f ON f.sk_tempo = t.sk_tempo
    GROUP BY t.ano, t.mes
)
SELECT ano, mes, revisoes,
       LAG(revisoes, 1)  OVER (ORDER BY ano, mes) AS mes_anterior,
       LEAD(revisoes, 1) OVER (ORDER BY ano, mes) AS proximo_mes,
       ROUND(100.0 * (revisoes - LAG(revisoes, 1) OVER (ORDER BY ano, mes))
             / NULLIF(LAG(revisoes, 1) OVER (ORDER BY ano, mes), 0), 2)  AS var_mom_pct,
       ROUND(100.0 * (revisoes - LAG(revisoes, 12) OVER (ORDER BY ano, mes))
             / NULLIF(LAG(revisoes, 12) OVER (ORDER BY ano, mes), 0), 2) AS var_yoy_pct
FROM mensal
ORDER BY ano DESC, mes DESC;

-- @@QUERY Consulta 7: Ranking de categorias por ano (RANK ... PARTITION BY)
-- Objetivo: posição de cada categoria dentro de cada ano e participação.
WITH cat_ano AS (
    SELECT t.ano, p.categoria_nome, SUM(f.qtd_revisoes) AS revisoes
    FROM fato_revisao f
    JOIN dim_tempo t  ON f.sk_tempo = t.sk_tempo
    JOIN dim_pagina p ON f.sk_pagina = p.sk_pagina
    GROUP BY t.ano, p.categoria_nome
)
SELECT ano, categoria_nome, revisoes,
       RANK() OVER (PARTITION BY ano ORDER BY revisoes DESC) AS posicao_no_ano,
       ROUND(100.0 * revisoes / SUM(revisoes) OVER (PARTITION BY ano), 2) AS pct_do_ano
FROM cat_ano
ORDER BY ano DESC, posicao_no_ano;

-- @@QUERY Consulta 8: Quartis de intensidade mensal (NTILE + PERCENT_RANK)
-- Objetivo: classificar cada mês em quartis de volume de edições.
WITH mensal AS (
    SELECT t.ano, t.mes, SUM(f.qtd_revisoes) AS revisoes
    FROM fato_revisao f JOIN dim_tempo t ON f.sk_tempo = t.sk_tempo
    GROUP BY t.ano, t.mes
)
SELECT ano, mes, revisoes,
       NTILE(4) OVER (ORDER BY revisoes)                AS quartil,
       ROUND(PERCENT_RANK() OVER (ORDER BY revisoes), 3) AS percent_rank
FROM mensal
ORDER BY revisoes DESC
LIMIT 15;

-- @@QUERY Consulta 9: Páginas mais referenciadas (2ª fato: fato_referencia)
-- Objetivo: verbetes que mais recebem links internos (tipo L), com ranking
-- global e posição dentro da categoria (constelação de fatos).
WITH recebidos AS (
    SELECT d.sk_pagina, d.titulo, d.categoria_nome, SUM(fr.qtd_links) AS links_recebidos
    FROM fato_referencia fr
    JOIN dim_tipo_link tl ON tl.sk_tipo_link = fr.sk_tipo_link AND tl.codigo_oltp = 'L'
    JOIN dim_pagina d ON d.sk_pagina = fr.sk_pagina_destino
    GROUP BY d.sk_pagina, d.titulo, d.categoria_nome
), ranq AS (
    SELECT *, DENSE_RANK() OVER (ORDER BY links_recebidos DESC) AS ranking_global,
              ROW_NUMBER() OVER (PARTITION BY categoria_nome
                                 ORDER BY links_recebidos DESC, titulo) AS posicao_na_categoria
    FROM recebidos
)
SELECT titulo, categoria_nome, links_recebidos, ranking_global, posicao_na_categoria
FROM ranq
ORDER BY ranking_global, titulo
LIMIT 15;

-- @@QUERY Consulta 10: Atividade por faixa do dia (dim_hora)
-- Objetivo: em que período do dia a wiki é mais editada.
SELECT h.faixa_dia,
       SUM(f.qtd_revisoes) AS total_revisoes,
       ROUND(100.0 * SUM(f.qtd_revisoes) / SUM(SUM(f.qtd_revisoes)) OVER (), 2) AS pct,
       ROUND(AVG(f.tamanho_conteudo), 1) AS tamanho_medio_chars
FROM fato_revisao f
JOIN dim_hora h ON h.sk_hora = f.sk_hora
GROUP BY h.faixa_dia
ORDER BY total_revisoes DESC;
