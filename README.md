# Tarefas do Dia (Rust)

União dos plugins **Daily Todos** (`io.github.saikomantisu.todos`) e
**Tasks & Time Tracker** (`limon.todo`) para o Omarchy, com backend em Rust.

## O que junta

| Daily Todos | Tasks & Time Tracker | Aqui |
|---|---|---|
| Big 3 (3 prioridades do dia) | — | ★ Big 3, peso dobrado no progresso |
| Tarefas do dia + carry-over | — | Tarefas por dia; as não concluídas passam para o dia seguinte (`↻N`) |
| Later | — | Lista "Para Depois", sem dia, fora das estatísticas |
| Mascote Pip + barra do dia | — | Pip na barra, progresso do dia, sequência de dias |
| — | A Fazer / Em Andamento / Concluídas | **A Fazer / Em Andamento / Em Espera / Concluídas** |
| — | Timer ao vivo | Play inicia; **pausar manda para Em Espera** com o tempo acumulado; retomar continua de onde parou |
| — | Notas (Markdown) | Notas globais com copiar, concluir, editar e apagar |

Só um timer roda por vez: iniciar outra tarefa pausa a anterior para Em Espera.

## Arquitetura

```
BarWidget.qml / Panel.qml / Mascot.qml   interface Quickshell (tema do Omarchy)
bin/omarchy-daily-tasks                  binário Rust: estado, timer, migração
src/                                     código-fonte Rust (cargo build --release)
~/.local/share/omarchy-daily-tasks/      state.json + tasks.md (exportação legível)
```

A interface não guarda estado: cada ação chama o binário
(`omarchy-daily-tasks add|start|pause|complete|set-status|…`), que grava
atomicamente e devolve o estado novo em JSON. Rode `omarchy-daily-tasks help`.

## Migração

Na primeira execução, se `state.json` ainda não existe, importa:

- `~/.local/share/omarchy-todos/history.json` (Big 3, tarefas, Para Depois)
- `~/.local/share/to-do/tasks.json` (tarefas com tempo gasto e Notas)

Os arquivos originais **não são alterados**. Um timer que estava rodando no
plugin antigo entra em Em Espera com o tempo já gasto preservado.

## Como compilar

```bash
cd ~/.config/omarchy/plugins/kruschewskyjoao95.daily-tasks
cargo build --release --offline
cp target/release/omarchy-daily-tasks bin/
cargo test --offline
```

## Uso

- Clique esquerdo no Pip: abre o painel · clique do meio: abre já com o campo de adicionar focado
- `★` no campo de adicionar: cria já como Big 3 · `🕐`: manda direto para o Para Depois
- Ao passar o mouse numa tarefa: `✓` concluir · `⏸` Em Espera · `☆/★` Big 3 · `↓` Para Depois · `✎` editar · `✕` apagar
- Rodapé do painel: um quadradinho por dia do mês atual (número do dia dentro, hoje com borda); quanto mais tarefas concluídas no dia, mais escuro o quadradinho — passe o mouse para ver `concluídas/total`
- IPC: `omarchy-shell kruschewskyjoao95.daily-tasks status|toggle|capture`

## Créditos

O mascote Pip e o conceito de progresso/humores vêm do Daily Todos (MIT,
Saikomantisu); o fluxo de tarefas/timer/notas vem do Tasks & Time Tracker
(MIT, Sheikh Limon). Licença deste plugin: MIT.
