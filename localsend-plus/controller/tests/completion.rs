//! The shell completions in `extras/terminal/` offer the aliases of the
//! devices online now, which come from the network. These tests feed hostile
//! aliases through a stand-in controller and check that the completion hands
//! them back verbatim and never runs them.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use tempfile::TempDir;

struct Fixture {
    dir: TempDir,
    /// PATH with the stand-in controller first.
    path: String,
    /// An empty folder to run in, so file completion adds nothing.
    work: PathBuf,
    aliases: Vec<String>,
}

impl Fixture {
    /// A `localsend-controller` stand-in whose `send --list` prints aliases
    /// that would create a marker file if a shell expanded them.
    fn new() -> Self {
        let dir = TempDir::new().unwrap();
        let root = dir.path();
        let aliases = vec![
            format!("$(touch {})", root.join("marker-subst").display()),
            format!("`touch {}`", root.join("marker-backtick").display()),
            "Galaxy S25".to_string(),
        ];
        let bin = root.join("bin");
        std::fs::create_dir(&bin).unwrap();
        let mut script = String::from("#!/bin/sh\n");
        for alias in &aliases {
            assert!(!alias.contains('\''));
            script.push_str(&format!("printf '%s\\n' '{alias}'\n"));
        }
        let controller = bin.join("localsend-controller");
        std::fs::write(&controller, script).unwrap();
        std::fs::set_permissions(&controller, std::fs::Permissions::from_mode(0o755)).unwrap();
        let work = root.join("work");
        std::fs::create_dir(&work).unwrap();
        let path = format!(
            "{}:{}",
            bin.display(),
            std::env::var("PATH").unwrap_or_default()
        );
        Fixture {
            dir,
            path,
            work,
            aliases,
        }
    }

    fn command(&self, program: &str) -> Command {
        let mut command = Command::new(program);
        command
            .current_dir(&self.work)
            .env("PATH", &self.path)
            .env("HOME", self.dir.path())
            .env("XDG_CONFIG_HOME", self.dir.path().join("config"))
            .env("XDG_DATA_HOME", self.dir.path().join("data"));
        command
    }

    fn assert_nothing_ran(&self) {
        for marker in ["marker-subst", "marker-backtick"] {
            assert!(
                !self.dir.path().join(marker).exists(),
                "the completion ran a device alias as a command ({marker})"
            );
        }
    }
}

fn completion(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../extras/terminal")
        .join(name)
}

fn has(program: &str) -> bool {
    Command::new(program)
        .arg("--version")
        .output()
        .is_ok_and(|output| output.status.success())
}

fn lines(output: std::process::Output) -> Vec<String> {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(str::to_string)
        .collect()
}

/// Runs the bash completion for `localsend <cur>` and returns COMPREPLY.
fn bash_complete(fixture: &Fixture, cur: &str) -> Vec<String> {
    let script = r#"source "$1"; COMP_WORDS=(localsend "$2"); COMP_CWORD=1; _localsend; printf '%s\n' "${COMPREPLY[@]}""#;
    let output = fixture
        .command("bash")
        .args(["--norc", "--noprofile", "-c", script, "bash"])
        .arg(completion("localsend.bash"))
        .arg(cur)
        .output()
        .unwrap();
    lines(output)
        .into_iter()
        .filter(|line| !line.is_empty())
        .collect()
}

#[test]
fn bash_completion_offers_aliases_verbatim_without_running_them() {
    if !has("bash") {
        eprintln!("bash is not installed, skipping");
        return;
    }
    let fixture = Fixture::new();
    assert_eq!(bash_complete(&fixture, ""), fixture.aliases);
    assert_eq!(bash_complete(&fixture, "Gal"), ["Galaxy S25"]);
    assert_eq!(bash_complete(&fixture, "$("), [fixture.aliases[0].clone()]);
    // A typed prefix is literal text, not a pattern.
    assert!(bash_complete(&fixture, "*").is_empty());
    fixture.assert_nothing_ran();
}

#[test]
fn fish_completion_offers_aliases_verbatim_without_running_them() {
    if !has("fish") {
        eprintln!("fish is not installed, skipping");
        return;
    }
    let fixture = Fixture::new();
    let script = r#"source $argv[1]; complete -C 'localsend '"#;
    let output = fixture
        .command("fish")
        .args(["--no-config", "-c", script])
        .arg(completion("localsend.fish"))
        .output()
        .unwrap();
    let offered: Vec<String> = lines(output)
        .into_iter()
        .map(|line| line.split('\t').next().unwrap_or_default().to_string())
        .collect();
    for alias in &fixture.aliases {
        assert!(offered.contains(alias), "{alias} missing from {offered:?}");
    }
    fixture.assert_nothing_ran();
}
