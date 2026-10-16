#!/usr/bin/env bash
# Regressão: rodapé com os dias do mês escurecendo por tarefas concluídas.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1" >&2; exit 1; }

grep -q 'property var monthCells' Panel.qml || fail "Panel sem monthCells"
grep -q 'state.month' Panel.qml || fail "Panel não lê state.month do backend"
grep -q 'model: root.monthCells' Panel.qml || fail "rodapé não renderiza monthCells"
grep -q 'columns: Math.ceil(root.monthCells.length / 2)' Panel.qml || fail "dias do mês não estão quebrados em duas linhas"
grep -q 'month_cells' src/main.rs || fail "backend Rust sem month_cells"

echo "OK: mapa do mês presente no backend e no rodapé"
