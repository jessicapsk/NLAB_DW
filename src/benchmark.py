#!/usr/bin/env python3
"""
Benchmark OLTP x OLAP: executa consultas equivalentes no nlab_db (normalizado)
e no nlab_dw (estrela), mede média, mediana e P95 de N execuções e gera relatório Markdown.
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


def percentile(sorted_vals, p):
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    pos = (len(sorted_vals) - 1) * (p / 100.0)
    lo = int(pos)
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (pos - lo) * (sorted_vals[hi] - sorted_vals[lo])


def calc_stats(ts):
    s = sorted(ts)
    return {
        "mean": statistics.mean(s),
        "median": statistics.median(s),
        "p95": percentile(s, 95),
    }


def timed(cur, label, sql, runs, timeout):
    """Retorna dict com mean/median/p95 em segundos, ou None se estourar o timeout."""
    ts = []
    cur.execute(f"SET SESSION max_statement_time = {timeout}")
    for i in range(1, runs + 1):
        t0 = time.time()
        try:
            cur.execute(sql)
            cur.fetchall()
        except pymysql.err.OperationalError as e:
            if e.args[0] == 1969:  # statement timeout
                print(f"      [{label}] execução {i}/{runs}: > {timeout}s (timeout)", flush=True)
                return None
            raise
        dt = time.time() - t0
        ts.append(dt)
        if i == 1 or i % 5 == 0 or i == runs:
            print(f"      [{label}] execução {i}/{runs}: {dt:.2f}s", flush=True)
    return calc_stats(ts)


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
    ap.add_argument("--runs", type=int, default=20, help="execuções no DW (padrão: 20)")
    ap.add_argument("--oltp-runs", type=int, default=20, help="execuções no OLTP (padrão: 20)")
    ap.add_argument("--timeout", type=int, default=300, help="timeout por consulta (s)")
    ap.add_argument("--no-oltp-indexes", action="store_true",
                    help="ignora índices secundários nas tabelas do OLTP (IGNORE INDEX)")
    ap.add_argument("--out", default="docs/benchmark.md")
    a = ap.parse_args()
    if a.password is None:
        sys.exit("Defina NLAB_DB_PASSWORD.")
    conn = pymysql.connect(host=a.host, port=a.port, user=a.user, password=a.password,
                           charset="utf8mb4", read_timeout=7200)
    idx_note = " (índices secundários do OLTP ignorados)" if a.no_oltp_indexes else ""
    lines = [
        "# Benchmark OLTP x OLAP",
        "",
        f"Mesmo servidor MariaDB{idx_note}. Estatísticas sobre {a.runs} execuções no DW e "
        f"{a.oltp_runs} no OLTP (timeout de {a.timeout}s por consulta).",
        "",
        "| Consulta | OLTP Média (s) | OLTP Mediana (s) | OLTP P95 (s) | DW Média (s) | DW Mediana (s) | DW P95 (s) | Speedup (Mediana) | Speedup (Média) |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    detail = ["", "## Planos de execução (tabela:tipo/chave/linhas estimadas)", ""]
    with conn.cursor() as cur:
        bench = build_bench(oltp_ignore_clauses(cur, a.no_oltp_indexes))
        for nome, oltp, dw in bench:
            print(f"▶ {nome}", flush=True)
            so = timed(cur, "OLTP", oltp, a.oltp_runs, a.timeout)
            sd = timed(cur, "DW", dw, a.runs, a.timeout)
            if so is None:
                sp_med = f"> {a.timeout / sd['median']:.0f}x"
                sp_avg = f"> {a.timeout / sd['mean']:.0f}x"
                print(
                    f"   RESUMO -> OLTP: > {a.timeout}s (timeout) | "
                    f"DW: média={sd['mean']:.2f}s mediana={sd['median']:.2f}s p95={sd['p95']:.2f}s",
                    flush=True,
                )
                lines.append(
                    f"| {nome} | > {a.timeout} | > {a.timeout} | > {a.timeout} | "
                    f"{sd['mean']:.2f} | {sd['median']:.2f} | {sd['p95']:.2f} | {sp_med} | {sp_avg} |"
                )
            else:
                sp_med = f"{so['median'] / sd['median']:.1f}x" if sd["median"] > 0 else "inf"
                sp_avg = f"{so['mean'] / sd['mean']:.1f}x" if sd["mean"] > 0 else "inf"
                print(
                    f"   RESUMO -> OLTP: média={so['mean']:.2f}s mediana={so['median']:.2f}s p95={so['p95']:.2f}s | "
                    f"DW: média={sd['mean']:.2f}s mediana={sd['median']:.2f}s p95={sd['p95']:.2f}s | "
                    f"speedup(med)={sp_med}",
                    flush=True,
                )
                lines.append(
                    f"| {nome} | {so['mean']:.2f} | {so['median']:.2f} | {so['p95']:.2f} | "
                    f"{sd['mean']:.2f} | {sd['median']:.2f} | {sd['p95']:.2f} | {sp_med} | {sp_avg} |"
                )
            detail += [f"**{nome}**", f"- OLTP: `{explain(cur, oltp)}`",
                       f"- DW: `{explain(cur, dw)}`", ""]
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines + detail) + "\n")
    print(f"Relatório gravado em {a.out}")


if __name__ == "__main__":
    main()
