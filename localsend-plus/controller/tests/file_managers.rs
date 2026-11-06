//! The context menu entries for Dolphin, Nautilus and Nemo in `extras/` hand
//! the selected paths to the plugin's IPC `send`: their number, then one path
//! per line. These tests run them against a stand-in `noctalia` that records
//! its arguments.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use tempfile::TempDir;

/// Paths a file manager may pass on, awkward ones included.
const PATHS: [&str; 3] = [
    "/home/me/My Pictures/a b.jpg",
    "/home/me/$(touch marker)",
    "/home/me/it's here",
];

struct Fixture {
    dir: TempDir,
    /// PATH with the stand-in `noctalia` first.
    path: String,
}

impl Fixture {
    fn new() -> Self {
        let dir = TempDir::new().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        let noctalia = bin.join("noctalia");
        let script = format!(
            "#!/bin/sh\nprintf '%s\\0' \"$@\" > '{}'\n",
            dir.path().join("args").display()
        );
        std::fs::write(&noctalia, script).unwrap();
        std::fs::set_permissions(&noctalia, std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = format!(
            "{}:{}",
            bin.display(),
            std::env::var("PATH").unwrap_or_default()
        );
        Fixture { dir, path }
    }

    fn command(&self, script: &Path) -> Command {
        let mut command = Command::new("sh");
        command
            .arg(script)
            .current_dir(self.dir.path())
            .env("PATH", &self.path);
        command
    }

    /// What `noctalia` was called with, or None when it was not called.
    fn recorded(&self) -> Option<Vec<String>> {
        let raw = std::fs::read(self.dir.path().join("args")).ok()?;
        let text = String::from_utf8(raw).unwrap();
        Some(
            text.strip_suffix('\0')
                .unwrap_or(&text)
                .split('\0')
                .map(str::to_string)
                .collect(),
        )
    }
}

fn extra(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../extras/file-managers")
        .join(name)
}

/// The lines of the `send` payload, after checking the rest of the command.
fn sent_lines(fixture: &Fixture) -> Vec<String> {
    let args = fixture.recorded().expect("noctalia was not called");
    let (payload, command) = args.split_last().unwrap();
    assert_eq!(
        command,
        [
            "msg",
            "plugin",
            "0rgl/localsend-plus:service",
            "all",
            "send"
        ]
    );
    assert!(!fixture.dir.path().join("marker").exists());
    payload
        .lines()
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect()
}

fn assert_sent(fixture: &Fixture) {
    let mut expected = vec![PATHS.len().to_string()];
    expected.extend(PATHS.map(str::to_string));
    assert_eq!(sent_lines(fixture), expected);
}

/// The arguments KIO runs a service menu's Exec line with: string escapes,
/// then quoting, then field codes, as the Desktop Entry specification orders
/// them (only the escapes and codes the entry uses).
fn desktop_exec(exec: &str, files: &[&str]) -> Vec<String> {
    let exec = exec.replace("\\\\", "\\");
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quoted = false;
    let mut chars = exec.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => quoted = !quoted,
            '\\' if quoted => word.extend(chars.next()),
            ' ' if !quoted => words.push(std::mem::take(&mut word)),
            c => word.push(c),
        }
    }
    words.push(word);
    words
        .into_iter()
        .filter(|word| !word.is_empty())
        .flat_map(|word| match word.as_str() {
            "%F" => files.iter().map(|file| file.to_string()).collect(),
            _ => vec![word.replace("%%", "%")],
        })
        .collect()
}

#[test]
fn dolphin_entry_sends_the_selected_paths() {
    let fixture = Fixture::new();
    let entry = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../extras/localsend-plus.desktop"),
    )
    .unwrap();
    let exec = entry
        .lines()
        .find_map(|line| line.strip_prefix("Exec="))
        .unwrap();
    let args = desktop_exec(exec, &PATHS);
    let status = Command::new(&args[0])
        .args(&args[1..])
        .current_dir(fixture.dir.path())
        .env("PATH", &fixture.path)
        .status()
        .unwrap();
    assert!(status.success());
    assert_sent(&fixture);
}

#[test]
fn nautilus_script_sends_the_selected_paths() {
    let fixture = Fixture::new();
    // Nautilus ends every path and URI with a newline.
    let selected: String = PATHS.iter().map(|path| format!("{path}\n")).collect();
    let uris: String = PATHS.iter().map(|_| "file:///x\n").collect();
    let status = fixture
        .command(&extra("nautilus-script"))
        .env("NAUTILUS_SCRIPT_SELECTED_FILE_PATHS", selected)
        .env("NAUTILUS_SCRIPT_SELECTED_URIS", uris)
        .status()
        .unwrap();
    assert!(status.success());
    assert_sent(&fixture);
}

#[test]
fn nautilus_script_does_nothing_without_local_paths() {
    let fixture = Fixture::new();
    let status = fixture
        .command(&extra("nautilus-script"))
        .env("NAUTILUS_SCRIPT_SELECTED_FILE_PATHS", "")
        .status()
        .unwrap();
    assert!(status.success());
    assert_eq!(fixture.recorded(), None);
}

#[test]
fn nemo_script_sends_its_arguments() {
    let fixture = Fixture::new();
    let status = fixture
        .command(&extra("localsend-plus-send.sh"))
        .args(PATHS)
        .status()
        .unwrap();
    assert!(status.success());
    assert_sent(&fixture);
}

#[test]
fn a_line_break_in_a_name_does_not_match_the_count() {
    let fixture = Fixture::new();
    let status = fixture
        .command(&extra("localsend-plus-send.sh"))
        .arg("/home/me/x\n/home/me/.ssh/id_ed25519")
        .status()
        .unwrap();
    assert!(status.success());
    let lines = sent_lines(&fixture);
    assert_eq!(lines[0], "1");
    assert_eq!(lines.len(), 3);
}

#[test]
fn nemo_action_runs_the_script_installed_next_to_it() {
    let action = std::fs::read_to_string(extra("localsend-plus.nemo_action")).unwrap();
    let lines: Vec<&str> = action.lines().collect();
    assert_eq!(lines.first(), Some(&"[Nemo Action]"));
    assert!(lines.contains(&"Exec=<localsend-plus-send.sh> %F"));
    // Nemo quotes each path itself only with Quote set.
    assert!(lines.contains(&"Quote=double"));
    assert!(extra("localsend-plus-send.sh").exists());
}
