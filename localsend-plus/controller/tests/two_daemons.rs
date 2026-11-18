//! End-to-end tests: two controller daemons on loopback send to each other.
//!
//! Each test starts its own pair, since a decline cooldown or a PIN lockout
//! must not leak into the next test. The daemons run in favorites mode, which
//! neither announces nor scans, so they stay off the local network; the one
//! test that needs a non-favorite sender says so.

use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tempfile::TempDir;

const BIN: &str = env!("CARGO_BIN_EXE_localsend-controller");
const TIMEOUT: Duration = Duration::from_secs(20);
/// Starting includes generating an RSA key, which a busy CI runner running
/// every test at once can make slow.
const START_TIMEOUT: Duration = Duration::from_secs(60);
const PIN: &str = "7391-secret";

struct Daemon {
    child: Child,
    dir: TempDir,
    socket: PathBuf,
    /// PATH with the wl-copy and wl-paste stand-ins first.
    path: String,
    port: u16,
    fingerprint: String,
    /// Everything the daemon wrote to stdout and stderr.
    output: Arc<Mutex<String>>,
}

impl Daemon {
    /// Starts `daemon` with the given extra arguments and waits until it is
    /// ready. A wl-copy stand-in writes the clipboard to `clipboard()`.
    fn start(alias: &str, extra: &[&str]) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let fake_bin = dir.path().join("bin");
        std::fs::create_dir_all(&fake_bin).unwrap();
        write_script(
            &fake_bin.join("wl-copy"),
            "#!/bin/sh\ncat > \"$LS_TEST_CLIPBOARD\"\n",
        );
        // Prints the types from LS_TEST_TYPES and the text from LS_TEST_PASTE.
        write_script(
            &fake_bin.join("wl-paste"),
            "#!/bin/sh\nif [ \"$1\" = --list-types ]; then printf '%s\\n' $LS_TEST_TYPES; \
             else cat \"$LS_TEST_PASTE\"; fi\n",
        );
        std::fs::create_dir_all(dir.path().join("inbox")).unwrap();

        let socket = dir.path().join("controller.sock");
        let port = free_port();
        let path = format!(
            "{}:{}",
            fake_bin.display(),
            std::env::var("PATH").unwrap_or_default()
        );
        let mut child = Command::new(BIN)
            .arg("--socket")
            .arg(&socket)
            .arg("daemon")
            .args(["--port", &port.to_string(), "--alias", alias])
            .args(["--visibility", "favorites"])
            .arg("--destination")
            .arg(dir.path().join("inbox"))
            .arg("--state-directory")
            .arg(dir.path().join("state"))
            .args(extra)
            .env("PATH", &path)
            .env("LS_TEST_CLIPBOARD", dir.path().join("clipboard"))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();

        let output = Arc::new(Mutex::new(String::new()));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let stdout = child.stdout.take().unwrap();
        let log = output.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if line.contains(r#""event":"ready""#) {
                    let _ = ready_tx.send(());
                }
                log.lock().unwrap().push_str(&line);
                log.lock().unwrap().push('\n');
            }
        });
        let stderr = child.stderr.take().unwrap();
        let log = output.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                log.lock().unwrap().push_str(&line);
                log.lock().unwrap().push('\n');
            }
        });
        if ready_rx.recv_timeout(START_TIMEOUT).is_err() {
            let _ = child.kill();
            panic!("{alias} did not start:\n{}", output.lock().unwrap());
        }

        let mut daemon = Self {
            child,
            path,
            dir,
            socket,
            port,
            fingerprint: String::new(),
            output,
        };
        daemon.fingerprint = daemon.snapshot()["daemon"]["fingerprint"]
            .as_str()
            .unwrap()
            .to_string();
        daemon
    }

    /// Runs a controller command against this daemon and returns its JSON.
    fn rpc(&self, args: &[&str]) -> Value {
        self.rpc_with_clipboard(args, "", "text/plain")
    }

    /// Like `rpc`, with `text` on the clipboard, offered as `types`.
    fn rpc_with_clipboard(&self, args: &[&str], text: &str, types: &str) -> Value {
        let paste = self.dir.path().join(format!("paste-{}", rand_suffix()));
        std::fs::write(&paste, text).unwrap();
        let output = Command::new(BIN)
            .arg("--socket")
            .arg(&self.socket)
            .args(args)
            .env("PATH", &self.path)
            .env("LS_TEST_PASTE", &paste)
            .env("LS_TEST_TYPES", types)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        serde_json::from_slice(&output.stdout).unwrap_or_else(|_| {
            panic!(
                "{args:?} printed no JSON: {}",
                String::from_utf8_lossy(&output.stderr)
            )
        })
    }

    fn snapshot(&self) -> Value {
        let response = self.rpc(&["snapshot"]);
        assert_eq!(response["ok"], true, "{response}");
        response["result"].clone()
    }

    /// Makes `other` a favorite reachable on loopback and waits until this
    /// daemon has confirmed it over HTTPS.
    fn befriend(&self, other: &Daemon) {
        let favorite = format!("{}=127.0.0.1:{}", other.fingerprint, other.port);
        let response = self.rpc(&[
            "set-visibility",
            "--mode",
            "favorites",
            "--favorite",
            &favorite,
        ]);
        assert_eq!(response["ok"], true, "{response}");
        self.rpc(&["refresh"]);
        wait_until("the favorite is online", || {
            self.snapshot()["devices"]
                .as_array()
                .unwrap()
                .iter()
                .any(|d| d["fingerprint"] == other.fingerprint.as_str() && d["online"] == true)
        });
    }

    fn pin_file(&self, pin: &str) -> String {
        let path = self.dir.path().join(format!("pin-{}", rand_suffix()));
        std::fs::write(&path, pin).unwrap();
        path.to_str().unwrap().to_string()
    }

    fn inbox(&self) -> PathBuf {
        self.dir.path().join("inbox")
    }

    fn clipboard(&self) -> PathBuf {
        self.dir.path().join("clipboard")
    }

    /// Waits for the incoming request and returns it.
    fn incoming(&self) -> Value {
        let mut found = Value::Null;
        wait_until("an incoming request", || {
            found = self.snapshot()["incoming"].clone();
            !found.is_null()
        });
        found
    }

    /// Waits until the transfer with this id has ended and returns it.
    fn finished(&self, id: &str) -> Value {
        let mut found = Value::Null;
        wait_until("the transfer to finish", || {
            found = transfer(&self.snapshot(), id);
            !found["finishedAt"].is_null()
        });
        found
    }

    fn output(&self) -> String {
        self.output.lock().unwrap().clone()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        self.rpc(&["shutdown"]);
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if let Ok(Some(_)) = self.child.try_wait() {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Two daemons that can send to each other: A is B's favorite and the other
/// way round.
fn pair(a_args: &[&str], b_args: &[&str]) -> (Daemon, Daemon) {
    let a = Daemon::start("test-a", a_args);
    let b = Daemon::start("test-b", b_args);
    a.befriend(&b);
    b.befriend(&a);
    (a, b)
}

/// Starts a send from `from` to `to` and returns its transfer id.
fn send(from: &Daemon, to: &Daemon, what: &[&str]) -> String {
    let mut args = vec![what[0], "--device", &to.fingerprint];
    args.extend(&what[1..]);
    transfer_id(&from.rpc(&args))
}

/// Previews `text` on the clipboard the way the panel does, then sends it.
fn send_clipboard(from: &Daemon, to: &Daemon, text: &str) -> String {
    let preview = from.rpc_with_clipboard(&["read-clipboard"], text, "text/plain");
    assert_eq!(preview["ok"], true, "{preview}");
    let sha = preview["result"]["sha256"].as_str().unwrap();
    transfer_id(&from.rpc_with_clipboard(
        &[
            "send-clipboard",
            "--device",
            &to.fingerprint,
            "--expect-sha256",
            sha,
        ],
        text,
        "text/plain",
    ))
}

fn transfer_id(response: &Value) -> String {
    assert_eq!(response["ok"], true, "{response}");
    response["result"]["transfer"]["id"]
        .as_str()
        .unwrap()
        .to_string()
}

fn transfer(snapshot: &Value, id: &str) -> Value {
    snapshot["transfers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"] == id)
        .cloned()
        .unwrap_or(Value::Null)
}

fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + TIMEOUT;
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// A port that is free right now and not handed out before in this run:
/// the tests run in parallel, and the kernel may offer a just-released port
/// again before the daemon that got it has bound it.
fn free_port() -> u16 {
    static HANDED_OUT: Mutex<Vec<u16>> = Mutex::new(Vec::new());
    loop {
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let mut handed_out = HANDED_OUT.lock().unwrap();
        if !handed_out.contains(&port) {
            handed_out.push(port);
            return port;
        }
    }
}

fn rand_suffix() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos()
}

fn write_script(path: &Path, text: &str) {
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn write_file(path: &Path, text: &str) -> String {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
    path.to_str().unwrap().to_string()
}

#[test]
fn sends_a_file_after_the_receiver_accepts() {
    let (a, b) = pair(&[], &[]);
    let file = write_file(&a.dir.path().join("out/hello.txt"), "hello over TLS");

    let id = send(&a, &b, &["send-files", "--path", &file]);
    let request = b.incoming();
    assert_eq!(request["sender"]["fingerprint"], a.fingerprint.as_str());
    let accepted = b.rpc(&["accept", "--request", request["id"].as_str().unwrap()]);
    assert_eq!(accepted["ok"], true, "{accepted}");

    assert_eq!(a.finished(&id)["state"], "completed");
    let received = b.inbox().join("hello.txt");
    wait_until("the file on disk", || {
        std::fs::read_to_string(&received).is_ok_and(|text| text == "hello over TLS")
    });
}

#[test]
fn sends_a_folder_with_its_structure() {
    let (a, b) = pair(&[], &[]);
    write_file(&a.dir.path().join("album/one.txt"), "1");
    write_file(&a.dir.path().join("album/sub/two.txt"), "2");
    let folder = a.dir.path().join("album");

    let id = send(&a, &b, &["send-files", "--path", folder.to_str().unwrap()]);
    let request = b.incoming();
    b.rpc(&["accept", "--request", request["id"].as_str().unwrap()]);

    assert_eq!(a.finished(&id)["state"], "completed");
    wait_until("both files on disk", || {
        std::fs::read_to_string(b.inbox().join("album/one.txt")).is_ok_and(|t| t == "1")
            && std::fs::read_to_string(b.inbox().join("album/sub/two.txt")).is_ok_and(|t| t == "2")
    });
}

#[test]
fn copies_an_accepted_text_message_without_bidi_overrides() {
    let (a, b) = pair(&[], &[]);

    let id = send_clipboard(&a, &b, "pay \u{202E}lin\u{202C} now");
    let request = b.incoming();
    assert!(request["messagePreview"].is_string(), "{request}");
    b.rpc(&["accept", "--request", request["id"].as_str().unwrap()]);

    let sent = a.finished(&id);
    assert_eq!(sent["state"], "completed");
    assert_eq!(sent["textMessage"], true);
    assert_eq!(b.finished(&id_of_incoming(&b))["textMessage"], true);
    assert_eq!(
        std::fs::read_to_string(b.clipboard()).unwrap(),
        "pay lin now"
    );
}

#[test]
fn a_declined_sender_is_declined_silently_for_a_while() {
    let (a, b) = pair(&[], &[]);
    let file = write_file(&a.dir.path().join("out/x.txt"), "x");

    let first = send(&a, &b, &["send-files", "--path", &file]);
    let request = b.incoming();
    b.rpc(&["decline", "--request", request["id"].as_str().unwrap()]);
    assert_eq!(a.finished(&first)["state"], "declined");

    let second = send(&a, &b, &["send-files", "--path", &file]);
    assert_eq!(a.finished(&second)["state"], "declined");
    assert!(b.snapshot()["incoming"].is_null());
}

#[test]
fn a_receiver_with_a_pin_checks_it() {
    let dir = tempfile::tempdir().unwrap();
    let pin = write_file(&dir.path().join("pin"), PIN);
    let (a, b) = pair(&[], &["--pin-file", &pin]);
    assert!(!Path::new(&pin).exists(), "the daemon deletes its PIN file");
    assert_eq!(b.snapshot()["daemon"]["pinRequired"], true);
    let file = write_file(&a.dir.path().join("out/p.txt"), "p");

    let none = send(&a, &b, &["send-files", "--path", &file]);
    assert_eq!(a.finished(&none)["error"]["code"], "pin_required");

    let wrong_pin = a.pin_file("0000");
    let wrong = send(
        &a,
        &b,
        &["send-files", "--path", &file, "--pin-file", &wrong_pin],
    );
    assert!(
        !Path::new(&wrong_pin).exists(),
        "the sender deletes its PIN file"
    );
    assert_eq!(a.finished(&wrong)["error"]["code"], "pin_invalid");

    let right_pin = a.pin_file(PIN);
    let right = send(
        &a,
        &b,
        &["send-files", "--path", &file, "--pin-file", &right_pin],
    );
    let request = b.incoming();
    b.rpc(&["accept", "--request", request["id"].as_str().unwrap()]);
    assert_eq!(a.finished(&right)["state"], "completed");

    let everything = format!(
        "{}{}{}{}",
        a.output(),
        b.output(),
        a.snapshot(),
        b.snapshot()
    );
    assert!(!everything.contains(PIN), "the PIN leaked: {everything}");
}

#[test]
fn three_wrong_pins_lock_the_sender_out() {
    let dir = tempfile::tempdir().unwrap();
    let pin = write_file(&dir.path().join("pin"), PIN);
    let (a, b) = pair(&[], &["--pin-file", &pin]);
    let file = write_file(&a.dir.path().join("out/l.txt"), "l");

    for _ in 0..3 {
        let wrong = a.pin_file("0000");
        let id = send(
            &a,
            &b,
            &["send-files", "--path", &file, "--pin-file", &wrong],
        );
        assert_eq!(a.finished(&id)["error"]["code"], "pin_invalid");
    }
    let right = a.pin_file(PIN);
    let id = send(
        &a,
        &b,
        &["send-files", "--path", &file, "--pin-file", &right],
    );
    assert_eq!(a.finished(&id)["error"]["code"], "pin_locked");
}

#[test]
fn auto_accept_favorites_takes_files_but_not_text() {
    let (a, b) = pair(&[], &["--auto-accept", "favorites"]);
    let file = write_file(&a.dir.path().join("out/auto.txt"), "auto");

    let id = send(&a, &b, &["send-files", "--path", &file]);
    assert_eq!(a.finished(&id)["state"], "completed");
    assert_eq!(b.finished(&id_of_incoming(&b))["autoAccepted"], true);

    send_clipboard(&a, &b, "needs a decision");
    let request = b.incoming();
    assert!(request["messagePreview"].is_string());
}

/// The id of the only incoming transfer B has seen.
fn id_of_incoming(b: &Daemon) -> String {
    b.snapshot()["transfers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["direction"] == "incoming")
        .and_then(|t| t["id"].as_str())
        .unwrap()
        .to_string()
}

#[test]
fn auto_accept_off_keeps_asking() {
    let (a, b) = pair(&[], &["--auto-accept", "off"]);
    let file = write_file(&a.dir.path().join("out/ask.txt"), "ask");

    send(&a, &b, &["send-files", "--path", &file]);
    assert!(b.incoming()["files"].is_array());
}

#[test]
fn a_new_request_is_announced_on_stdout() {
    let (a, b) = pair(&[], &["--auto-accept", "off"]);
    let file = write_file(&a.dir.path().join("out/ping.txt"), "ping");
    let changes = |daemon: &Daemon| daemon.output().matches(r#""event":"changed""#).count();
    let before = changes(&b);

    send(&a, &b, &["send-files", "--path", &file]);
    wait_until("the receiver to announce the request", || {
        changes(&b) > before
    });
    assert!(b.incoming()["files"].is_array());
}

#[test]
fn auto_accept_everyone_needs_a_long_pin() {
    let b = Daemon::start("test-b", &["--auto-accept", "everyone"]);
    assert_eq!(b.snapshot()["daemon"]["autoAccept"], "favorites");

    let dir = tempfile::tempdir().unwrap();
    let short = write_file(&dir.path().join("pin"), "1234");
    let c = Daemon::start(
        "test-c",
        &["--auto-accept", "everyone", "--pin-file", &short],
    );
    assert_eq!(c.snapshot()["daemon"]["autoAccept"], "favorites");
    assert_eq!(c.snapshot()["daemon"]["pinRequired"], true);
}

#[test]
fn a_changed_or_secret_clipboard_is_not_sent() {
    let (a, b) = pair(&[], &[]);
    let preview = a.rpc_with_clipboard(&["read-clipboard"], "first", "text/plain");
    let sha = preview["result"]["sha256"].as_str().unwrap();
    let changed = a.rpc_with_clipboard(
        &[
            "send-clipboard",
            "--device",
            &b.fingerprint,
            "--expect-sha256",
            sha,
        ],
        "second",
        "text/plain",
    );
    assert_eq!(changed["error"]["code"], "clipboard_changed");

    let secret = a.rpc_with_clipboard(
        &["read-clipboard"],
        "hunter2",
        "text/plain x-kde-passwordManagerHint",
    );
    assert_eq!(secret["error"]["code"], "clipboard_secret");
    assert!(!secret.to_string().contains("hunter2"));
}

/// The only test with a non-favorite sender, so B must be visible to
/// everyone: it announces itself on the local network for a few seconds.
#[test]
fn auto_accept_everyone_with_a_pin_takes_files_from_anyone() {
    let dir = tempfile::tempdir().unwrap();
    let pin = write_file(&dir.path().join("pin"), PIN);
    let b = Daemon::start(
        "localsend-controller-test",
        &["--auto-accept", "everyone", "--pin-file", &pin],
    );
    b.rpc(&["set-visibility", "--mode", "everyone"]);
    assert_eq!(b.snapshot()["daemon"]["autoAccept"], "everyone");
    let a = Daemon::start("test-a", &[]);
    let added = a.rpc(&["add-device", "--address", &format!("127.0.0.1:{}", b.port)]);
    assert_eq!(
        added["result"]["device"]["fingerprint"],
        b.fingerprint.as_str()
    );

    let file = write_file(&a.dir.path().join("out/any.txt"), "any");
    let pin_file = a.pin_file(PIN);
    let id = send(
        &a,
        &b,
        &["send-files", "--path", &file, "--pin-file", &pin_file],
    );
    assert_eq!(a.finished(&id)["state"], "completed");
    assert_eq!(b.finished(&id_of_incoming(&b))["autoAccepted"], true);
}

#[test]
fn add_device_reports_an_unreachable_address() {
    let a = Daemon::start("test-a", &[]);
    let response = a.rpc(&[
        "add-device",
        "--address",
        &format!("127.0.0.1:{}", free_port()),
    ]);
    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "device_unreachable");
}

/// `send FILE DEVICE` from a script: no terminal, so it prints each state
/// once and exits with the transfer's result.
#[test]
fn the_terminal_command_sends_to_a_device_named_by_alias() {
    let (a, b) = pair(&[], &["--auto-accept", "favorites"]);
    let file = write_file(&a.dir.path().join("out/cli.txt"), "from a terminal");
    let terminal = |args: &[&str]| {
        Command::new(BIN)
            .arg("--socket")
            .arg(&a.socket)
            .arg("send")
            .args(args)
            .env("LANG", "C")
            .stdin(Stdio::null())
            .output()
            .unwrap()
    };

    let listed = terminal(&["--list"]);
    assert_eq!(String::from_utf8_lossy(&listed.stdout).trim(), "test-b");

    let sent = terminal(&[&file, "TEST-B"]);
    let output = String::from_utf8_lossy(&sent.stderr);
    assert!(sent.status.success(), "{output}");
    assert!(output.contains("Sent."), "{output}");
    wait_until("the file on disk", || {
        std::fs::read_to_string(b.inbox().join("cli.txt")).is_ok_and(|t| t == "from a terminal")
    });

    // Without a terminal it cannot ask which device is meant.
    let unnamed = terminal(&[&file]);
    assert_eq!(unnamed.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&unnamed.stderr).contains("test-b"));
}
