#!/usr/bin/env python3
"""
Executa as consultas analíticas (OLAP) no Data Warehouse e exibe os resultados.
As consultas são separadas pelo marcador "-- @@QUERY <título>" no arquivo SQL.
"""

import argparse
import os
import re
import sys
import time

import pymysql


def print_table(headers, rows, max_rows):
    if not rows:
        print("  (Nenhum resultado retornado)")
        return
    str_rows = [["NULL" if c is None else str(c) for c in row] for row in rows]
    widths = [len(h) for h in headers]
    for row in str_rows:
        for i, v in enumerate(row):
            widths[i] = max(widths[i], len(v))
    print(" | ".join(h.ljust(widths[i]) for i, h in enumerate(headers)))
    print("-+-".join("-" * w for w in widths))
    for row in str_rows[:max_rows]:
        print(" | ".join(v.ljust(widths[i]) for i, v in enumerate(row)))
    if len(str_rows) > max_rows:
        print(f"... e mais {len(str_rows) - max_rows} linhas.")


def parse_queries(content):
    """Retorna [(título, sql)] a partir dos marcadores -- @@QUERY."""
    parts = re.split(r"^--\s*@@QUERY\s*", content, flags=re.MULTILINE)
    queries = []
    for part in parts[1:]:
        lines = part.splitlines()
        title = lines[0].strip()
        sql_lines = [ln for ln in lines[1:] if not ln.strip().startswith("--")]
        sql = "\n".join(sql_lines).strip().rstrip(";")
        if sql:
            queries.append((title, sql))
    return queries


def main():
    env = os.environ.get
    parser = argparse.ArgumentParser(description="Executar Queries OLAP no DW")
    parser.add_argument("--host", default=env("NLAB_DB_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(env("NLAB_DB_PORT", "3307")))
    parser.add_argument("--user", default=env("NLAB_DB_USER", "root"))
    parser.add_argument("--password", default=env("NLAB_DB_PASSWORD"))
    parser.add_argument("--queries-file", default="sql/02_queries_olap.sql")
    parser.add_argument("--max-rows", type=int, default=25)
    args = parser.parse_args()
    if args.password is None:
        print("Erro: defina NLAB_DB_PASSWORD (ver .env.example) ou use --password.",
              file=sys.stderr)
        sys.exit(2)

    conn = pymysql.connect(host=args.host, port=args.port, user=args.user,
                           password=args.password, database="nlab_dw", charset="utf8mb4",
                           read_timeout=3600)
    with open(args.queries_file, "r", encoding="utf-8") as f:
        queries = parse_queries(f.read())

    with conn.cursor() as cur:
        for title, sql in queries:
            print("\n" + "=" * 80)
            print(f"📊 {title}")
            print("=" * 80)
            t0 = time.time()
            cur.execute(sql)
            rows = cur.fetchall()
            headers = [d[0] for d in cur.description]
            elapsed = time.time() - t0
            print_table(headers, rows, args.max_rows)
            print(f"⏱ {elapsed:.3f}s | Linhas retornadas: {len(rows)}")
    conn.close()
    print("\n" + "=" * 80)
    print(f"✔ {len(queries)} consultas analíticas executadas com sucesso no nlab_dw!")
    print("=" * 80 + "\n")


if __name__ == "__main__":
    main()
