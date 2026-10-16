use crate::model::*;
use serde_json::Value;
use std::path::Path;

/// Import the two legacy plugins into the unified state. Originals are only
/// read, never modified. Returns a human-readable summary for logs/tests.
pub fn migrate(daily_history: &Path, limon_tasks: &Path, today: &str) -> (State, String) {
    let mut state = State::default();
    let mut notes_from_daily = 0usize;
    let mut tasks_from_limon = 0usize;

    // ---- Daily Todos: ~/.local/share/omarchy-todos/history.json ----
    if let Ok(raw) = std::fs::read_to_string(daily_history) {
        if let Ok(v) = serde_json::from_str::<Value>(&raw) {
            if let Some(days) = v.get("days").and_then(|d| d.as_object()) {
                for (key, day) in days {
                    let mut tasks = Vec::new();
                    for (list_name, big3) in [("big3", true), ("todos", false)] {
                        if let Some(items) = day.get(list_name).and_then(|l| l.as_array()) {
                            for it in items {
                                let text = clean_text(it.get("text").and_then(|x| x.as_str()).unwrap_or(""));
                                if text.is_empty() {
                                    continue;
                                }
                                let done = it.get("done").and_then(|x| x.as_bool()).unwrap_or(false);
                                tasks.push(Task {
                                    id: str_field(it, "id"),
                                    text,
                                    status: if done { Status::Done } else { Status::Todo },
                                    big3,
                                    created_at: str_field(it, "createdAt"),
                                    completed_at: opt_field(it, "completedAt"),
                                    time_spent_seconds: 0,
                                    timer_running: false,
                                    timer_started_at: None,
                                    carries: it.get("carries").and_then(|x| x.as_u64()).unwrap_or(0) as u32,
                                    first_seen: {
                                        let f = str_field(it, "firstSeen");
                                        if f.is_empty() { key.clone() } else { f }
                                    },
                                });
                            }
                        }
                    }
                    notes_from_daily += tasks.len();
                    state.days.insert(key.clone(), Day { date: key.clone(), tasks });
                }
            }
            if let Some(later) = v.get("later").and_then(|l| l.as_array()) {
                for it in later {
                    let text = clean_text(it.get("text").and_then(|x| x.as_str()).unwrap_or(""));
                    if text.is_empty() {
                        continue;
                    }
                    state.later.push(Task {
                        id: str_field(it, "id"),
                        text,
                        status: Status::Todo,
                        big3: false,
                        created_at: str_field(it, "createdAt"),
                        completed_at: None,
                        time_spent_seconds: 0,
                        timer_running: false,
                        timer_started_at: None,
                        carries: 0,
                        first_seen: String::new(),
                    });
                }
            }
        }
    }

    // ---- Tasks & Time Tracker: ~/.local/share/to-do/tasks.json ----
    if let Ok(raw) = std::fs::read_to_string(limon_tasks) {
        if let Ok(v) = serde_json::from_str::<Value>(&raw) {
            if let Some(items) = v.get("tasks").and_then(|l| l.as_array()) {
                for it in items {
                    let text = clean_text(it.get("title").and_then(|x| x.as_str()).unwrap_or(""));
                    if text.is_empty() {
                        continue;
                    }
                    let status = it
                        .get("status")
                        .and_then(|x| x.as_str())
                        .and_then(Status::parse)
                        .unwrap_or(Status::Todo);
                    let created = str_field(it, "createdAt");
                    let day_key = if created.len() >= 10 && created.as_bytes().get(4) == Some(&b'-') {
                        created[..10].to_string()
                    } else {
                        today.to_string()
                    };
                    let timer = it.get("timer");
                    let task = Task {
                        id: str_field(it, "id"),
                        text,
                        status,
                        big3: false,
                        created_at: created,
                        completed_at: it.get("completedAt").and_then(|x| x.as_str()).map(|s| s.to_string()),
                        time_spent_seconds: it.get("timeSpentSeconds").and_then(|x| x.as_u64()).unwrap_or(0),
                        timer_running: timer.and_then(|t| t.get("isRunning")).and_then(|x| x.as_bool()).unwrap_or(false),
                        timer_started_at: None,
                        carries: 0,
                        first_seen: day_key.clone(),
                    };
                    // A running legacy timer has no epoch we can trust after a
                    // restart; park it in Stand By instead of inventing time.
                    let mut task = task;
                    if task.timer_running {
                        task.timer_running = false;
                        if task.status == Status::InProgress {
                            task.status = Status::Standby;
                        }
                    }
                    state.today_mut(&day_key).tasks.push(task);
                    tasks_from_limon += 1;
                }
            }
            if let Some(notes) = v.get("notes").and_then(|l| l.as_array()) {
                for it in notes {
                    let text = it.get("text").and_then(|x| x.as_str()).unwrap_or("").trim().to_string();
                    if text.is_empty() {
                        continue;
                    }
                    state.notes.push(Note {
                        id: str_field(it, "id"),
                        text,
                        done: it.get("done").and_then(|x| x.as_bool()).unwrap_or(false),
                        created_at: str_field(it, "createdAt"),
                    });
                }
            }
        }
    }

    let summary = format!(
        "migrated {} daily task(s) across {} day(s), {} limon task(s), {} later, {} note(s)",
        notes_from_daily,
        state.days.len(),
        tasks_from_limon,
        state.later.len(),
        state.notes.len()
    );
    (state, summary)
}

fn str_field(v: &Value, key: &str) -> String {
    v.get(key).and_then(|x| x.as_str()).unwrap_or("").to_string()
}
fn opt_field(v: &Value, key: &str) -> Option<String> {
    match v.get(key).and_then(|x| x.as_str()) {
        Some(s) if !s.is_empty() => Some(s.to_string()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn migrates_both_sources_without_touching_originals() {
        let dir = std::env::temp_dir().join(format!("dt-migrate-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let daily = dir.join("history.json");
        let limon = dir.join("tasks.json");
        let daily_src = r#"{"version":1,"days":{"2026-10-16":{"date":"2026-10-16","big3":[{"id":"b1","text":"Big One","done":false}],"todos":[{"id":"t1","text":"Old Todo","done":true}]}},"later":[{"id":"l1","text":"Passport"}]}"#;
        let limon_src = r#"{"version":1,"notes":[{"id":"n1","text":"hello","done":false}],"tasks":[{"id":"x1","title":"LandingPage","status":"in_progress","createdAt":"2026-10-16T13:00:00Z","timeSpentSeconds":120,"timer":{"isRunning":true,"lastStartedAt":null}}]}"#;
        std::fs::File::create(&daily).unwrap().write_all(daily_src.as_bytes()).unwrap();
        std::fs::File::create(&limon).unwrap().write_all(limon_src.as_bytes()).unwrap();

        let (state, summary) = migrate(&daily, &limon, "2026-10-16");
        assert!(summary.contains("limon task"));
        let today = &state.days["2026-10-16"];
        // big + done + limon (parked to standby, spent preserved)
        assert_eq!(today.tasks.len(), 3);
        let limon_task = today.tasks.iter().find(|t| t.id == "x1").unwrap();
        assert_eq!(limon_task.status, Status::Standby);
        assert_eq!(limon_task.time_spent_seconds, 120);
        assert_eq!(state.later.len(), 1);
        assert_eq!(state.notes.len(), 1);
        // originals untouched
        assert_eq!(std::fs::read_to_string(&daily).unwrap(), daily_src);
        std::fs::remove_dir_all(&dir).ok();
    }
}
