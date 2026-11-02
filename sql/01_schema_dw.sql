-- =====================================================================
-- Data Warehouse nLab - Modelagem Dimensional (Constelação de Fatos)
--   fato_revisao    (grão: 1 revisão)
--   fato_referencia (grão: 1 link/categoria/imagem/redirect de uma página)
-- Dimensões conformadas: dim_pagina (+ dim_tempo/dim_hora/dim_autor/dim_tipo_link)
--
-- Índices secundários e FKs são criados DEPOIS da carga em massa
-- (ver sql/01b_post_load.sql), o que acelera muito o INSERT...SELECT.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS nlab_dw
  CHARACTER SET utf8mb4;

USE nlab_dw;

-- Desabilitar temporariamente checagem de FK para recriação limpa
SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS fato_referencia;
DROP TABLE IF EXISTS fato_revisao;
DROP TABLE IF EXISTS dim_tipo_link;
DROP TABLE IF EXISTS dim_hora;
DROP TABLE IF EXISTS dim_pagina;
DROP TABLE IF EXISTS dim_autor;
DROP TABLE IF EXISTS dim_tempo;
DROP TABLE IF EXISTS stg_revisao;
DROP TABLE IF EXISTS stg_categoria_pagina;
DROP TABLE IF EXISTS etl_rejeitados;
SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------
-- 0. Área de staging e controle do ETL
-- ---------------------------------------------------------------------
-- Categoria de cada página. No OLTP, pages.category_id está NULL; a
-- categoria real está em wiki_references (link_type = 'C').
CREATE TABLE stg_categoria_pagina (
    page_id INT NOT NULL,
    categoria_nome VARCHAR(255) NOT NULL,
    PRIMARY KEY (page_id)
) ENGINE=InnoDB;

-- Revisões extraídas sem o texto (apenas o tamanho em caracteres)
CREATE TABLE stg_revisao (
    id INT NOT NULL,
    page_id INT NULL,
    author_id INT NULL,
    author_nome VARCHAR(255) NULL,
    created_at DATETIME NULL,
    tamanho INT NULL,
    PRIMARY KEY (id),
    KEY idx_stg_page (page_id)
) ENGINE=InnoDB;

-- Registros que não puderam ser carregados (rastreabilidade do ETL)
CREATE TABLE etl_rejeitados (
    id BIGINT AUTO_INCREMENT NOT NULL,
    tabela_origem VARCHAR(50) NOT NULL,
    id_origem INT NOT NULL,
    motivo VARCHAR(100) NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 1. Dimensão Tempo (calendário contínuo, gerada pelo ETL)
-- ---------------------------------------------------------------------
CREATE TABLE dim_tempo (
    sk_tempo INT NOT NULL,                  -- Formato YYYYMMDD (ex: 20260920)
    data_completa DATE NOT NULL,
    ano SMALLINT NOT NULL,
    trimestre TINYINT NOT NULL,
    mes TINYINT NOT NULL,
    nome_mes VARCHAR(20) NOT NULL,
    dia TINYINT NOT NULL,
    dia_semana VARCHAR(20) NOT NULL,
    dia_semana_num TINYINT NOT NULL,        -- 1 = Domingo, 7 = Sábado
    eh_fim_de_semana TINYINT(1) NOT NULL,   -- 1 = Sim, 0 = Não
    PRIMARY KEY (sk_tempo),
    UNIQUE KEY uk_data_completa (data_completa)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 2. Dimensão Hora do dia (24 linhas)
-- ---------------------------------------------------------------------
CREATE TABLE dim_hora (
    sk_hora TINYINT NOT NULL,               -- 0..23 (= HOUR(created_at))
    faixa_dia VARCHAR(20) NOT NULL,         -- Madrugada/Manhã/Tarde/Noite
    PRIMARY KEY (sk_hora)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 3. Dimensão Autor (SCD tipo 1)
-- A faixa de contribuição é recalculada a cada carga a partir da própria
-- fato; sobrescrever é aceitável porque a faixa é um atributo derivado e
-- não se deseja histórico de "em que faixa o autor estava". Por isso não
-- se usa SCD tipo 2.
-- ---------------------------------------------------------------------
CREATE TABLE dim_autor (
    sk_autor INT AUTO_INCREMENT NOT NULL,
    id_autor_oltp INT NULL,                 -- ID original em users (NULL para anônimos)
    nome_autor VARCHAR(255) NOT NULL,
    faixa_contribuicoes VARCHAR(50) NOT NULL DEFAULT 'Sem revisões',
    PRIMARY KEY (sk_autor)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 4. Dimensão Página (categoria desnormalizada e deduplicada por nome)
-- ---------------------------------------------------------------------
CREATE TABLE dim_pagina (
    sk_pagina INT AUTO_INCREMENT NOT NULL,
    id_pagina_oltp INT NOT NULL,            -- ID original em pages
    titulo VARCHAR(255) NOT NULL,
    slug VARCHAR(255) NULL,
    categoria_nome VARCHAR(255) NOT NULL DEFAULT 'Não categorizado',
    eh_redirect TINYINT(1) NOT NULL DEFAULT 0,
    PRIMARY KEY (sk_pagina),
    UNIQUE KEY uk_pagina_oltp (id_pagina_oltp),
    KEY idx_pagina_titulo (titulo)          -- necessário durante a carga (resolve destino dos links)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 5. Dimensão Tipo de Link
-- ---------------------------------------------------------------------
CREATE TABLE dim_tipo_link (
    sk_tipo_link INT AUTO_INCREMENT NOT NULL,
    codigo_oltp VARCHAR(50) NOT NULL,       -- wiki_references.link_type
    descricao VARCHAR(100) NOT NULL,
    PRIMARY KEY (sk_tipo_link),
    UNIQUE KEY uk_codigo (codigo_oltp)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 6. Fato Revisão
-- Grão: 1 registro por revisão efetuada em uma página por um autor.
--  - id_revisao_oltp ........ dimensão degenerada (rastreabilidade)
--  - qtd_revisoes ........... contador unitário (fato aditivo, "factless")
--  - eh_primeira_revisao .... aditivo (1 = revisão que cria a página)
--  - tamanho_conteudo ....... semi-aditivo (não somar no tempo; usar AVG/MAX)
--  - delta_tamanho .......... aditivo (variação de caracteres vs. revisão anterior)
--  - dias_desde_rev_anterior  não aditivo (NULL na primeira revisão)
--  - numero_revisao ......... não aditivo (usar MAX); sequência por página,
--                             recalculada no ETL pois revisions.number vale
--                             1 em todas as linhas do OLTP
-- ---------------------------------------------------------------------
CREATE TABLE fato_revisao (
    id_fato BIGINT AUTO_INCREMENT NOT NULL,
    sk_tempo INT NOT NULL,
    sk_hora TINYINT NOT NULL,
    sk_autor INT NOT NULL,
    sk_pagina INT NOT NULL,
    id_revisao_oltp INT NOT NULL,
    numero_revisao INT NOT NULL DEFAULT 1,
    eh_primeira_revisao TINYINT(1) NOT NULL DEFAULT 0,
    qtd_revisoes INT NOT NULL DEFAULT 1,
    tamanho_conteudo INT NOT NULL DEFAULT 0,
    delta_tamanho INT NOT NULL DEFAULT 0,
    dias_desde_rev_anterior INT NULL,
    PRIMARY KEY (id_fato),
    UNIQUE KEY uk_revisao_oltp (id_revisao_oltp)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 7. Fato Referência (segunda fato: constelação de fatos)
-- Grão: 1 registro por linha de wiki_references (link L, categoria C,
-- imagem I ou redirect R) partindo de uma página.
-- ---------------------------------------------------------------------
CREATE TABLE fato_referencia (
    id_fato_ref BIGINT AUTO_INCREMENT NOT NULL,
    sk_pagina_origem INT NOT NULL,
    sk_pagina_destino INT NULL,             -- NULL quando não resolvido (C, I ou nome inexistente)
    sk_tipo_link INT NOT NULL,
    id_referencia_oltp INT NOT NULL,        -- dimensão degenerada
    qtd_links INT NOT NULL DEFAULT 1,
    eh_destino_resolvido TINYINT(1) NOT NULL DEFAULT 0,
    PRIMARY KEY (id_fato_ref),
    UNIQUE KEY uk_referencia_oltp (id_referencia_oltp)
) ENGINE=InnoDB;
