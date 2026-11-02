#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "=================================================="
echo "🚀 nLab Data Warehouse: Pipeline & Queries OLAP"
echo "=================================================="

# Credenciais (.env não é versionado; use .env.example como modelo)
if [ ! -f .env ]; then
    echo "❌ Arquivo .env não encontrado. Execute: cp .env.example .env  (e ajuste a senha)"
    exit 1
fi
set -a; source .env; set +a

# Ambiente virtual Python
if [ ! -d ".venv" ]; then
    echo "📦 Criando ambiente virtual Python (.venv)..."
    python3 -m venv .venv
    .venv/bin/pip install --quiet -r requirements.txt
fi

# Sobe o MariaDB via Docker apenas se a porta ainda não estiver respondendo
if (exec 3<>/dev/tcp/"${NLAB_DB_HOST:-127.0.0.1}"/"${NLAB_DB_PORT:-3307}") 2>/dev/null; then
    echo "✔ Servidor MariaDB já está respondendo em ${NLAB_DB_HOST:-127.0.0.1}:${NLAB_DB_PORT:-3307}."
else
    echo "🐳 Subindo MariaDB (docker compose) e aguardando o healthcheck..."
    docker compose up -d --wait
fi

echo "🔄 Executando Pipeline de ETL (inclui validação)..."
.venv/bin/python3 src/etl.py

echo "📊 Executando Consultas Analíticas (OLAP)..."
.venv/bin/python3 src/run_queries.py

echo "=================================================="
echo "✔ Concluído com sucesso!"
echo "=================================================="
