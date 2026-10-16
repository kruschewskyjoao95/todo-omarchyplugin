#!/usr/bin/env bash
# Regressão de layout: as 5 abas em pt-BR precisam caber no painel.
# Antes: painel de 400px -> ~71px por aba e "Em Andamento (9)" cortava.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1" >&2; exit 1; }

width=$(grep -oE 'fittedContentWidth\(Style\.space\([0-9]+\)\)' Panel.qml | grep -oE '[0-9]+' | head -1)
[ -n "$width" ] || fail "contentWidth não encontrado em Panel.qml"
[ "$width" -ge 480 ] || fail "painel estreito demais: ${width}px (mínimo 480)"
[ "$width" -le 520 ] || fail "painel largo demais: ${width}px (máximo 520)"

grep -q 'width: tabRow.cellWidth' Panel.qml || fail "abas não usam tabRow.cellWidth"
grep -q '"Andamento"' Panel.qml || fail "aba longa não foi encurtada para 'Andamento'"

grep -q 'width: panelFlick.width - Style.space(14)' Panel.qml || fail "sem calha de 14px para a barra de rolagem"
grep -q 'columns: Math.ceil(root.monthCells.length / 2)' Panel.qml || fail "dias do mês não estão em duas linhas"

echo "OK: painel ${width}px, abas em cellWidth, rótulos cabem"
