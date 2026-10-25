mod clipboard;
mod daemon;
mod files;
mod identity;
mod rpc;
mod terminal;

use clap::{error::ErrorKind, Parser, Subcommand};
use rpc::{ApiError, AutoAccept, FavoriteSpec, Pin, RpcRequest, RpcResponse, Visibility};
use serde_json::json;
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

const MAX_RPC_BYTES: u64 = 8 * 1024 * 1024;
const RPC_TIMEOUT: Duration = Duration::from_secs(35);
/// Port of a device added by address when the address names none.
const DEFAULT_LOCALSEND_PORT: u16 = 53317;

#[derive(Parser)]
#[command(
    name = "localsend-controller",
    version,
    about = "LocalSend receiver and sender for the LocalSend Plus Noctalia plugin"
)]
struct Cli {
    /// The daemon's management socket. `send` defaults to the plugin's;
    /// every other command except `read-clipboard` needs it.
    #[arg(long, global = true, value_name = "PATH")]
    socket: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Daemon {
        #[arg(long, default_value_t = 53317)]
        port: u16,
        #[arg(long, value_name = "PATH")]
        destination: PathBuf,
        /// Name shown to other devices; a random one is picked once and kept
        /// in the state directory when this is missing.
        #[arg(long)]
        alias: Option<String>,
        #[arg(long, value_name = "PATH")]
        state_directory: PathBuf,
        #[arg(long, value_enum, default_value_t = Visibility::Everyone)]
        visibility: Visibility,
        /// File holding the PIN senders must give; it is deleted once read.
        #[arg(long, value_name = "PATH")]
        pin_file: Option<PathBuf>,
        #[arg(long, value_enum, default_value_t = AutoAccept::Off)]
        auto_accept: AutoAccept,
        /// Model shown to other devices; defaults to the os-release name.
        #[arg(long)]
        device_model: Option<String>,
    },
    /// Sends files and folders from a terminal: `send FILE... [DEVICE]`.
    /// The device is the last argument unless that is an existing file;
    /// without one, or when the name fits several devices, it asks.
    Send {
        /// Prints the online devices' names, one per line, and exits.
        #[arg(long)]
        list: bool,
        #[arg(value_name = "FILE... [DEVICE]")]
        items: Vec<String>,
    },
    Snapshot,
    Refresh,
    SendFiles {
        #[arg(long)]
        device: String,
        #[arg(long = "path", required = true, value_name = "PATH")]
        paths: Vec<PathBuf>,
        /// File holding the receiver's PIN; it is deleted once read.
        #[arg(long, value_name = "PATH")]
        pin_file: Option<PathBuf>,
    },
    SendClipboard {
        #[arg(long)]
        device: String,
        /// SHA-256 (hex) of the clipboard text the user confirmed; the send
        /// fails if the clipboard holds anything else by now.
        #[arg(long, value_name = "HEX")]
        expect_sha256: String,
        #[arg(long, value_name = "PATH")]
        pin_file: Option<PathBuf>,
    },
    /// Prints the SHA-256 of the clipboard text and its first characters,
    /// without contacting the daemon.
    ReadClipboard {
        #[arg(long, default_value_t = 400)]
        preview_chars: usize,
    },
    /// Probes `HOST[:PORT]` over HTTPS and lists the device found there.
    AddDevice {
        #[arg(long)]
        address: String,
    },
    Accept {
        #[arg(long)]
        request: String,
    },
    Decline {
        #[arg(long)]
        request: String,
    },
    Cancel {
        #[arg(long)]
        transfer: String,
    },
    SetVisibility {
        #[arg(long, value_enum)]
        mode: Visibility,
        /// `FINGERPRINT` or `FINGERPRINT=HOST:PORT`, repeatable.
        #[arg(long = "favorite", value_name = "FAVORITE")]
        favorites: Vec<FavoriteSpec>,
    },
    Shutdown,
}

#[tokio::main]
async fn main() {
    std::panic::set_hook(Box::new(|_| {
        eprintln!(
            "{}",
            json!({
                "ok": false,
                "error": {
                    "code": "panic",
                    "message": "The controller encountered an internal panic"
                }
            })
        );
    }));

    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error)
            if matches!(
                error.kind(),
                ErrorKind::DisplayHelp | ErrorKind::DisplayVersion
            ) =>
        {
            emit(&RpcResponse::success(json!({"help": error.to_string()})));
            std::process::exit(0);
        }
        Err(error) => fail(ApiError::new("invalid_arguments", error.to_string()), 2),
    };

    let command = match cli.command {
        Command::ReadClipboard { preview_chars } => {
            match clipboard::preview(preview_chars).await {
                Ok(preview) => emit(&RpcResponse::success(preview)),
                Err(error) => fail(error, 1),
            }
            std::process::exit(0);
        }
        Command::Send { list, items } => {
            std::process::exit(terminal::run(cli.socket, items, list).await);
        }
        command => command,
    };

    let Some(socket) = cli.socket else {
        fail(
            ApiError::new("invalid_arguments", "--socket is required"),
            2,
        );
    };

    let exit_code = match command {
        Command::Daemon {
            port,
            destination,
            alias,
            state_directory,
            visibility,
            pin_file,
            auto_accept,
            device_model,
        } => {
            let result = async {
                let pin = match pin_file {
                    Some(path) => {
                        Some(read_pin_file(&path).map_err(|error| anyhow::anyhow!(error.message))?)
                    }
                    None => None,
                };
                let device_model = identity::resolve_device_model(device_model)?;
                daemon::run(daemon::DaemonConfig {
                    socket,
                    port,
                    destination,
                    alias,
                    state_directory,
                    visibility,
                    pin,
                    auto_accept,
                    device_model,
                })
                .await
            }
            .await;
            match result {
                Ok(()) => 0,
                Err(error) => {
                    emit(&RpcResponse::failure(ApiError::new(
                        "daemon_start_failed",
                        error.to_string(),
                    )));
                    1
                }
            }
        }
        command => {
            let request = match command_to_request(command).await {
                Ok(request) => request,
                Err(error) => fail(error, 1),
            };
            match call_daemon(&socket, &request).await {
                Ok(response) => {
                    let success = response.ok;
                    emit(&response);
                    if success {
                        0
                    } else {
                        1
                    }
                }
                Err(error) => {
                    emit(&RpcResponse::failure(error));
                    1
                }
            }
        }
    };
    std::process::exit(exit_code);
}

fn fail(error: ApiError, code: i32) -> ! {
    emit(&RpcResponse::failure(error));
    std::process::exit(code);
}

async fn command_to_request(command: Command) -> Result<RpcRequest, ApiError> {
    Ok(match command {
        Command::Snapshot => RpcRequest::Snapshot {},
        Command::Refresh => RpcRequest::Refresh {},
        Command::SendFiles {
            device,
            paths,
            pin_file,
        } => RpcRequest::SendFiles {
            device,
            paths: absolute_paths(paths)?,
            pin: read_optional_pin(pin_file)?,
        },
        Command::SendClipboard {
            device,
            expect_sha256,
            pin_file,
        } => {
            // Read first, so the PIN file is gone even if the clipboard fails.
            let pin = read_optional_pin(pin_file)?;
            let text = clipboard::read().await?;
            clipboard::ensure_unchanged(&text, &expect_sha256)?;
            RpcRequest::SendText { device, text, pin }
        }
        Command::AddDevice { address } => {
            let (host, port) = device_address(&address)
                .map_err(|error| ApiError::new("invalid_arguments", error))?;
            RpcRequest::AddDevice { host, port }
        }
        Command::Accept { request } => RpcRequest::Accept { request },
        Command::Decline { request } => RpcRequest::Decline { request },
        Command::Cancel { transfer } => RpcRequest::Cancel { transfer },
        Command::SetVisibility { mode, favorites } => RpcRequest::SetVisibility {
            visibility: mode,
            favorites,
        },
        Command::Shutdown => RpcRequest::Shutdown {},
        Command::Daemon { .. } | Command::ReadClipboard { .. } | Command::Send { .. } => {
            return Err(ApiError::new(
                "invalid_arguments",
                "This command is not sent to the daemon",
            ));
        }
    })
}

/// Most PINs are a few digits; anything larger is not a PIN file.
const MAX_PIN_FILE_BYTES: u64 = 1024;

/// Reads a PIN from a file and deletes the file, also when the PIN is
/// invalid, so a PIN never lingers on disk or appears in a command line.
fn read_pin_file(path: &Path) -> Result<Pin, ApiError> {
    let read = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .and_then(|file| {
            let mut text = String::new();
            file.take(MAX_PIN_FILE_BYTES).read_to_string(&mut text)?;
            Ok(text)
        });
    let _ = std::fs::remove_file(path);
    let text = read.map_err(|_| ApiError::new("invalid_pin", "Could not read the PIN file"))?;
    Pin::try_from(text)
}

fn read_optional_pin(path: Option<PathBuf>) -> Result<Option<Pin>, ApiError> {
    path.as_deref().map(read_pin_file).transpose()
}

/// `HOST:PORT`, or a bare host or IP address on the default LocalSend port.
fn device_address(address: &str) -> Result<(String, u16), String> {
    let address = address.trim();
    if address.parse::<std::net::IpAddr>().is_ok() || !address.contains(':') {
        return rpc::parse_address(&format!("{address}:{DEFAULT_LOCALSEND_PORT}"));
    }
    rpc::parse_address(address)
}

fn absolute_paths(paths: Vec<PathBuf>) -> Result<Vec<String>, ApiError> {
    let current = std::env::current_dir()
        .map_err(|_| ApiError::new("invalid_path", "Could not determine the current directory"))?;
    paths
        .into_iter()
        .map(|path| {
            let path = if path.is_absolute() {
                path
            } else {
                current.join(path)
            };
            path.into_os_string()
                .into_string()
                .map_err(|_| ApiError::new("invalid_path", "Selected path is not valid UTF-8"))
        })
        .collect()
}

async fn call_daemon(socket: &PathBuf, request: &RpcRequest) -> Result<RpcResponse, ApiError> {
    let mut stream = tokio::time::timeout(Duration::from_secs(3), UnixStream::connect(socket))
        .await
        .map_err(|_| ApiError::new("daemon_unavailable", "Controller connection timed out"))?
        .map_err(|_| {
            ApiError::new(
                "daemon_unavailable",
                format!("Could not connect to {}", socket.display()),
            )
        })?;
    let expected_uid = unsafe { libc::geteuid() };
    let daemon_uid = stream
        .peer_cred()
        .map_err(|_| ApiError::new("daemon_unavailable", "Could not verify controller identity"))?
        .uid();
    if daemon_uid != expected_uid {
        return Err(ApiError::new(
            "daemon_unavailable",
            "Controller socket belongs to another user",
        ));
    }
    let mut request_bytes = serde_json::to_vec(request)
        .map_err(|_| ApiError::new("serialization_error", "Could not serialize request"))?;
    if request_bytes.len() as u64 > MAX_RPC_BYTES {
        return Err(ApiError::new(
            "request_too_large",
            "Request exceeds the management API limit",
        ));
    }
    request_bytes.push(b'\n');
    tokio::time::timeout(RPC_TIMEOUT, async move {
        stream
            .write_all(&request_bytes)
            .await
            .map_err(|_| ApiError::new("daemon_unavailable", "Could not write to daemon"))?;
        stream
            .shutdown()
            .await
            .map_err(|_| ApiError::new("daemon_unavailable", "Could not finish daemon request"))?;

        let mut reader = BufReader::new(stream.take(MAX_RPC_BYTES + 1));
        let mut line = String::new();
        let read = reader
            .read_line(&mut line)
            .await
            .map_err(|_| ApiError::new("protocol_error", "Could not read daemon response"))?;
        if read == 0 {
            return Err(ApiError::new(
                "protocol_error",
                "Daemon closed the socket without a response",
            ));
        }
        if read as u64 > MAX_RPC_BYTES || !line.ends_with('\n') {
            return Err(ApiError::new(
                "protocol_error",
                "Daemon response is invalid or too large",
            ));
        }
        serde_json::from_str(line.trim_end_matches(['\r', '\n']))
            .map_err(|_| ApiError::new("protocol_error", "Daemon returned invalid JSON"))
    })
    .await
    .map_err(|_| ApiError::new("daemon_timeout", "Controller request timed out"))?
}

fn emit(response: &RpcResponse) {
    let mut stdout = std::io::stdout().lock();
    if serde_json::to_writer(&mut stdout, response).is_err() {
        let _ = stdout.write_all(
            br#"{"ok":false,"error":{"code":"serialization_error","message":"Could not serialize output"}}"#,
        );
    }
    let _ = stdout.write_all(b"\n");
    let _ = stdout.flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pin_files_are_deleted_once_read() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pin");
        std::fs::write(&path, "4321\n").unwrap();
        assert_eq!(read_pin_file(&path).unwrap().as_str(), "4321");
        assert!(!path.exists());

        std::fs::write(&path, "").unwrap();
        assert!(read_pin_file(&path).is_err());
        assert!(!path.exists());
        assert!(read_pin_file(&path).is_err());
    }

    #[test]
    fn device_addresses_default_to_the_localsend_port() {
        assert_eq!(
            device_address("10.0.0.2").unwrap(),
            ("10.0.0.2".into(), 53317)
        );
        assert_eq!(
            device_address("phone.lan").unwrap(),
            ("phone.lan".into(), 53317)
        );
        assert_eq!(
            device_address("fe80::1").unwrap(),
            ("fe80::1".into(), 53317)
        );
        assert_eq!(device_address("10.0.0.2:1234").unwrap().1, 1234);
        assert!(device_address("10.0.0.2:x").is_err());
    }
}
