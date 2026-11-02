#!/usr/bin/env python3
"""
ETL Pipeline: nlab_db (OLTP) -> nlab_dw (OLAP, constelação de fatos)

Etapas:
  1. DDL: recria o schema dimensional (sql/01_schema_dw.sql).
  2. Staging: extrai revisões (sem o texto) e a categoria real de cada página.
  3. Dimensões: dim_tempo (calendário contínuo), dim_hora, dim_autor,
     dim_pagina, dim_tipo_link.
  4. Fatos: fato_revisao e fato_referencia (em lotes).
  5. Pós-carga: índices secundários + FKs (sql/01b_post_load.sql) e recálculo
     da faixa de contribuição dos autores (SCD tipo 1).
  6. Validação: reconciliação OLTP x DW. Sai com código 1 se houver divergência.

Credenciais: variáveis de ambiente NLAB_DB_HOST / NLAB_DB_PORT / NLAB_DB_USER /
NLAB_DB_PASSWORD (ou flags de linha de comando).
"""

import argparse
import os
import re
import sys
import time
from datetime import date, timedelta

import pymysql

BATCH_REF = 500_000

MESES = ["Janeiro", "Fevereiro", "Março", "Abril", "Maio", "Junho", "Julho",
         "Agosto", "Setembro", "Outubro", "Novembro", "Dezembro"]
DIAS = ["Segunda-feira", "Terça-feira", "Quarta-feira", "Quinta-feira",
        "Sexta-feira", "Sábado", "Domingo"]  # índice = date.weekday()

TIPOS_LINK = {
    "L": "Link interno entre verbetes",
    "C": "Categoria",
    "I": "Imagem / inclusão",
    "R": "Redirecionamento",
    "F": "Arquivo / anexo",
    "W": "Link externo / interwiki",
}


def log_step(msg, t0=None):
    now = time.strftime("%H:%M:%S")
    if t0 is None:
        print(f"[{now}] ➔ {msg}...", flush=True)
    else:
        print(f"[{now}] ✔ {msg} ({time.time() - t0:.1f}s)", flush=True)


def split_sql(text):
    """Remove comentários '--' e separa os comandos por ';'."""
    no_comments = "\n".join(re.sub(r"--.*$", "", ln) for ln in text.splitlines())
    return [c.strip() for c in no_comments.split(";") if c.strip()]


def run_script(conn, path):
    with open(path, "r", encoding="utf-8") as f:
        cmds = split_sql(f.read())
    with conn.cursor() as cur:
        for cmd in cmds:
            cur.execute(cmd)


def scalar(conn, sql):
    with conn.cursor() as cur:
        cur.execute(sql)
        return cur.fetchone()[0]


def table_exists(conn, schema, table):
    return scalar(conn, f"SELECT COUNT(*) FROM information_schema.tables "
                        f"WHERE table_schema='{schema}' AND table_name='{table}'") > 0


def column_exists(conn, schema, table, column):
    return scalar(conn, f"SELECT COUNT(*) FROM information_schema.columns "
                        f"WHERE table_schema='{schema}' AND table_name='{table}' "
                        f"AND column_name='{column}'") > 0


# ---------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------
def load_staging(conn, has_refs):
    t0 = time.time()
    log_step("Staging: revisões (tamanho do conteúdo)")
    has_rev_author = column_exists(conn, "nlab_db", "revisions", "author")
    author_expr = "NULLIF(TRIM(r.author), '')" if has_rev_author else "NULL"
    lo = scalar(conn, "SELECT COALESCE(MIN(id),0) FROM nlab_db.revisions")
    hi = scalar(conn, "SELECT COALESCE(MAX(id),0) FROM nlab_db.revisions")
    n = 0
    with conn.cursor() as cur:
        start = lo
        while start <= hi:
            end = start + BATCH_REF - 1
            cur.execute(f"""
                INSERT INTO nlab_dw.stg_revisao
                    (id, page_id, author_id, author_nome, created_at, tamanho)
                SELECT r.id, r.page_id, r.author_id, {author_expr},
                       r.created_at, COALESCE(CHAR_LENGTH(r.content), 0)
                FROM nlab_db.revisions r
                WHERE r.id BETWEEN %s AND %s
            """, (start, end))
            n += cur.rowcount
            log_step(f"  lote revisões {start:,}..{min(end, hi):,}: {n:,} acumulado")
            start = end + 1
    log_step(f"stg_revisao ({n:,} linhas)", t0)

    t0 = time.time()
    log_step("Staging: categoria real de cada página")
    has_page_cat = column_exists(conn, "nlab_db", "pages", "category_id")
    with conn.cursor() as cur:
        # 1) categoria pelo próprio cadastro da página (se existir)
        n1 = 0
        if has_page_cat:
            cur.execute("""
                INSERT INTO nlab_dw.stg_categoria_pagina (page_id, categoria_nome)
                SELECT p.id, MIN(c.name)
                FROM nlab_db.pages p JOIN nlab_db.categories c ON c.id = p.category_id
                GROUP BY p.id
            """)
            n1 = cur.rowcount
        # 2) categoria via link tipo 'C' em wiki_references (nomes deduplicados)
        n2 = 0
        if has_refs:
            cur.execute("""
                INSERT IGNORE INTO nlab_dw.stg_categoria_pagina (page_id, categoria_nome)
                SELECT w.page_id, MIN(c.name)
                FROM nlab_db.wiki_references w
                JOIN nlab_db.categories c ON c.id = w.category_id
                WHERE w.link_type = 'C' AND w.page_id IS NOT NULL
                GROUP BY w.page_id
            """)
            n2 = cur.rowcount
    log_step(f"stg_categoria_pagina ({n1:,} por pages + {n2:,} por links C)", t0)


# ---------------------------------------------------------------------
# Dimensões
# ---------------------------------------------------------------------
def populate_dim_tempo(conn):
    t0 = time.time()
    log_step("dim_tempo (calendário contínuo)")
    with conn.cursor() as cur:
        cur.execute("SELECT DATE(MIN(created_at)), DATE(MAX(created_at)) "
                    "FROM nlab_db.revisions WHERE created_at IS NOT NULL")
        d0, d1 = cur.fetchone()
        rows = []
        d = d0
        while d <= d1:
            wd = d.weekday()  # 0 = segunda
            dow_mysql = ((wd + 1) % 7) + 1  # 1 = domingo ... 7 = sábado
            rows.append((int(d.strftime("%Y%m%d")), d, d.year, (d.month - 1) // 3 + 1,
                         d.month, MESES[d.month - 1], d.day, DIAS[wd], dow_mysql,
                         1 if wd >= 5 else 0))
            d += timedelta(days=1)
        cur.executemany("""
            INSERT INTO nlab_dw.dim_tempo (sk_tempo, data_completa, ano, trimestre, mes,
                nome_mes, dia, dia_semana, dia_semana_num, eh_fim_de_semana)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""", rows)
    log_step(f"dim_tempo ({len(rows):,} dias, {d0} a {d1})", t0)


def populate_dim_hora(conn):
    def faixa(h):
        return "Madrugada" if h < 6 else "Manhã" if h < 12 else "Tarde" if h < 18 else "Noite"
    with conn.cursor() as cur:
        cur.executemany("INSERT INTO nlab_dw.dim_hora (sk_hora, faixa_dia) VALUES (%s,%s)",
                        [(h, faixa(h)) for h in range(24)])
    log_step("dim_hora (24 linhas)", time.time())


def populate_dim_autor(conn):
    t0 = time.time()
    log_step("dim_autor")
    with conn.cursor() as cur:
        cur.execute("""INSERT INTO nlab_dw.dim_autor
            (sk_autor, id_autor_oltp, nome_autor, faixa_contribuicoes)
            VALUES (1, NULL, 'Autor Anônimo / Desconhecido', 'Anônimo')""")
        cur.execute("""INSERT INTO nlab_dw.dim_autor (id_autor_oltp, nome_autor)
                       SELECT u.id, u.name FROM nlab_db.users u""")
        # autores citados só por nome textual nas revisões
        cur.execute("""INSERT INTO nlab_dw.dim_autor (id_autor_oltp, nome_autor)
            SELECT NULL, s.author_nome
            FROM (SELECT DISTINCT author_nome FROM nlab_dw.stg_revisao
                  WHERE author_nome IS NOT NULL AND author_id IS NULL) s
            WHERE NOT EXISTS (SELECT 1 FROM nlab_dw.dim_autor da
                              WHERE da.nome_autor = s.author_nome)""")
    n = scalar(conn, "SELECT COUNT(*) FROM nlab_dw.dim_autor")
    log_step(f"dim_autor ({n} autores)", t0)


def populate_dim_pagina(conn):
    t0 = time.time()
    log_step("dim_pagina")
    slug_expr = "p.slug" if column_exists(conn, "nlab_db", "pages", "slug") else "NULL"
    redir_expr = ("COALESCE(p.is_redirect, 0)"
                  if column_exists(conn, "nlab_db", "pages", "is_redirect") else "0")
    with conn.cursor() as cur:
        cur.execute(f"""
            INSERT INTO nlab_dw.dim_pagina
                (id_pagina_oltp, titulo, slug, categoria_nome, eh_redirect)
            SELECT p.id, p.name, {slug_expr},
                   COALESCE(sc.categoria_nome, 'Não categorizado'),
                   {redir_expr}
            FROM nlab_db.pages p
            LEFT JOIN nlab_dw.stg_categoria_pagina sc ON sc.page_id = p.id
        """)
        n = cur.rowcount
    log_step(f"dim_pagina ({n:,} páginas)", t0)


def populate_dim_tipo_link(conn, has_refs):
    if not has_refs:
        return
    with conn.cursor() as cur:
        cur.execute("SELECT DISTINCT COALESCE(link_type, 'N/D') FROM nlab_db.wiki_references")
        codes = [r[0] for r in cur.fetchall()]
        cur.executemany(
            "INSERT INTO nlab_dw.dim_tipo_link (codigo_oltp, descricao) VALUES (%s,%s)",
            [(c, TIPOS_LINK.get(c, "Outro / não classificado")) for c in sorted(codes)])
    log_step(f"dim_tipo_link ({len(codes)} tipos)", time.time())


# ---------------------------------------------------------------------
# Fatos
# ---------------------------------------------------------------------
def populate_fato_revisao(conn):
    t0 = time.time()
    log_step("fato_revisao")
    with conn.cursor() as cur:
        # Rejeitados: sem data ou sem página correspondente
        cur.execute("""
            INSERT INTO nlab_dw.etl_rejeitados (tabela_origem, id_origem, motivo)
            SELECT 'revisions', s.id,
                   CASE WHEN s.created_at IS NULL THEN 'created_at nulo'
                        ELSE 'page_id sem página correspondente' END
            FROM nlab_dw.stg_revisao s
            LEFT JOIN nlab_dw.dim_pagina dp ON dp.id_pagina_oltp = s.page_id
            WHERE s.created_at IS NULL OR dp.sk_pagina IS NULL
        """)
        # numero_revisao/delta/intervalo calculados com window functions
        # (revisions.number vale 1 em todas as linhas do OLTP).
        cur.execute("""
            INSERT INTO nlab_dw.fato_revisao
                (sk_tempo, sk_hora, sk_autor, sk_pagina, id_revisao_oltp, numero_revisao,
                 eh_primeira_revisao, qtd_revisoes, tamanho_conteudo, delta_tamanho,
                 dias_desde_rev_anterior)
            SELECT dt.sk_tempo, HOUR(s.created_at),
                   COALESCE(da_id.sk_autor, da_nome.sk_autor, 1),
                   dp.sk_pagina, s.id, s.rn, IF(s.rn = 1, 1, 0), 1,
                   s.tamanho, s.tamanho - COALESCE(s.tam_ant, 0),
                   DATEDIFF(s.created_at, s.ts_ant)
            FROM (
                SELECT id, page_id, author_id, author_nome, created_at, tamanho,
                       ROW_NUMBER() OVER w AS rn,
                       LAG(tamanho)    OVER w AS tam_ant,
                       LAG(created_at) OVER w AS ts_ant
                FROM nlab_dw.stg_revisao
                WHERE created_at IS NOT NULL
                WINDOW w AS (PARTITION BY page_id ORDER BY created_at, id)
            ) s
            JOIN nlab_dw.dim_pagina dp ON dp.id_pagina_oltp = s.page_id
            JOIN nlab_dw.dim_tempo  dt ON dt.data_completa = DATE(s.created_at)
            LEFT JOIN nlab_dw.dim_autor da_id ON da_id.id_autor_oltp = s.author_id
            LEFT JOIN (SELECT nome_autor, MIN(sk_autor) AS sk_autor
                       FROM nlab_dw.dim_autor GROUP BY nome_autor) da_nome
                   ON s.author_nome IS NOT NULL AND da_nome.nome_autor = s.author_nome
        """)
        n = cur.rowcount
    log_step(f"fato_revisao ({n:,} fatos)", t0)


def populate_fato_referencia(conn):
    t0 = time.time()
    log_step("fato_referencia (em lotes)")
    lo = scalar(conn, "SELECT COALESCE(MIN(id),0) FROM nlab_db.wiki_references")
    hi = scalar(conn, "SELECT COALESCE(MAX(id),0) FROM nlab_db.wiki_references")
    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO nlab_dw.etl_rejeitados (tabela_origem, id_origem, motivo)
            SELECT 'wiki_references', w.id, 'page_id sem página correspondente'
            FROM nlab_db.wiki_references w
            LEFT JOIN nlab_dw.dim_pagina dp ON dp.id_pagina_oltp = w.page_id
            WHERE dp.sk_pagina IS NULL
        """)
        total = 0
        start = lo
        # destino resolvido via target_page_id (quando preenchido) ou por nome
        # binário exato para links L (interno), R (redirect) e I (inclusão).
        while start <= hi:
            end = start + BATCH_REF - 1
            cur.execute("""
                INSERT INTO nlab_dw.fato_referencia
                    (sk_pagina_origem, sk_pagina_destino, sk_tipo_link,
                     id_referencia_oltp, qtd_links, eh_destino_resolvido)
                SELECT po.sk_pagina, COALESCE(pt.sk_pagina, pd.sk_pagina), tl.sk_tipo_link, w.id, 1,
                       IF(COALESCE(pt.sk_pagina, pd.sk_pagina) IS NULL, 0, 1)
                FROM nlab_db.wiki_references w
                JOIN nlab_dw.dim_pagina po ON po.id_pagina_oltp = w.page_id
                JOIN nlab_dw.dim_tipo_link tl ON tl.codigo_oltp = COALESCE(w.link_type, 'N/D')
                LEFT JOIN nlab_dw.dim_pagina pt ON pt.id_pagina_oltp = w.target_page_id
                LEFT JOIN nlab_dw.dim_pagina pd
                       ON w.target_page_id IS NULL
                      AND w.link_type IN ('L', 'R', 'I')
                      AND pd.titulo = CONVERT(w.referenced_name USING utf8mb4) COLLATE utf8mb4_bin
                WHERE w.id BETWEEN %s AND %s
            """, (start, end))
            total += cur.rowcount
            log_step(f"  lote {start:,}..{min(end, hi):,}: {total:,} acumulado")
            start = end + 1
    log_step(f"fato_referencia ({total:,} fatos)", t0)


def post_load(conn, base):
    t0 = time.time()
    log_step("Pós-carga: índices e FKs")
    run_script(conn, os.path.join(base, "sql", "01b_post_load.sql"))
    log_step("índices e FKs criados", t0)

    # Faixa de contribuição derivada da própria fato (SCD tipo 1)
    with conn.cursor() as cur:
        cur.execute("""
            UPDATE nlab_dw.dim_autor a
            JOIN (SELECT sk_autor, COUNT(*) AS n FROM nlab_dw.fato_revisao
                  GROUP BY sk_autor) x ON x.sk_autor = a.sk_autor
            SET a.faixa_contribuicoes = CASE
                WHEN a.sk_autor = 1 THEN 'Anônimo'
                WHEN x.n >= 100000 THEN 'Core (>= 100 mil revisões)'
                WHEN x.n >= 10000  THEN 'Ativo (10 mil a 99.999)'
                ELSE 'Regular (< 10 mil)' END
        """)
    log_step("faixa_contribuicoes recalculada a partir da fato", time.time())


# ---------------------------------------------------------------------
# Validação
# ---------------------------------------------------------------------
def validate_load(conn, has_refs):
    print("\n" + "=" * 70)
    print(" VALIDAÇÃO / RECONCILIAÇÃO OLTP x DW")
    print("=" * 70)
    checks = [
        ("revisions = fato_revisao + rejeitadas",
         "SELECT (SELECT COUNT(*) FROM nlab_db.revisions)",
         "SELECT (SELECT COUNT(*) FROM nlab_dw.fato_revisao) + "
         "(SELECT COUNT(*) FROM nlab_dw.etl_rejeitados WHERE tabela_origem='revisions')"),
        ("pages = dim_pagina",
         "SELECT COUNT(*) FROM nlab_db.pages", "SELECT COUNT(*) FROM nlab_dw.dim_pagina"),
        ("SUM(qtd_revisoes) = COUNT(fato_revisao)",
         "SELECT COUNT(*) FROM nlab_dw.fato_revisao",
         "SELECT COALESCE(SUM(qtd_revisoes),0) FROM nlab_dw.fato_revisao"),
        ("SUM(eh_primeira_revisao) = páginas com revisão",
         "SELECT COUNT(DISTINCT sk_pagina) FROM nlab_dw.fato_revisao",
         "SELECT COALESCE(SUM(eh_primeira_revisao),0) FROM nlab_dw.fato_revisao"),
        ("fato_revisao órfã de dim_tempo/autor/pagina/hora = 0",
         "SELECT 0",
         "SELECT COUNT(*) FROM nlab_dw.fato_revisao f "
         "LEFT JOIN nlab_dw.dim_tempo t ON t.sk_tempo=f.sk_tempo "
         "LEFT JOIN nlab_dw.dim_autor a ON a.sk_autor=f.sk_autor "
         "LEFT JOIN nlab_dw.dim_pagina p ON p.sk_pagina=f.sk_pagina "
         "LEFT JOIN nlab_dw.dim_hora h ON h.sk_hora=f.sk_hora "
         "WHERE t.sk_tempo IS NULL OR a.sk_autor IS NULL OR p.sk_pagina IS NULL OR h.sk_hora IS NULL"),
        ("dim_tempo contínua (dias = datediff + 1)",
         "SELECT DATEDIFF(MAX(data_completa), MIN(data_completa)) + 1 FROM nlab_dw.dim_tempo",
         "SELECT COUNT(*) FROM nlab_dw.dim_tempo"),
    ]
    if has_refs:
        checks += [
            ("wiki_references = fato_referencia + rejeitadas",
             "SELECT COUNT(*) FROM nlab_db.wiki_references",
             "SELECT (SELECT COUNT(*) FROM nlab_dw.fato_referencia) + "
             "(SELECT COUNT(*) FROM nlab_dw.etl_rejeitados WHERE tabela_origem='wiki_references')"),
        ]
    ok_all = True
    for nome, esperado, obtido in checks:
        e, o = scalar(conn, esperado), scalar(conn, obtido)
        ok = int(e) == int(o)
        ok_all &= ok
        print(f"  {'OK  ' if ok else 'FAIL'} {nome}: esperado={int(e):,} obtido={int(o):,}")
    rej = scalar(conn, "SELECT COUNT(*) FROM nlab_dw.etl_rejeitados")
    print(f"  INFO linhas rejeitadas (etl_rejeitados): {rej:,}")
    print("=" * 70)
    return ok_all


def print_dw_summary(conn, has_refs):
    print("\n" + "=" * 60)
    print(" RESUMO DA CARGA DO DATA WAREHOUSE (nlab_dw)")
    print("=" * 60)
    tables = ["dim_tempo", "dim_hora", "dim_autor", "dim_pagina", "fato_revisao"]
    if has_refs:
        tables += ["dim_tipo_link", "fato_referencia"]
    for tbl in tables:
        print(f"  • {tbl:<20} : {scalar(conn, f'SELECT COUNT(*) FROM nlab_dw.{tbl}'):>12,d} linhas")
    print("=" * 60)


def main():
    env = os.environ.get
    parser = argparse.ArgumentParser(description="ETL OLTP -> OLAP (nLab Data Warehouse)")
    parser.add_argument("--host", default=env("NLAB_DB_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(env("NLAB_DB_PORT", "3307")))
    parser.add_argument("--user", default=env("NLAB_DB_USER", "root"))
    parser.add_argument("--password", default=env("NLAB_DB_PASSWORD"))
    parser.add_argument("--ddl", default="sql/01_schema_dw.sql")
    parser.add_argument("--only-validate", action="store_true",
                        help="apenas reconcilia OLTP x DW (não recarrega)")
    args = parser.parse_args()

    if args.password is None:
        print("Erro: defina NLAB_DB_PASSWORD (ver .env.example) ou use --password.",
              file=sys.stderr)
        sys.exit(2)

    base = os.path.dirname(os.path.dirname(os.path.abspath(args.ddl)))
    try:
        conn = pymysql.connect(host=args.host, port=args.port, user=args.user,
                               password=args.password, charset="utf8mb4",
                               autocommit=True, read_timeout=3600, write_timeout=3600)
    except Exception as e:
        print(f"Erro de conexão com o MariaDB: {e}", file=sys.stderr)
        sys.exit(1)

    start = time.time()
    try:
        has_refs = table_exists(conn, "nlab_db", "wiki_references")
        if not has_refs:
            print("AVISO: nlab_db.wiki_references não existe (seed de amostra?). "
                  "fato_referencia será criada vazia e ignorada.")
        if args.only_validate:
            sys.exit(0 if validate_load(conn, has_refs) else 1)

        print("Iniciando ETL do nLab Data Warehouse...")
        log_step("DDL do DW")
        run_script(conn, args.ddl)
        with conn.cursor() as cur:
            cur.execute("SET SESSION foreign_key_checks = 0, unique_checks = 0")
        load_staging(conn, has_refs)
        populate_dim_tempo(conn)
        populate_dim_hora(conn)
        populate_dim_autor(conn)
        populate_dim_pagina(conn)
        populate_dim_tipo_link(conn, has_refs)
        populate_fato_revisao(conn)
        if has_refs:
            populate_fato_referencia(conn)
        with conn.cursor() as cur:
            cur.execute("SET SESSION foreign_key_checks = 1, unique_checks = 1")
        post_load(conn, base)
        print_dw_summary(conn, has_refs)
        ok = validate_load(conn, has_refs)
        print(f"{'🎉 ETL finalizado' if ok else '❌ ETL com divergências'} "
              f"em {time.time() - start:.1f}s")
        sys.exit(0 if ok else 1)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
