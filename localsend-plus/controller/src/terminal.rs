//! `localsend-controller send`: sending files from a terminal. The device is
//! named by its alias (or the start of it) or picked from a numbered list,
//! and the command waits until the transfer has ended.

use crate::files::display_text;
use crate::rpc::{ApiError, Pin, RpcRequest, RpcResponse, TransferState};
use serde::Deserialize;
use serde_json::Value;
use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// The socket of the plugin's daemon, as `M.SOCK` in lib.luau builds it.
const PLUGIN_SOCKET: &str = "0rgl-localsend-plus.sock";
const POLL_INTERVAL: Duration = Duration::from_millis(250);
/// How long to wait for devices to answer a refresh when none is online.
const REFRESH_WAIT: Duration = Duration::from_secs(4);

const EXIT_FAILED: i32 = 1;
const EXIT_USAGE: i32 = 2;
const EXIT_CANCELLED: i32 = 130;

#[derive(Clone, Copy, PartialEq)]
enum Lang {
    En,
    Pl,
}

impl Lang {
    /// Polish when the locale says so, English otherwise.
    fn detect() -> Self {
        for name in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let Ok(value) = std::env::var(name) {
                if !value.is_empty() {
                    return if value.starts_with("pl") {
                        Lang::Pl
                    } else {
                        Lang::En
                    };
                }
            }
        }
        Lang::En
    }

    fn pick(self, en: &'static str, pl: &'static str) -> &'static str {
        match self {
            Lang::En => en,
            Lang::Pl => pl,
        }
    }
}

/// The parts of a daemon snapshot this command reads. Fields it does not
/// know are skipped, so a newer daemon still works with it.
#[derive(Deserialize)]
struct SnapshotView {
    #[serde(default)]
    devices: Vec<DeviceView>,
    #[serde(default)]
    transfers: Vec<TransferView>,
}

#[derive(Deserialize)]
struct DeviceView {
    fingerprint: String,
    alias: String,
    #[serde(default)]
    online: bool,
    address: Option<AddressView>,
    #[serde(default)]
    favorite: bool,
}

#[derive(Deserialize)]
struct AddressView {
    host: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TransferView {
    id: String,
    state: TransferState,
    #[serde(default)]
    completed_bytes: u64,
    #[serde(default)]
    total_bytes: u64,
    error: Option<ApiError>,
}

#[derive(Clone, Debug, PartialEq)]
struct Device {
    fingerprint: String,
    alias: String,
    host: String,
    favorite: bool,
}

pub async fn run(socket: Option<PathBuf>, items: Vec<String>, list: bool) -> i32 {
    let lang = Lang::detect();
    let Some(socket) = socket.or_else(plugin_socket) else {
        eprintln!(
            "{}",
            lang.pick("XDG_RUNTIME_DIR is not set.", "Brak XDG_RUNTIME_DIR.")
        );
        return EXIT_FAILED;
    };
    match send(&socket, items, list, lang).await {
        Ok(code) => code,
        Err(error) => {
            eprintln!("{}", describe(&error, lang));
            EXIT_FAILED
        }
    }
}

async fn send(socket: &Path, items: Vec<String>, list: bool, lang: Lang) -> Result<i32, ApiError> {
    if list {
        for device in online_devices(&snapshot(socket).await?) {
            println!("{}", device.alias);
        }
        return Ok(0);
    }

    let (files, query) = split_arguments(&items);
    if files.is_empty() {
        eprintln!(
            "{}",
            lang.pick(
                "Usage: localsend FILE... [DEVICE]",
                "Użycie: localsend PLIK... [URZĄDZENIE]"
            )
        );
        return Ok(EXIT_USAGE);
    }
    if let Some(missing) = files.iter().find(|file| !Path::new(file).exists()) {
        let text = lang.pick(
            "No such file or folder: ",
            "Nie ma takiego pliku ani folderu: ",
        );
        eprintln!("{text}{missing}");
        return Ok(EXIT_USAGE);
    }
    let paths = crate::absolute_paths(files.iter().map(PathBuf::from).collect())?;

    let devices = devices_or_refresh(socket).await?;
    if devices.is_empty() {
        eprintln!(
            "{}",
            lang.pick(
                "No device is online. Open LocalSend on the other device and try again.",
                "Żadne urządzenie nie jest online. Otwórz LocalSend na drugim urządzeniu i spróbuj ponownie."
            )
        );
        return Ok(EXIT_FAILED);
    }
    // A name that matches one favorite sends at once; anything else asks,
    // so a stranger cannot take a favorite's name and get its files.
    let found = query
        .as_deref()
        .map(|query| matching(&devices, query))
        .unwrap_or_default();
    let device = match found.as_slice() {
        [only] if only.favorite => (*only).clone(),
        _ => {
            if let (Some(query), true) = (&query, found.is_empty()) {
                let text = lang.pick(
                    "No online device matches",
                    "Żadne urządzenie online nie pasuje do",
                );
                eprintln!("{text} \"{query}\".");
            }
            let candidates: Vec<&Device> = if found.is_empty() {
                devices.iter().collect()
            } else {
                found
            };
            match choose(&candidates, lang)? {
                Some(device) => device.clone(),
                None => return Ok(cancelled(lang)),
            }
        }
    };

    let label = if files.len() == 1 {
        crate::files::display_name(&files[0])
    } else {
        items_label(files.len(), lang)
    };
    eprintln!(
        "{} {label} {} {}",
        lang.pick("Sending", "Wysyłam"),
        lang.pick("to", "do"),
        device.alias
    );

    let mut pin = None;
    loop {
        let id = start(socket, &device, &paths, pin.take()).await?;
        match watch(socket, &id, lang).await? {
            Outcome::Done(code) => return Ok(code),
            Outcome::NeedsPin(error) => {
                if error.code == "pin_invalid" {
                    eprintln!("{}", lang.pick("Wrong PIN.", "Błędny PIN."));
                }
                match ask_pin(lang)? {
                    Some(entered) => pin = Some(entered),
                    None => return Ok(cancelled(lang)),
                }
            }
        }
    }
}

fn cancelled(lang: Lang) -> i32 {
    eprintln!("{}", lang.pick("Cancelled.", "Anulowano."));
    EXIT_CANCELLED
}

/// "3 items" / "3 pozycje", "5 pozycji".
fn items_label(count: usize, lang: Lang) -> String {
    match lang {
        Lang::En => format!("{count} items"),
        Lang::Pl => {
            let few = (2..=4).contains(&(count % 10)) && !(12..=14).contains(&(count % 100));
            format!("{count} {}", if few { "pozycje" } else { "pozycji" })
        }
    }
}

fn plugin_socket() -> Option<PathBuf> {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .map(|runtime| runtime.join(PLUGIN_SOCKET))
}

/// Splits `FILE... [DEVICE]`: the last argument names a device unless it is
/// an existing file or folder, or the only argument.
fn split_arguments(items: &[String]) -> (Vec<String>, Option<String>) {
    match items.split_last() {
        Some((last, rest)) if !rest.is_empty() && !Path::new(last).exists() => {
            (rest.to_vec(), Some(last.clone()))
        }
        _ => (items.to_vec(), None),
    }
}

async fn call(socket: &Path, request: RpcRequest) -> Result<Value, ApiError> {
    let response: RpcResponse = crate::call_daemon(socket, &request).await?;
    if response.ok {
        Ok(response.result.unwrap_or(Value::Null))
    } else {
        Err(response
            .error
            .unwrap_or_else(|| ApiError::new("unknown", "Unknown error")))
    }
}

async fn snapshot(socket: &Path) -> Result<SnapshotView, ApiError> {
    serde_json::from_value(call(socket, RpcRequest::Snapshot {}).await?).map_err(|_| {
        ApiError::new(
            "protocol_error",
            "The daemon returned an unreadable snapshot",
        )
    })
}

/// Online devices with an HTTPS address, favorites first, then by alias.
fn online_devices(snapshot: &SnapshotView) -> Vec<Device> {
    let mut devices: Vec<Device> = snapshot
        .devices
        .iter()
        .filter(|device| device.online)
        .filter_map(|device| {
            Some(Device {
                fingerprint: device.fingerprint.clone(),
                // Cleaned here too, in case the daemon is an older build.
                alias: display_text(&device.alias),
                host: device.address.as_ref()?.host.clone(),
                favorite: device.favorite,
            })
        })
        .collect();
    devices.sort_by(|a, b| {
        b.favorite
            .cmp(&a.favorite)
            .then_with(|| a.alias.to_lowercase().cmp(&b.alias.to_lowercase()))
    });
    devices
}

/// The online devices; when none is, asks the daemon to look again and
/// waits a few seconds for answers.
async fn devices_or_refresh(socket: &Path) -> Result<Vec<Device>, ApiError> {
    let devices = online_devices(&snapshot(socket).await?);
    if !devices.is_empty() {
        return Ok(devices);
    }
    call(socket, RpcRequest::Refresh {}).await?;
    let deadline = Instant::now() + REFRESH_WAIT;
    while Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(500)).await;
        let devices = online_devices(&snapshot(socket).await?);
        if !devices.is_empty() {
            return Ok(devices);
        }
    }
    Ok(Vec::new())
}

/// The favorites that match `query` when any does, else the other devices
/// that do. Within a group, see [`best_matches`].
fn matching<'a>(devices: &'a [Device], query: &str) -> Vec<&'a Device> {
    let (favorites, others): (Vec<&Device>, Vec<&Device>) =
        devices.iter().partition(|device| device.favorite);
    let found = best_matches(&favorites, query);
    if found.is_empty() {
        best_matches(&others, query)
    } else {
        found
    }
}

/// Devices whose alias equals the query, else starts with it, else contains
/// it (ignoring case); else whose fingerprint starts with it.
fn best_matches<'a>(devices: &[&'a Device], query: &str) -> Vec<&'a Device> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return Vec::new();
    }
    let alias_tests: [fn(&str, &str) -> bool; 3] = [
        |alias, query| alias == query,
        |alias, query| alias.starts_with(query),
        |alias, query| alias.contains(query),
    ];
    for test in alias_tests {
        let found: Vec<&Device> = devices
            .iter()
            .copied()
            .filter(|device| test(&device.alias.to_lowercase(), &query))
            .collect();
        if !found.is_empty() {
            return found;
        }
    }
    devices
        .iter()
        .copied()
        .filter(|device| query.len() >= 4 && device.fingerprint.to_lowercase().starts_with(&query))
        .collect()
}

/// Shows a numbered list and reads the choice; None when the user cancels.
fn choose<'a>(devices: &[&'a Device], lang: Lang) -> Result<Option<&'a Device>, ApiError> {
    let width = devices
        .iter()
        .map(|device| device.alias.chars().count())
        .max()
        .unwrap_or(0);
    eprintln!("{}", lang.pick("Send to which device?", "Komu wysłać?"));
    for (index, device) in devices.iter().enumerate() {
        let pad = width - device.alias.chars().count();
        eprintln!(
            "  {:>2}  {}{}  {}  {}  {}",
            index + 1,
            device.alias,
            " ".repeat(pad),
            if device.favorite { "★" } else { " " },
            short_fingerprint(&device.fingerprint),
            device.host
        );
    }
    if !std::io::stdin().is_terminal() {
        return Err(ApiError::new(
            "device_ambiguous",
            lang.pick(
                "Name a favorite as the last argument, or run this in a terminal to pick a device.",
                "Podaj ulubione urządzenie jako ostatni argument albo uruchom w terminalu, żeby je wybrać.",
            ),
        ));
    }
    loop {
        let answer = prompt(lang.pick("Number (Enter cancels): ", "Numer (Enter anuluje): "))?;
        let answer = answer.trim();
        if answer.is_empty() {
            return Ok(None);
        }
        match answer.parse::<usize>() {
            Ok(number) if (1..=devices.len()).contains(&number) => {
                return Ok(Some(devices[number - 1]));
            }
            _ => eprintln!(
                "{}",
                lang.pick("Enter a number from the list.", "Wpisz numer z listy.")
            ),
        }
    }
}

/// The first characters of a fingerprint, enough to tell devices with the
/// same alias apart (as `lib.shortFingerprint` shows them in the panel).
fn short_fingerprint(fingerprint: &str) -> &str {
    fingerprint.get(..8).unwrap_or(fingerprint)
}

fn prompt(text: &str) -> Result<String, ApiError> {
    eprint!("{text}");
    let _ = std::io::stderr().flush();
    let mut line = String::new();
    std::io::stdin()
        .lock()
        .read_line(&mut line)
        .map_err(|_| ApiError::new("input_error", "Could not read the answer"))?;
    Ok(line)
}

/// Asks for the receiver's PIN without echoing it; None when the user
/// enters nothing.
fn ask_pin(lang: Lang) -> Result<Option<Pin>, ApiError> {
    if !std::io::stdin().is_terminal() {
        return Err(ApiError::new(
            "pin_required",
            lang.pick("The receiver asks for a PIN.", "Odbiorca prosi o PIN."),
        ));
    }
    let entered = {
        let _echo = EchoOff::new();
        prompt(lang.pick(
            "Receiver's PIN (Enter cancels): ",
            "PIN odbiorcy (Enter anuluje): ",
        ))?
    };
    eprintln!();
    let entered = entered.trim_end_matches(['\r', '\n']).to_string();
    if entered.is_empty() {
        return Ok(None);
    }
    Pin::try_from(entered).map(Some)
}

/// Turns terminal echo off for its lifetime.
struct EchoOff(Option<libc::termios>);

impl EchoOff {
    fn new() -> Self {
        // SAFETY: termios is a plain C struct, valid when all zeroes.
        let mut original: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: `original` is a writable termios that the call fills in.
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } != 0 {
            return Self(None);
        }
        let mut silent = original;
        silent.c_lflag &= !libc::ECHO;
        // SAFETY: `silent` is the settings tcgetattr returned, with echo off.
        unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &silent) };
        Self(Some(original))
    }
}

impl Drop for EchoOff {
    fn drop(&mut self) {
        if let Some(original) = &self.0 {
            // SAFETY: `original` is the settings tcgetattr returned.
            unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, original) };
        }
    }
}

async fn start(
    socket: &Path,
    device: &Device,
    paths: &[String],
    pin: Option<Pin>,
) -> Result<String, ApiError> {
    let result = call(
        socket,
        RpcRequest::SendFiles {
            device: device.fingerprint.clone(),
            paths: paths.to_vec(),
            pin,
        },
    )
    .await?;
    result["transfer"]["id"]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| ApiError::new("protocol_error", "The daemon returned no transfer"))
}

enum Outcome {
    /// The transfer ended; the exit code to return.
    Done(i32),
    /// The receiver wants a PIN (pin_required) or another one (pin_invalid).
    NeedsPin(ApiError),
}

/// Follows a transfer until it ends, showing its progress. Ctrl+C cancels
/// it; a second Ctrl+C stops waiting.
async fn watch(socket: &Path, id: &str, lang: Lang) -> Result<Outcome, ApiError> {
    let mut progress = Progress::new(lang);
    let mut cancelling = false;
    let mut ticker = tokio::time::interval(POLL_INTERVAL);
    loop {
        tokio::select! {
            _ = ticker.tick() => {}
            _ = tokio::signal::ctrl_c() => {
                if cancelling {
                    progress.finish();
                    return Ok(Outcome::Done(EXIT_CANCELLED));
                }
                cancelling = true;
                progress.say(lang.pick("Cancelling…", "Anuluję…"));
                let _ = call(socket, RpcRequest::Cancel { transfer: id.to_string() }).await;
                continue;
            }
        }
        let snapshot = snapshot(socket).await?;
        let Some(transfer) = snapshot
            .transfers
            .into_iter()
            .find(|transfer| transfer.id == id)
        else {
            progress.finish();
            return Err(ApiError::new(
                "transfer_lost",
                lang.pick(
                    "The daemon no longer lists the transfer.",
                    "Demon nie pokazuje już tego transferu.",
                ),
            ));
        };
        match transfer.state {
            TransferState::Preparing => progress.say(lang.pick(
                "Waiting for the receiver to accept…",
                "Czekam, aż odbiorca zaakceptuje…",
            )),
            TransferState::Transferring | TransferState::Cancelling => {
                progress.bytes(transfer.completed_bytes, transfer.total_bytes)
            }
            TransferState::Completed => {
                progress.finish();
                eprintln!("{}", lang.pick("Sent.", "Wysłano."));
                return Ok(Outcome::Done(0));
            }
            TransferState::Declined => {
                progress.finish();
                eprintln!(
                    "{}",
                    lang.pick("The receiver declined.", "Odbiorca odrzucił.")
                );
                return Ok(Outcome::Done(EXIT_FAILED));
            }
            TransferState::Cancelled => {
                progress.finish();
                eprintln!("{}", lang.pick("Cancelled.", "Anulowano."));
                return Ok(Outcome::Done(EXIT_CANCELLED));
            }
            TransferState::Failed => {
                progress.finish();
                let error = transfer
                    .error
                    .unwrap_or_else(|| ApiError::new("unknown", ""));
                if matches!(error.code.as_str(), "pin_required" | "pin_invalid") {
                    return Ok(Outcome::NeedsPin(error));
                }
                eprintln!("{}", describe(&error, lang));
                return Ok(Outcome::Done(EXIT_FAILED));
            }
        }
    }
}

/// One status line, redrawn in place on a terminal and printed once per
/// change elsewhere.
struct Progress {
    lang: Lang,
    terminal: bool,
    shown: String,
    started: Option<Instant>,
}

impl Progress {
    fn new(lang: Lang) -> Self {
        Self {
            lang,
            terminal: std::io::stderr().is_terminal(),
            shown: String::new(),
            started: None,
        }
    }

    fn say(&mut self, text: &str) {
        if text == self.shown {
            return;
        }
        if self.terminal {
            eprint!("\r\x1b[2K{text}");
            let _ = std::io::stderr().flush();
        } else {
            eprintln!("{text}");
        }
        self.shown = text.to_string();
    }

    fn bytes(&mut self, done: u64, total: u64) {
        let started = *self.started.get_or_insert_with(Instant::now);
        if !self.terminal {
            let text = self.lang.pick("Transferring…", "Przesyłam…");
            self.say(text);
            return;
        }
        const WIDTH: u64 = 24;
        let share = |scale: u64| {
            done.min(total)
                .saturating_mul(scale)
                .checked_div(total)
                .unwrap_or(0)
        };
        let (filled, percent) = (share(WIDTH), share(100));
        let seconds = started.elapsed().as_secs_f64();
        let speed = if seconds > 0.5 {
            format!(
                "  {}/s",
                crate::files::format_bytes((done as f64 / seconds) as u64)
            )
        } else {
            String::new()
        };
        let text = format!(
            "[{}{}] {:>3}%  {} / {}{}",
            "#".repeat(filled as usize),
            "-".repeat((WIDTH - filled) as usize),
            percent,
            crate::files::format_bytes(done),
            crate::files::format_bytes(total),
            speed
        );
        self.say(&text);
    }

    /// Ends the status line, so the next message starts on its own line.
    fn finish(&mut self) {
        if self.terminal && !self.shown.is_empty() {
            eprintln!();
        }
        self.shown.clear();
    }
}

/// A message for an error, in the user's language where it is a known one.
fn describe(error: &ApiError, lang: Lang) -> String {
    let known = match error.code.as_str() {
        "daemon_unavailable" | "daemon_timeout" => Some(lang.pick(
            "LocalSend Plus is not running. Turn the plugin on in Noctalia.",
            "LocalSend Plus nie działa. Włącz plugin w Noctalii.",
        )),
        "outgoing_busy" => {
            Some(lang.pick("Another send is still running.", "Trwa już inna wysyłka."))
        }
        "pin_locked" => Some(lang.pick(
            "Too many wrong PINs. LocalSend on the receiver has to restart first.",
            "Za dużo błędnych PIN-ów. LocalSend u odbiorcy musi się najpierw zrestartować.",
        )),
        "peer_busy" => Some(lang.pick(
            "The receiver is busy with another transfer.",
            "Odbiorca jest zajęty innym transferem.",
        )),
        "device_offline" | "device_not_found" => Some(lang.pick(
            "The device is no longer online.",
            "Urządzenie nie jest już online.",
        )),
        "invalid_pin" => {
            Some(lang.pick("A PIN has 1 to 64 characters.", "PIN ma od 1 do 64 znaków."))
        }
        _ => None,
    };
    match known {
        Some(text) => text.to_string(),
        None if error.message.is_empty() => error.code.clone(),
        None => error.message.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device(alias: &str, fingerprint: &str, favorite: bool) -> Device {
        Device {
            fingerprint: fingerprint.to_string(),
            alias: alias.to_string(),
            host: "10.0.0.2".to_string(),
            favorite,
        }
    }

    #[test]
    fn matches_the_alias_before_the_fingerprint() {
        let devices = [
            device("Telefon Pixel", "AB12CD", false),
            device("Telewizor", "EF34AB", false),
            device("Laptop", "TE99AA", false),
        ];
        let aliases = |query| -> Vec<&str> {
            matching(&devices, query)
                .iter()
                .map(|d| d.alias.as_str())
                .collect()
        };
        assert_eq!(aliases("telefon pixel"), ["Telefon Pixel"]);
        assert_eq!(aliases("TEL"), ["Telefon Pixel", "Telewizor"]);
        assert_eq!(aliases("pixel"), ["Telefon Pixel"]);
        assert_eq!(aliases("ef34"), ["Telewizor"]);
        assert!(
            aliases("ab").is_empty(),
            "a short query is not a fingerprint"
        );
        assert!(aliases("  ").is_empty());
    }

    #[test]
    fn favorites_match_before_a_stranger_with_a_closer_name() {
        let devices = [
            device("Pixel 8", "AB12CD34EF", true),
            device("pixel", "9F9F9F9F9F", false),
            device("Laptop", "TE99AA", false),
        ];
        let aliases = |query| -> Vec<&str> {
            matching(&devices, query)
                .iter()
                .map(|d| d.alias.as_str())
                .collect()
        };
        assert_eq!(aliases("pixel"), ["Pixel 8"]);
        assert_eq!(aliases("lap"), ["Laptop"]);
        assert_eq!(short_fingerprint(&devices[0].fingerprint), "AB12CD34");
        assert_eq!(short_fingerprint("AB"), "AB");
    }

    #[test]
    fn the_last_argument_names_the_device_unless_it_is_a_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("a.txt");
        std::fs::write(&file, "a").unwrap();
        let file = file.to_str().unwrap().to_string();
        let args = |items: &[&str]| {
            split_arguments(&items.iter().map(|s| s.to_string()).collect::<Vec<_>>())
        };

        assert_eq!(
            args(&[&file, "phone"]),
            (vec![file.clone()], Some("phone".into()))
        );
        assert_eq!(
            args(&[&file, &file]),
            (vec![file.clone(), file.clone()], None)
        );
        assert_eq!(args(&[&file]), (vec![file.clone()], None));
        assert_eq!(
            args(&["missing.txt"]),
            (vec!["missing.txt".to_string()], None)
        );
    }

    #[test]
    fn counts_items_in_polish() {
        assert_eq!(items_label(3, Lang::Pl), "3 pozycje");
        assert_eq!(items_label(5, Lang::Pl), "5 pozycji");
        assert_eq!(items_label(12, Lang::Pl), "12 pozycji");
        assert_eq!(items_label(22, Lang::Pl), "22 pozycje");
        assert_eq!(items_label(2, Lang::En), "2 items");
    }

    #[test]
    fn lists_online_devices_with_favorites_first() {
        let snapshot: SnapshotView = serde_json::from_value(serde_json::json!({"devices": [
            {"fingerprint": "A", "alias": "zeta", "online": true, "favorite": false,
             "address": {"host": "10.0.0.3", "port": 53317, "protocol": "https"}},
            {"fingerprint": "B", "alias": "Offline", "online": false, "favorite": true, "address": null},
            {"fingerprint": "C", "alias": "Phone", "online": true, "favorite": true,
             "address": {"host": "10.0.0.4", "port": 53317, "protocol": "https"}},
            {"fingerprint": "D", "alias": "alpha", "online": true, "favorite": false,
             "address": {"host": "10.0.0.5", "port": 53317, "protocol": "https"}},
        ]}))
        .unwrap();
        let aliases: Vec<String> = online_devices(&snapshot)
            .into_iter()
            .map(|d| d.alias)
            .collect();
        assert_eq!(aliases, ["Phone", "alpha", "zeta"]);
    }
}
