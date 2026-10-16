use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const VERSION: u32 = 1;
pub const BIG3_SLOTS: usize = 3;
pub const MAX_TASKS_PER_DAY: usize = 100;
pub const MAX_LATER: usize = 200;
pub const MAX_NOTES: usize = 500;
pub const HISTORY_DAYS: usize = 400;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Todo,
    InProgress,
    Standby,
    Done,
}

impl Status {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "todo" | "to-do" | "to_do" => Some(Self::Todo),
            "in_progress" | "progress" | "in-progress" => Some(Self::InProgress),
            "standby" | "stand_by" | "stand-by" | "paused" => Some(Self::Standby),
            "done" | "complete" | "completed" => Some(Self::Done),
            _ => None,
        }
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Todo => "todo",
            Self::InProgress => "in_progress",
            Self::Standby => "standby",
            Self::Done => "done",
        }
    }
    pub fn is_done(&self) -> bool {
        matches!(self, Self::Done)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Task {
    pub id: String,
    pub text: String,
    pub status: Status,
    #[serde(default)]
    pub big3: bool,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub completed_at: Option<String>,
    #[serde(default)]
    pub time_spent_seconds: u64,
    #[serde(default)]
    pub timer_running: bool,
    #[serde(default)]
    pub timer_started_at: Option<i64>,
    #[serde(default)]
    pub carries: u32,
    #[serde(default)]
    pub first_seen: String,
}

impl Task {
    pub fn new(id: String, text: String, day: &str, big3: bool, now_iso: String) -> Self {
        Self {
            id,
            text,
            status: Status::Todo,
            big3,
            created_at: now_iso,
            completed_at: None,
            time_spent_seconds: 0,
            timer_running: false,
            timer_started_at: None,
            carries: 0,
            first_seen: day.to_string(),
        }
    }
    /// Elapsed seconds including a live timer segment.
    pub fn live_seconds(&self, now_epoch: i64) -> u64 {
        let mut total = self.time_spent_seconds;
        if self.timer_running {
            if let Some(started) = self.timer_started_at {
                total = total.saturating_add(now_epoch.saturating_sub(started).max(0) as u64);
            }
        }
        total
    }
    /// Fold a live segment into `time_spent_seconds` and stop the timer.
    pub fn stop_timer(&mut self, now_epoch: i64) {
        if self.timer_running {
            self.time_spent_seconds = self.live_seconds(now_epoch);
        }
        self.timer_running = false;
        self.timer_started_at = None;
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    pub id: String,
    pub text: String,
    #[serde(default)]
    pub done: bool,
    #[serde(default)]
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Day {
    pub date: String,
    #[serde(default)]
    pub tasks: Vec<Task>,
}

impl Day {
    pub fn empty(date: &str) -> Self {
        Self { date: date.to_string(), tasks: Vec::new() }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct State {
    pub version: u32,
    #[serde(default)]
    pub days: BTreeMap<String, Day>,
    #[serde(default)]
    pub later: Vec<Task>,
    #[serde(default)]
    pub notes: Vec<Note>,
}

impl Default for State {
    fn default() -> Self {
        Self { version: VERSION, days: BTreeMap::new(), later: Vec::new(), notes: Vec::new() }
    }
}

impl State {
    pub fn today_mut(&mut self, key: &str) -> &mut Day {
        self.days.entry(key.to_string()).or_insert_with(|| Day::empty(key))
    }
    pub fn today(&self, key: &str) -> Option<&Day> {
        self.days.get(key)
    }

    /// Build today from the most recent prior day. Unfinished Big 3 items are
    /// demoted to regular tasks; a running timer is paused into Stand By.
    pub fn roll_forward(&mut self, today: &str, now_epoch: i64) -> usize {
        if self.days.contains_key(today) {
            return 0;
        }
        let prev_key = self.days.keys().filter(|k| k.as_str() < today).last().cloned();
        let mut carried = Vec::new();
        if let Some(prev_key) = prev_key {
            if let Some(prev) = self.days.get(&prev_key) {
                for task in &prev.tasks {
                    if task.status.is_done() || carried.len() >= MAX_TASKS_PER_DAY {
                        continue;
                    }
                    let mut copy = task.clone();
                    copy.big3 = false;
                    copy.completed_at = None;
                    copy.stop_timer(now_epoch);
                    if copy.status == Status::InProgress {
                        copy.status = Status::Standby;
                    }
                    if copy.first_seen.is_empty() {
                        copy.first_seen = prev_key.clone();
                    }
                    copy.carries = copy.carries.saturating_add(1);
                    carried.push(copy);
                }
            }
        }
        let count = carried.len();
        self.days.insert(today.to_string(), Day { date: today.to_string(), tasks: carried });
        self.prune();
        count
    }

    fn prune(&mut self) {
        while self.days.len() > HISTORY_DAYS {
            if let Some(first) = self.days.keys().next().cloned() {
                self.days.remove(&first);
            } else {
                break;
            }
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Stats {
    pub total: usize,
    pub done: usize,
    pub todo: usize,
    pub in_progress: usize,
    pub standby: usize,
    pub big3_total: usize,
    pub big3_done: usize,
    pub ratio: f64,
    pub weighted_ratio: f64,
    pub all_done: bool,
}

pub fn day_stats(day: Option<&Day>) -> Stats {
    let tasks: &[Task] = day.map(|d| d.tasks.as_slice()).unwrap_or(&[]);
    let done = tasks.iter().filter(|t| t.status.is_done()).count();
    let big3: Vec<&Task> = tasks.iter().filter(|t| t.big3).collect();
    let big3_done = big3.iter().filter(|t| t.status.is_done()).count();
    let weighted_total: f64 = tasks.iter().map(|t| if t.big3 { 2.0 } else { 1.0 }).sum();
    let weighted_done: f64 = tasks.iter().filter(|t| t.status.is_done()).map(|t| if t.big3 { 2.0 } else { 1.0 }).sum();
    Stats {
        total: tasks.len(),
        done,
        todo: tasks.iter().filter(|t| t.status == Status::Todo).count(),
        in_progress: tasks.iter().filter(|t| t.status == Status::InProgress).count(),
        standby: tasks.iter().filter(|t| t.status == Status::Standby).count(),
        big3_total: big3.len(),
        big3_done,
        ratio: if tasks.is_empty() { 0.0 } else { done as f64 / tasks.len() as f64 },
        weighted_ratio: if weighted_total == 0.0 { 0.0 } else { weighted_done / weighted_total },
        all_done: !tasks.is_empty() && done == tasks.len(),
    }
}

pub fn clean_text(value: &str) -> String {
    let collapsed: String = value.split_whitespace().collect::<Vec<_>>().join(" ");
    collapsed.chars().take(500).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task(id: &str, status: Status) -> Task {
        Task {
            id: id.into(),
            text: id.into(),
            status,
            big3: false,
            created_at: String::new(),
            completed_at: None,
            time_spent_seconds: 0,
            timer_running: false,
            timer_started_at: None,
            carries: 0,
            first_seen: String::new(),
        }
    }

    #[test]
    fn standby_is_distinct_status() {
        assert_eq!(Status::parse("standby"), Some(Status::Standby));
        assert_eq!(Status::parse("stand-by"), Some(Status::Standby));
        assert_eq!(Status::Standby.as_str(), "standby");
        assert!(!Status::Standby.is_done());
    }

    #[test]
    fn pause_folds_live_time() {
        let mut t = task("a", Status::InProgress);
        t.time_spent_seconds = 60;
        t.timer_running = true;
        t.timer_started_at = Some(1_000);
        assert_eq!(t.live_seconds(1_090), 150);
        t.stop_timer(1_090);
        assert_eq!(t.time_spent_seconds, 150);
        assert!(!t.timer_running);
    }

    #[test]
    fn roll_forward_demotes_big3_and_pauses_running() {
        let mut s = State::default();
        let mut big = task("big", Status::InProgress);
        big.big3 = true;
        big.timer_running = true;
        big.timer_started_at = Some(100);
        let mut done = task("done", Status::Done);
        done.big3 = true;
        s.days.insert("2026-10-15".into(), Day { date: "2026-10-15".into(), tasks: vec![big, done] });
        let carried = s.roll_forward("2026-10-16", 200);
        assert_eq!(carried, 1);
        let today = &s.days["2026-10-16"].tasks[0];
        assert!(!today.big3);
        assert_eq!(today.status, Status::Standby);
        assert_eq!(today.carries, 1);
        assert_eq!(today.time_spent_seconds, 100);
    }
}
