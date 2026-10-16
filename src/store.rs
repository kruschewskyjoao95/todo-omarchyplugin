use crate::model::*;
use std::path::{Path, PathBuf};

pub struct Store {
    pub dir: PathBuf,
}

impl Store {
    pub fn from_env() -> Self {
        let dir = std::env::var_os("OMARCHY_DAILY_TASKS_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("~"));
                home.join(".local/share/omarchy-daily-tasks")
            });
        Self { dir }
    }
    pub fn state_path(&self) -> PathBuf {
        self.dir.join("state.json")
    }
    pub fn md_path(&self) -> PathBuf {
        self.dir.join("tasks.md")
    }
    pub fn daily_history_path() -> PathBuf {
        if let Some(p) = std::env::var_os("OMARCHY_TODOS_HISTORY") {
            return PathBuf::from(p);
        }
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
        PathBuf::from(home).join(".local/share/omarchy-todos/history.json")
    }
    pub fn limon_tasks_path() -> PathBuf {
        if let Some(p) = std::env::var_os("OMARCHY_TODO_TASKS") {
            return PathBuf::from(p);
        }
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
        PathBuf::from(home).join(".local/share/to-do/tasks.json")
    }

    pub fn load(&self) -> Option<State> {
        let raw = std::fs::read_to_string(self.state_path()).ok()?;
        serde_json::from_str(&raw).ok()
    }

    /// Atomic write: temp file beside the target, then rename. 0600 perms.
    pub fn save(&self, state: &State) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.dir)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&self.dir, std::fs::Permissions::from_mode(0o700));
        }
        let tmp = self.dir.join("state.json.tmp");
        let json = serde_json::to_string_pretty(state).unwrap_or_default();
        std::fs::write(&tmp, json + "\n")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
        }
        std::fs::rename(&tmp, self.state_path())?;
        std::fs::write(self.md_path(), render_markdown(state))?;
        Ok(())
    }
}

pub fn fmt_human(sec: u64) -> String {
    if sec == 0 {
        return "0s".into();
    }
    let h = sec / 3600;
    let m = (sec % 3600) / 60;
    let s = sec % 60;
    if h > 0 {
        if m > 0 { format!("{h}h {m}m") } else { format!("{h}h") }
    } else if m > 0 {
        if s > 0 { format!("{m}m {s}s") } else { format!("{m}m") }
    } else {
        format!("{s}s")
    }
}

pub fn render_markdown(state: &State) -> String {
    let mut out = String::from("# 📋 Tarefas do Dia\n\n");
    if !state.notes.is_empty() {
        out.push_str("## 📝 Notas\n");
        for n in &state.notes {
            out.push_str(&format!("- [{}] {} <!-- id:{} -->\n", if n.done { "x" } else { " " }, n.text, n.id));
        }
        out.push('\n');
    }
    // Newest day first.
    let mut days: Vec<&Day> = state.days.values().collect();
    days.sort_by(|a, b| b.date.cmp(&a.date));
    for day in days.iter().take(31) {
        out.push_str(&format!("## {} \n", day.date));
        let section = |title: &str, status: Status, mark: &str, out: &mut String| {
            let items: Vec<&Task> = day.tasks.iter().filter(|t| t.status == status).collect();
            out.push_str(&format!("\n### {title}\n"));
            if items.is_empty() {
                out.push_str("_Nenhuma tarefa_\n");
            } else {
                for t in items {
                    let big = if t.big3 { "★ " } else { "" };
                    let spent = if t.time_spent_seconds > 0 { format!(" ({})", fmt_human(t.time_spent_seconds)) } else { String::new() };
                    out.push_str(&format!("- [{mark}] {big}{}{} <!-- id:{} -->\n", t.text, spent, t.id));
                }
            }
        };
        section("📋 A Fazer", Status::Todo, " ", &mut out);
        section("⚡ Em Andamento", Status::InProgress, "/", &mut out);
        section("⏸ Em Espera", Status::Standby, "~", &mut out);
        section("✅ Concluídas", Status::Done, "x", &mut out);
        out.push('\n');
    }
    if !state.later.is_empty() {
        out.push_str("## 🕐 Para Depois\n");
        for t in &state.later {
            out.push_str(&format!("- [ ] {} <!-- id:{} -->\n", t.text, t.id));
        }
    }
    out
}

pub fn _unused(_: &Path) {}
