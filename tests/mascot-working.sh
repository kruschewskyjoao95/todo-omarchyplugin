#!/usr/bin/env bash
# Regressão: Pip anima enquanto uma tarefa está sendo feita (timer rodando).
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1" >&2; exit 1; }

grep -q 'property bool working' Mascot.qml || fail "Mascot sem propriedade working"
grep -q 'on workBob' Mascot.qml || fail "Mascot sem animação de trabalho (workBob)"
grep -q 'working: root.runningText' BarWidget.qml || fail "BarWidget não liga working ao timer rodando"
grep -q 'host.backendState = state' Panel.qml || fail "Panel não sincroniza estado com a barra ao iniciar tarefa"

echo "OK: Pip anima com tarefa em andamento"
