mod migrate;
mod model;
mod store;

use chrono::{Local, Utc};
use model::*;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};

static COUNTER: AtomicU64 = AtomicU64::new(0);

fn now_epoch() -> i64 {
    Utc::now().timestamp()
}
fn now_iso() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
fn today_key() -> String {
    Local::now().format("%Y-%m-%d").to_string()
}
fn new_id() -> String {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let base = format!("{}{}", Utc::now().timestamp_millis(), n);
    // short, filename/JSON-safe id
    let mut h: u64 = 1469598103934665603;
    for b in base.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(1099511628211);
    }
    format!("t{:x}{:x}", Utc::now().timestamp_millis(), h % 0xffffff)
}

fn load_state(store: &store::Store) -> (State, bool) {
    if let Some(s) = store.load() {
        return (s, false);
    }
    // First run: migrate the two legacy plugins (originals untouched).
    let today = today_key();
    let (mut s, summary) = migrate::migrate(&store::Store::daily_history_path(), &store::Store::limon_tasks_path(), &today);
    eprintln!("omarchy-daily-tasks: {summary}");
    s.roll_forward(&today, now_epoch());
    let _ = store.save(&s);
    (s, true)
}

fn view(state: &State) -> Value {
    let today = today_key();
    let day = state.today(&today);
    let stats = day_stats(day);
    let tasks: Vec<Value> = day
        .map(|d| {
            d.tasks
                .iter()
                .map(|t| {
                    json!({
                        "id": t.id, "text": t.text, "title": t.text,
                        "status": t.status.as_str(), "big3": t.big3,
                        "createdAt": t.created_at, "completedAt": t.completed_at,
                        "timeSpentSeconds": t.time_spent_seconds,
                        "liveSeconds": t.live_seconds(now_epoch()),
                        "timer": { "isRunning": t.timer_running, "lastStartedAt": t.timer_started_at },
                        "carries": t.carries
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    // 14-day history, oldest first
    let mut history = Vec::new();
    for offset in (0..14).rev() {
        let key = (Local::now() - chrono::Duration::days(offset)).format("%Y-%m-%d").to_string();
        let s = day_stats(state.today(&key));
        history.push(json!({"key": key, "done": s.done, "total": s.total, "ratio": s.ratio, "tracked": state.days.contains_key(&key) && s.total > 0}));
    }
    let mut streak = 0;
    for offset in 0..HISTORY_DAYS {
        let key = (Local::now() - chrono::Duration::days(offset as i64)).format("%Y-%m-%d").to_string();
        match state.today(&key) {
            Some(d) if day_stats(Some(d)).all_done => streak += 1,
            _ => break,
        }
    }
    let running = day.and_then(|d| d.tasks.iter().find(|t| t.timer_running));
    json!({
        "version": VERSION,
        "todayKey": today,
        "tasks": tasks,
        "later": state.later.iter().map(|t| json!({"id": t.id, "text": t.text, "createdAt": t.created_at})).collect::<Vec<_>>(),
        "notes": state.notes.iter().map(|n| json!({"id": n.id, "text": n.text, "done": n.done, "createdAt": n.created_at})).collect::<Vec<_>>(),
        "stats": stats,
        "history": history,
        "month": month_cells(state, Local::now().date_naive()),
        "streak": streak,
        "runningTaskId": running.map(|t| t.id.clone()),
        "runningText": running.map(|t| format!("{} {}", t.text, store::fmt_human(t.live_seconds(now_epoch())))),
    })
}

/// Cells for every day of today's month, for the footer heatmap.
/// `level` grows with the absolute number of completed tasks that day:
/// 0 done = 0, 1 = 1, 2 = 2, 3 = 3, 4 or more = 4.
pub fn month_cells(state: &State, today: chrono::NaiveDate) -> Vec<Value> {
    use chrono::Datelike;
    let (year, month) = (today.year(), today.month());
    let next_month = if month == 12 {
        chrono::NaiveDate::from_ymd_opt(year + 1, 1, 1)
    } else {
        chrono::NaiveDate::from_ymd_opt(year, month + 1, 1)
    };
    let days_in_month = next_month
        .and_then(|n| chrono::NaiveDate::from_ymd_opt(year, month, 1).map(|f| (n - f).num_days()))
        .unwrap_or(30) as u32;
    let mut cells = Vec::new();
    for day in 1..=days_in_month {
        let key = format!("{year:04}-{month:02}-{day:02}");
        let stats = day_stats(state.today(&key));
        let level = match stats.done {
            0 => 0,
            1 => 1,
            2 => 2,
            3 => 3,
            _ => 4,
        };
        cells.push(json!({
            "key": key, "day": day, "done": stats.done, "total": stats.total,
            "level": level, "today": key == today.format("%Y-%m-%d").to_string()
        }));
    }
    cells
}

fn find_today<'a>(state: &'a mut State, today: &str, id: &str) -> Option<&'a mut Task> {
    state.today_mut(today).tasks.iter_mut().find(|t| t.id == id)
}

fn pause_all(state: &mut State, today: &str, except: Option<&str>, now: i64) {
    for t in state.today_mut(today).tasks.iter_mut() {
        if t.timer_running && Some(t.id.as_str()) != except {
            t.stop_timer(now);
            if t.status == Status::InProgress {
                t.status = Status::Standby;
            }
        }
    }
}

fn start_timer(state: &mut State, today: &str, id: &str) {
    let now = now_epoch();
    pause_all(state, today, Some(id), now);
    if let Some(t) = find_today(state, today, id) {
        if t.status == Status::Done {
            return;
        }
        t.status = Status::InProgress;
        t.timer_running = true;
        t.timer_started_at = Some(now);
    }
}

fn pause_timer(state: &mut State, today: &str, id: &str) {
    let now = now_epoch();
    if let Some(t) = find_today(state, today, id) {
        t.stop_timer(now);
        if t.status == Status::InProgress {
            t.status = Status::Standby;
        }
    }
}

fn set_status(state: &mut State, today: &str, id: &str, status: Status) {
    let now = now_epoch();
    match status {
        Status::InProgress => start_timer(state, today, id),
        Status::Standby => pause_timer(state, today, id),
        Status::Done => {
            if let Some(t) = find_today(state, today, id) {
                t.stop_timer(now);
                t.status = Status::Done;
                t.completed_at = Some(now_iso());
            }
        }
        Status::Todo => {
            if let Some(t) = find_today(state, today, id) {
                let was_done = t.status == Status::Done;
                t.stop_timer(now);
                t.status = Status::Todo;
                t.completed_at = None;
                if was_done {
                    t.time_spent_seconds = 0;
                }
            }
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("state");
    let arg = |i: usize| args.get(i).cloned().unwrap_or_default();

    // `copy <text>` does not need state.
    if cmd == "copy" {
        let text = arg(1);
        use std::io::Write;
        if let Ok(mut child) = std::process::Command::new("wl-copy").stdin(std::process::Stdio::piped()).spawn() {
            if let Some(stdin) = child.stdin.as_mut() {
                let _ = stdin.write_all(text.as_bytes());
            }
            let _ = child.wait();
        }
        return;
    }
    if cmd == "help" || cmd == "--help" || cmd == "-h" {
        println!("omarchy-daily-tasks <state|status|add|add-later|add-note|start|pause|standby|complete|set-status|rename|delete|toggle-big3|reorder|clear-done|pull-later|defer|note-toggle|note-edit|note-delete|copy> [argumentos]");
        return;
    }

    let store = store::Store::from_env();
    let today = today_key();
    let (mut state, migrated) = load_state(&store);
    let mut dirty = migrated;
    if state.roll_forward(&today, now_epoch()) > 0 || !state.days.contains_key(&today) {
        dirty = true;
    }
    // roll_forward creates today when missing; ensure the day exists.
    if !state.days.contains_key(&today) {
        state.today_mut(&today);
        dirty = true;
    }

    match cmd {
        "state" => {}
        "status" => {
            let s = day_stats(state.today(&today));
            println!("{}/{}", s.done, s.total);
            return;
        }
        "add" => {
            let text = clean_text(&arg(1));
            if !text.is_empty() {
                let big3 = args.iter().any(|a| a == "--big3");
                let day = state.today_mut(&today);
                if day.tasks.len() < MAX_TASKS_PER_DAY && (!big3 || day.tasks.iter().filter(|t| t.big3).count() < BIG3_SLOTS) {
                    day.tasks.push(Task::new(new_id(), text, &today, big3, now_iso()));
                    dirty = true;
                }
            }
        }
        "add-later" => {
            let text = clean_text(&arg(1));
            if !text.is_empty() && state.later.len() < MAX_LATER {
                state.later.push(Task::new(new_id(), text, "", false, now_iso()));
                dirty = true;
            }
        }
        "add-note" => {
            let text = arg(1).trim().to_string();
            if !text.is_empty() && state.notes.len() < MAX_NOTES {
                state.notes.insert(0, Note { id: new_id(), text, done: false, created_at: now_iso() });
                dirty = true;
            }
        }
        "start" => { start_timer(&mut state, &today, &arg(1)); dirty = true; }
        "pause" | "standby" => { pause_timer(&mut state, &today, &arg(1)); dirty = true; }
        "complete" => { set_status(&mut state, &today, &arg(1), Status::Done); dirty = true; }
        "set-status" => {
            if let Some(s) = Status::parse(&arg(2)) {
                set_status(&mut state, &today, &arg(1), s);
                dirty = true;
            }
        }
        "rename" => {
            let text = clean_text(&arg(2));
            if let Some(t) = find_today(&mut state, &today, &arg(1)) {
                if !text.is_empty() { t.text = text; dirty = true; }
            }
        }
        "delete" => {
            let id = arg(1);
            state.today_mut(&today).tasks.retain(|t| t.id != id);
            state.later.retain(|t| t.id != id);
            dirty = true;
        }
        "toggle-big3" => {
            let id = arg(1);
            let day = state.today_mut(&today);
            let is_big = day.tasks.iter().find(|t| t.id == id).map(|t| t.big3).unwrap_or(false);
            if !is_big && day.tasks.iter().filter(|t| t.big3).count() >= BIG3_SLOTS {
                // full: no-op
            } else if let Some(t) = day.tasks.iter_mut().find(|t| t.id == id) {
                t.big3 = !t.big3;
                dirty = true;
            }
        }
        "reorder" => {
            let id = arg(1);
            let delta: i32 = arg(2).parse().unwrap_or(0);
            let day = state.today_mut(&today);
            if let Some(pos) = day.tasks.iter().position(|t| t.id == id) {
                let target = pos as i32 + delta;
                if target >= 0 && (target as usize) < day.tasks.len() {
                    day.tasks.swap(pos, target as usize);
                    dirty = true;
                }
            }
        }
        "clear-done" => {
            state.today_mut(&today).tasks.retain(|t| !t.status.is_done());
            dirty = true;
        }
        "pull-later" => {
            let id = arg(1);
            if let Some(pos) = state.later.iter().position(|t| t.id == id) {
                let mut t = state.later.remove(pos);
                t.first_seen = today.clone();
                t.status = Status::Todo;
                state.today_mut(&today).tasks.push(t);
                dirty = true;
            }
        }
        "defer" => {
            let id = arg(1);
            let day = state.today_mut(&today);
            if let Some(pos) = day.tasks.iter().position(|t| t.id == id && !t.status.is_done()) {
                let mut t = day.tasks.remove(pos);
                t.stop_timer(now_epoch());
                t.status = Status::Todo;
                t.carries = 0;
                if state.later.len() < MAX_LATER {
                    state.later.push(t);
                    dirty = true;
                }
            }
        }
        "note-toggle" => {
            if let Some(n) = state.notes.iter_mut().find(|n| n.id == arg(1)) { n.done = !n.done; dirty = true; }
        }
        "note-edit" => {
            let text = arg(2).trim().to_string();
            if let Some(n) = state.notes.iter_mut().find(|n| n.id == arg(1)) {
                if !text.is_empty() { n.text = text; dirty = true; }
            }
        }
        "note-delete" => {
            state.notes.retain(|n| n.id != arg(1));
            dirty = true;
        }
        other => {
            eprintln!("omarchy-daily-tasks: unknown command '{other}'");
            std::process::exit(2);
        }
    }

    if dirty {
        if let Err(e) = store.save(&state) {
            eprintln!("omarchy-daily-tasks: failed to save: {e}");
            std::process::exit(1);
        }
    }
    println!("{}", serde_json::to_string(&view(&state)).unwrap_or_else(|_| "{}".into()));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn month_cells_cover_month_and_darkens_with_done_count() {
        let mut s = State::default();
        let mut done_task = |id: &str| {
            let mut t = Task::new(id.into(), id.into(), "2026-10-16", false, String::new());
            t.status = Status::Done;
            t
        };
        s.today_mut("2026-10-16").tasks = vec![done_task("a"), done_task("b"), done_task("c"), done_task("d")];
        s.today_mut("2026-10-15").tasks = vec![done_task("e")];
        let cells = month_cells(&s, chrono::NaiveDate::from_ymd_opt(2026, 10, 16).unwrap());
        assert_eq!(cells.len(), 31);
        assert_eq!(cells[15]["day"], 16);
        assert_eq!(cells[15]["today"], true);
        assert_eq!(cells[15]["level"], 4); // 4 concluídas = mais escuro
        assert_eq!(cells[14]["level"], 1); // 1 concluída = mais claro
        assert_eq!(cells[0]["level"], 0);
    }

    #[test]
    fn start_then_pause_lands_in_standby_with_time() {
        let mut s = State::default();
        s.today_mut("2026-10-16").tasks.push(Task::new("a".into(), "Job".into(), "2026-10-16", false, String::new()));
        start_timer(&mut s, "2026-10-16", "a");
        let t = &s.days["2026-10-16"].tasks[0];
        assert_eq!(t.status, Status::InProgress);
        assert!(t.timer_running);
        pause_timer(&mut s, "2026-10-16", "a");
        let t = &s.days["2026-10-16"].tasks[0];
        assert_eq!(t.status, Status::Standby);
        assert!(!t.timer_running);
    }

    #[test]
    fn starting_second_task_pauses_first_to_standby() {
        let mut s = State::default();
        for id in ["a", "b"] {
            s.today_mut("2026-10-16").tasks.push(Task::new(id.into(), id.into(), "2026-10-16", false, String::new()));
        }
        start_timer(&mut s, "2026-10-16", "a");
        start_timer(&mut s, "2026-10-16", "b");
        let tasks = &s.days["2026-10-16"].tasks;
        assert_eq!(tasks[0].status, Status::Standby);
        assert_eq!(tasks[1].status, Status::InProgress);
    }
}
