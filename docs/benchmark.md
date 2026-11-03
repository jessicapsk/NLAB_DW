# Relatório de Benchmark: OLTP (`nlab_db`) vs. OLAP (`nlab_dw`)

Comparativo estatístico de desempenho (**20 execuções por consulta**, extraindo **média, mediana e percentil 95 — P95**) entre o banco operacional normalizado (**OLTP — `nlab_db`**) e o Data Warehouse em Constelação de Fatos (**OLAP — `nlab_dw`**), executados sobre a mesma instância **MariaDB 12.3.3** (`nlab_mariadb`).

---

## 1. Ambiente, Metodologia e Volume de Dados

- **SGBD:** MariaDB `12.3.3` (container Docker `nlab_mariadb`)
- **Amostragem:** **20 execuções consecutivas** no OLTP (`--oltp-runs 20`) e **20 execuções consecutivas** no DW (`--runs 20`) para cada consulta, sem concorrência entre cenários.
- **Métricas calculadas (`src/benchmark.py`):**
  - **Média aritmética:** sensível ao custo de aquecimento de cache (*cold cache* nas primeiras iterações).
  - **Mediana (P50):** reflete o regime estacionário (*warm cache*).
  - **P95 (percentil 95, interpolação linear):** captura a latência de cauda e instabilidade de I/O.
- **Timeout:** **300 s** por consulta (`max_statement_time = 300`).

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

## 3. Resultados (20 Execuções por Consulta)

### Cenário A — OLTP sem índices secundários (`--no-oltp-indexes`)
Todos os índices secundários do `nlab_db` são ignorados via `IGNORE INDEX`, mantendo apenas as chaves primárias (`PRIMARY`) no OLTP.

| Consulta | OLTP Média (s) | OLTP Mediana (s) | OLTP P95 (s) | DW Média (s) | DW Mediana (s) | DW P95 (s) | Speedup (Média) | Speedup (Mediana) | Speedup (P95) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **B1 - Revisões por ano/mês** | 9,05 | 4,64 | 25,07 | 3,26 | 2,76 | 3,31 | **2,8x** | **1,7x** | **7,6x** |
| **B2 - Revisões por categoria** | > 300 | > 300 | > 300 | 4,49 | 4,17 | 4,69 | **> 67x** | **> 72x** | **> 64x** |
| **B3 - Revisões por autor** | 11,37 | 7,89 | 25,15 | 2,79 | 2,65 | 2,95 | **4,1x** | **3,0x** | **8,5x** |

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
Execução com todos os índices secundários nativos do `nlab_db` ativos (`index_revisions_on_created_at`, `index_revisions_on_page_id`, `fk_revisions_author`, `index_wiki_references_on_page_id`, etc.).

| Consulta | OLTP Média (s) | OLTP Mediana (s) | OLTP P95 (s) | DW Média (s) | DW Mediana (s) | DW P95 (s) | Speedup (Média) | Speedup (Mediana) | Speedup (P95) |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **B1 - Revisões por ano/mês** | 0,70 | 0,43 | 0,73 | 2,98 | 2,61 | 3,22 | 0,2x | 0,2x | 0,2x |
| **B2 - Revisões por categoria** | 5,04 | 3,92 | 5,33 | 4,02 | 3,78 | 4,12 | **1,3x** | **1,0x** | **1,3x** |
| **B3 - Revisões por autor** | 0,44 | 0,29 | 0,45 | 2,54 | 2,53 | 2,60 | 0,2x | 0,1x | 0,2x |

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

## 4. Análise Estatística (Média, Mediana e P95)

1. **Estabilidade de cauda (P95) do DW vs. volatilidade do OLTP sem índices (Cenário A):**
   - No OLTP sem índices secundários, a tabela `revisions` (que carrega `content MEDIUMTEXT` nas páginas InnoDB) estoura o *buffer pool* do SGBD e passa a depender do cache de páginas do sistema operacional. Nas primeiras iterações (*cold/lukewarm cache*), **B1** e **B3** levam de **18 s a 40 s**, elevando o **P95 para ~25,1 s** (5,4x acima da mediana em B1).
   - No DW, `fato_revisao` contém apenas inteiros enxutos e cabe confortavelmente em memória: a diferença entre mediana e P95 é mínima (`2,76 s` vs. `3,31 s` em B1; `2,65 s` vs. `2,95 s` em B3), resultando em **speedups de P95 de 7,6x (B1) e 8,5x (B3)**.
2. **Custo de junções multi-tabela em **B2** (Revisões por categoria):**
   - Sem índices secundários no OLTP, o *Block Nested Loop* entre `wiki_references` (5,93 M linhas) e `revisions` (1,54 M linhas) estoura o limite de **300 s** já na 1ª execução (**speedup > 72x na mediana e > 64x no P95**).
   - Com índices secundários no OLTP, após aquecer o cache a mediana aproxima-se do DW (`3,92 s` vs. `3,78 s`), porém a **1ª execução a frio custou 25,72 s no OLTP contra 8,73 s no DW**, deixando o DW **1,3x melhor tanto na média (`4,02 s` vs. `5,04 s`) quanto no P95 (`4,12 s` vs. `5,33 s`)** graças à categoria desnormalizada em `dim_pagina`.
3. ***Index-only scan* no OLTP indexado (Cenário B — B1 e B3):**
   - Como B1 e B3 no OLTP fazem apenas `COUNT(*)` sobre colunas cobertas por índices secundários leves (`created_at` e `author_id`), o MariaDB resolve a agregação varrendo apenas a árvore do índice secundário (`0,29–0,43 s` na mediana), sem ler as linhas da tabela `revisions`. No DW, a consulta soma a medida explícita `SUM(f.qtd_revisoes)` acessando `fato_revisao` em tempo constante (`~2,5–2,6 s`), comportamento que permanece estável mesmo quando múltiplas medidas (`tamanho_conteudo`, `delta_tamanho`, `eh_primeira_revisao`) são agregadas juntas.

---

## 5. Como Reproduzir

```bash
# 20 execuções com índices secundários do OLTP ativos
.venv/bin/python3 src/benchmark.py --runs 20 --oltp-runs 20 --timeout 300 --out docs/benchmark_com_indices.md

# 20 execuções ignorando índices secundários do OLTP
.venv/bin/python3 src/benchmark.py --runs 20 --oltp-runs 20 --timeout 300 --no-oltp-indexes --out docs/benchmark_sem_indices.md
```
