#!/usr/bin/env bash
# Regressão: editar tarefa precisa de botão visível de confirmar (não só Enter).
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1" >&2; exit 1; }

grep -q 'id: editField' Panel.qml || fail "campo de edição sem id"
grep -q 'function commitEdit' Panel.qml || fail "sem commitEdit reutilizável"
grep -q 'visible: card.isEditing' Panel.qml || fail "botões de edição não aparecem ao editar"
grep -q 'Confirmar edição' Panel.qml || fail "botão de confirmar sem rótulo/tooltip"
grep -q 'card.commitEdit()' Panel.qml || fail "Enter e botão não compartilham commitEdit"

echo "OK: edição tem confirmar/cancelar visíveis"
