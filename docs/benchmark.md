# Relatório de Benchmark: OLTP (`nlab_db`) vs. OLAP (`nlab_dw`)

Comparativo de desempenho entre o banco operacional normalizado (**OLTP — `nlab_db`**) e o Data Warehouse em Constelação de Fatos (**OLAP — `nlab_dw`**), executados sobre a mesma instância **MariaDB 12.3.3** (`nlab_mariadb`).

---

## 1. Ambiente e Volume de Dados

- **SGBD:** MariaDB `12.3.3` (container Docker `nlab_mariadb`)
- **Metodologia:** mediana de **3 execuções** no DW (`nlab_dw`) e **1 execução** no OLTP (`nlab_db`), com timeout de **300 s** por consulta (`src/benchmark.py`).
- **Carga do ETL:** concluída em `862,6 s` com **100% de reconciliação** e **0 registros rejeitados**.

| Entidade (OLTP → DW) | Volume de Registros | Observações |
| :--- | ---: | :--- |
| `pages` → `dim_pagina` | 1.000.000 | Categoria desnormalizada em `dim_pagina.categoria_nome` (54 categorias + `Não categorizado`) |
| `revisions` → `fato_revisao` | 1.536.920 | No OLTP inclui `content MEDIUMTEXT`; no DW armazena apenas medidas numéricas e chaves substitutas |
| `wiki_references` → `fato_referencia` | 5.931.831 | 6 tipos de link (`L`, `C`, `R`, `I`, `W`, `F`) |
| `users` → `dim_autor` | 3.326 → 3.327 | Inclui registro `sk_autor = 1` para autor anônimo |
| `dim_tempo` / `dim_hora` | 10.170 / 24 | Calendário contínuo (`2008-01-02` a `2035-11-05`) e 24 horas do dia |

---

## 2. Consultas Avaliadas

| ID | Consulta Analítica | SQL OLTP (`nlab_db`) | SQL OLAP (`nlab_dw`) |
| :--- | :--- | :--- | :--- |
| **B1** | Revisões por ano/mês | `SELECT YEAR(created_at) a, MONTH(created_at) m, COUNT(*) n FROM nlab_db.revisions GROUP BY a, m` | `SELECT t.ano, t.mes, SUM(f.qtd_revisoes) FROM nlab_dw.fato_revisao f JOIN nlab_dw.dim_tempo t ON t.sk_tempo = f.sk_tempo GROUP BY t.ano, t.mes` |
| **B2** | Revisões por categoria | `SELECT c.name, COUNT(*) n FROM nlab_db.revisions r JOIN nlab_db.wiki_references w ON w.page_id = r.page_id AND w.link_type = 'C' JOIN nlab_db.categories c ON c.id = w.category_id GROUP BY c.name` | `SELECT p.categoria_nome, SUM(f.qtd_revisoes) FROM nlab_dw.fato_revisao f JOIN nlab_dw.dim_pagina p ON p.sk_pagina = f.sk_pagina GROUP BY p.categoria_nome` |
| **B3** | Revisões por autor | `SELECT u.name, COUNT(*) n FROM nlab_db.revisions r JOIN nlab_db.users u ON u.id = r.author_id GROUP BY u.name` | `SELECT a.nome_autor, SUM(f.qtd_revisoes) FROM nlab_dw.fato_revisao f JOIN nlab_dw.dim_autor a ON a.sk_autor = f.sk_autor GROUP BY a.nome_autor` |

---

## 3. Resultados Consolidados

### Cenário A — OLTP sem índices secundários (`--no-oltp-indexes`)
 Todos os índices secundários das tabelas operacionais foram ignorados via `IGNORE INDEX`, mantendo apenas as chaves primárias (`PRIMARY`) no OLTP para avaliar o custo real de varredura sobre tabelas operacionais volumosas e junções normalizadas.

| Consulta | OLTP sem índices (s) | DW (s) | Speedup (OLTP / DW) |
| :--- | ---: | ---: | ---: |
| **B1 - Revisões por ano/mês** | 48,62 | 2,52 | **19,3x** |
| **B2 - Revisões por categoria** | > 300,00 (timeout) | 3,61 | **> 83x** |
| **B3 - Revisões por autor** | 44,17 | 2,47 | **17,9x** |

#### Planos de execução (`tabela:tipo/chave/linhas estimadas`) — Cenário A
- **B1 - Revisões por ano/mês**
  - OLTP: `revisions:ALL/-/~2557610`
  - DW: `t:ALL/-/~10279; f:ref/idx_fato_tempo/~103`
- **B2 - Revisões por categoria**
  - OLTP: `w:ALL/-/~5509454; c:eq_ref/PRIMARY/~1; r:ALL/-/~2557610`
  - DW: `p:index/idx_pagina_categoria/~982139; f:ref/idx_fato_pagina/~1`
- **B3 - Revisões por autor**
  - OLTP: `r:ALL/-/~2557610; u:eq_ref/PRIMARY/~1`
  - DW: `f:ALL/-/~1530379; a:eq_ref/PRIMARY/~1`

---

### Cenário B — OLTP com índices secundários nativos
Execução com todos os índices secundários existentes no `nlab_db` ativos (`index_revisions_on_created_at`, `index_revisions_on_page_id`, `fk_revisions_author`, `index_wiki_references_on_page_id`, etc.).

| Consulta | OLTP indexado (s) | DW (s) | Speedup (OLTP / DW) |
| :--- | ---: | ---: | ---: |
| **B1 - Revisões por ano/mês** | 1,02 | 2,52 | 0,4x |
| **B2 - Revisões por categoria** | 11,25 | 3,58 | **3,1x** |
| **B3 - Revisões por autor** | 1,38 | 2,42 | 0,6x |

#### Planos de execução (`tabela:tipo/chave/linhas estimadas`) — Cenário B
- **B1 - Revisões por ano/mês**
  - OLTP: `revisions:index/index_revisions_on_created_at/~2557610` *(Using index)*
  - DW: `t:ALL/-/~10279; f:ref/idx_fato_tempo/~103`
- **B2 - Revisões por categoria**
  - OLTP: `w:ALL/-/~5509454; c:eq_ref/PRIMARY/~1; r:ref/index_revisions_on_page_id/~2` *(Using index)*
  - DW: `p:index/idx_pagina_categoria/~982139; f:ref/idx_fato_pagina/~1`
- **B3 - Revisões por autor**
  - OLTP: `u:index/index_users_on_name/~3326; r:ref/fk_revisions_author/~708` *(Using index)*
  - DW: `f:ALL/-/~1530379; a:eq_ref/PRIMARY/~1`

---

## 4. Comparativo Geral e Análise Técnica

| Consulta | OLTP s/ índices (s) | OLTP c/ índices (s) | DW OLAP (s) | Ganho DW vs. OLTP s/ índ. | Ganho DW vs. OLTP c/ índ. |
| :--- | ---: | ---: | ---: | ---: | ---: |
| **B1 - Ano/Mês** | 48,62 | 1,02 | **2,52** | **19,3x** | 0,4x |
| **B2 - Categoria** | > 300,00 | 11,25 | **3,58 – 3,61** | **> 83x** | **3,1x** |
| **B3 - Autor** | 44,17 | 1,38 | **2,42 – 2,47** | **17,9x** | 0,6x |

### Principais conclusões
1. **Impacto do payload textual (`content MEDIUMTEXT`) nas varreduras (Cenário A — B1 e B3):**
   No banco operacional sem índices secundários, o MariaDB precisa percorrer o índice clusterizado de `revisions`, cujas páginas InnoDB carregam os textos completos dos artigos. Isso eleva uma agregação simples para **44–49 s**, enquanto `fato_revisao` (composta apenas por inteiros compactos, sem o texto bruto) resolve a mesma carga em **~2,5 s** (**17,9x a 19,3x mais rápido**).
2. **Eliminação de junções pesadas por desnormalização (B2 nos dois cenários):**
   No OLTP, a categoria de uma página não está em `pages`, exigindo cruzar `revisions` (1,54 M linhas) com `wiki_references` (5,93 M linhas, filtrando `link_type = 'C'`) e `categories`. Sem índices secundários, o cruzamento `ALL × ALL` ultrapassa **300 s** (**> 83x** a favor do DW). Mesmo com índices secundários no OLTP, a consulta ainda precisa varrer os 5,93 milhões de registros de `wiki_references` (`11,25 s`), enquanto no DW a categoria já está desnormalizada em `dim_pagina`, reduzindo o tempo para **3,58 s** (**3,1x mais rápido**).
3. ***Index-only scan* vs. leitura de medidas na tabela fato (Cenário B — B1 e B3):**
   Quando o OLTP conta apenas linhas (`COUNT(*)`) sobre colunas já cobertas por um índice secundário (`created_at` ou `author_id`), o InnoDB executa *index-only scan* (`Using index`) sem tocar nas páginas da tabela `revisions` (`1,02 s` e `1,38 s`). No DW, as consultas somam a medida `SUM(f.qtd_revisoes)` (e em consultas reais também agregam `tamanho_conteudo`, `delta_tamanho`, `eh_primeira_revisao`), lendo os registros de `fato_revisao` em **~2,4–2,5 s** com tempo previsível independentemente de quantas medidas sejam agregadas simultaneamente.

---

## 5. Como Reproduzir

```bash
# Benchmark padrão (com os índices existentes no OLTP)
.venv/bin/python3 src/benchmark.py --timeout 300 --out docs/benchmark_com_indices.md

# Benchmark ignorando os índices secundários do OLTP
.venv/bin/python3 src/benchmark.py --timeout 300 --no-oltp-indexes --out docs/benchmark_sem_indices.md
```
