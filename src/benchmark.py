#!/usr/bin/env python3
"""
Benchmark OLTP x OLAP: executa consultas equivalentes no nlab_db (normalizado)
e no nlab_dw (estrela), mede a mediana de N execuções e gera docs/benchmark.md.
"""

import argparse
import os
import statistics
import sys
import time

import pymysql

def oltp_ignore_clauses(cur, enabled):
    if not enabled:
        return {t: "" for t in ("revisions", "wiki_references", "categories", "users")}
    clauses = {}
    for tbl in ("revisions", "wiki_references", "categories", "users"):
        cur.execute("""
            SELECT DISTINCT index_name FROM information_schema.statistics
            WHERE table_schema = 'nlab_db' AND table_name = %s AND index_name <> 'PRIMARY'
            ORDER BY index_name
        """, (tbl,))
        idxs = [f"`{r[0]}`" for r in cur.fetchall()]
        clauses[tbl] = f"IGNORE INDEX ({', '.join(idxs)})" if idxs else ""
    return clauses


def build_bench(ig):
    return [
        ("B1 - Revisões por ano/mês",
         f"""SELECT YEAR(created_at) a, MONTH(created_at) m, COUNT(*) n
            FROM nlab_db.revisions {ig['revisions']} GROUP BY a, m""",
         """SELECT t.ano, t.mes, SUM(f.qtd_revisoes)
            FROM nlab_dw.fato_revisao f JOIN nlab_dw.dim_tempo t ON t.sk_tempo = f.sk_tempo
            GROUP BY t.ano, t.mes"""),
        ("B2 - Revisões por categoria",
         f"""SELECT c.name, COUNT(*) n
            FROM nlab_db.revisions r {ig['revisions']}
            JOIN nlab_db.wiki_references w {ig['wiki_references']} ON w.page_id = r.page_id AND w.link_type = 'C'
            JOIN nlab_db.categories c {ig['categories']} ON c.id = w.category_id
            GROUP BY c.name""",
         """SELECT p.categoria_nome, SUM(f.qtd_revisoes)
            FROM nlab_dw.fato_revisao f JOIN nlab_dw.dim_pagina p ON p.sk_pagina = f.sk_pagina
            GROUP BY p.categoria_nome"""),
        ("B3 - Revisões por autor",
         f"""SELECT u.name, COUNT(*) n FROM nlab_db.revisions r {ig['revisions']}
            JOIN nlab_db.users u {ig['users']} ON u.id = r.author_id GROUP BY u.name""",
         """SELECT a.nome_autor, SUM(f.qtd_revisoes)
            FROM nlab_dw.fato_revisao f JOIN nlab_dw.dim_autor a ON a.sk_autor = f.sk_autor
            GROUP BY a.nome_autor"""),
    ]


def timed(cur, sql, runs, timeout):
    """Mediana em segundos, ou None se estourar o timeout (max_statement_time)."""
    ts = []
    cur.execute(f"SET SESSION max_statement_time = {timeout}")
    for _ in range(runs):
        t0 = time.time()
        try:
            cur.execute(sql)
            cur.fetchall()
        except pymysql.err.OperationalError as e:
            if e.args[0] == 1969:  # statement timeout
                return None
            raise
        ts.append(time.time() - t0)
    return statistics.median(ts)


def explain(cur, sql):
    cur.execute("EXPLAIN " + sql)
    return "; ".join(f"{r[2]}:{r[3]}/{r[5] or '-'}/~{r[8]}" for r in cur.fetchall())


def main():
    env = os.environ.get
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=env("NLAB_DB_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(env("NLAB_DB_PORT", "3307")))
    ap.add_argument("--user", default=env("NLAB_DB_USER", "root"))
    ap.add_argument("--password", default=env("NLAB_DB_PASSWORD"))
    ap.add_argument("--runs", type=int, default=3, help="execuções no DW (mediana)")
    ap.add_argument("--oltp-runs", type=int, default=1, help="execuções no OLTP (mediana)")
    ap.add_argument("--timeout", type=int, default=600, help="timeout por consulta (s)")
    ap.add_argument("--no-oltp-indexes", action="store_true",
                    help="ignora índices secundários nas tabelas do OLTP (IGNORE INDEX)")
    ap.add_argument("--out", default="docs/benchmark.md")
    a = ap.parse_args()
    if a.password is None:
        sys.exit("Defina NLAB_DB_PASSWORD.")
    conn = pymysql.connect(host=a.host, port=a.port, user=a.user, password=a.password,
                           charset="utf8mb4", read_timeout=7200)
    idx_note = " (índices secundários do OLTP ignorados)" if a.no_oltp_indexes else ""
    lines = ["# Benchmark OLTP x OLAP", "",
             f"Mesmo servidor MariaDB{idx_note}. Mediana de {a.runs} execuções no DW e de "
             f"{a.oltp_runs} no OLTP (timeout de {a.timeout}s por consulta).", "",
             "| Consulta | OLTP (s) | DW (s) | Speedup |", "|---|---:|---:|---:|"]
    detail = ["", "## Planos de execução (tabela:tipo/chave/linhas estimadas)", ""]
    with conn.cursor() as cur:
        bench = build_bench(oltp_ignore_clauses(cur, a.no_oltp_indexes))
        for nome, oltp, dw in bench:
            print(f"▶ {nome}", flush=True)
            to = timed(cur, oltp, a.oltp_runs, a.timeout)
            td = timed(cur, dw, a.runs, a.timeout)
            if to is None:
                print(f"   OLTP > {a.timeout}s (timeout)  DW={td:.2f}s", flush=True)
                lines.append(f"| {nome} | > {a.timeout} (timeout) | {td:.2f} | > {a.timeout / td:.0f}x |")
            else:
                sp = to / td if td > 0 else float("inf")
                print(f"   OLTP={to:.2f}s  DW={td:.2f}s  speedup={sp:.1f}x", flush=True)
                lines.append(f"| {nome} | {to:.2f} | {td:.2f} | {sp:.1f}x |")
            detail += [f"**{nome}**", f"- OLTP: `{explain(cur, oltp)}`",
                       f"- DW: `{explain(cur, dw)}`", ""]
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines + detail) + "\n")
    print(f"Relatório gravado em {a.out}")


if __name__ == "__main__":
    main()

