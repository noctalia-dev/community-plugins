//! The management socket: one JSON request and one JSON response per
//! connection, from processes of the same user only.

use crate::rpc::{current_uid, ApiError, RpcRequest, RpcResponse, MAX_RPC_BYTES};
use anyhow::{Context, Result};
use std::fs;
use std::io::ErrorKind;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{mpsc, oneshot, Semaphore};
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

const MAX_MANAGEMENT_CONNECTIONS: usize = 32;
const MANAGEMENT_READ_TIMEOUT: Duration = Duration::from_secs(10);

pub(super) struct RpcCall {
    pub request: RpcRequest,
    pub reply: oneshot::Sender<RpcResponse>,
}

/// Removes the socket on drop, unless another daemon has replaced it.
pub(super) struct SocketGuard {
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl Drop for SocketGuard {
    fn drop(&mut self) {
        let Ok(metadata) = fs::symlink_metadata(&self.path) else {
            return;
        };
        if metadata.file_type().is_socket()
            && metadata.dev() == self.device
            && metadata.ino() == self.inode
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

pub(super) fn bind_management_socket(path: &Path) -> Result<(UnixListener, SocketGuard)> {
    let parent = path
        .parent()
        .context("Socket path has no parent directory")?;
    let parent_metadata =
        fs::symlink_metadata(parent).context("Could not inspect management socket directory")?;
    anyhow::ensure!(
        parent_metadata.is_dir() && !parent_metadata.file_type().is_symlink(),
        "Socket parent directory is invalid"
    );
    let current_uid = current_uid();
    anyhow::ensure!(
        parent_metadata.uid() == current_uid && parent_metadata.mode() & 0o022 == 0,
        "Socket parent directory must be private to the current user"
    );
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            anyhow::ensure!(
                metadata.file_type().is_socket(),
                "Refusing to replace a non-socket management path"
            );
            match std::os::unix::net::UnixStream::connect(path) {
                Ok(_) => anyhow::bail!("A LocalSend controller daemon is already running"),
                Err(error) if error.kind() == ErrorKind::ConnectionRefused => {
                    let current = fs::symlink_metadata(path)?;
                    anyhow::ensure!(
                        current.file_type().is_socket()
                            && current.dev() == metadata.dev()
                            && current.ino() == metadata.ino(),
                        "Management socket changed while checking whether it was stale"
                    );
                    fs::remove_file(path).context("Could not remove stale management socket")?;
                }
                Err(error) => {
                    return Err(error).context("Could not verify existing management socket");
                }
            }
        }
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => return Err(error).context("Could not inspect management socket"),
    }

    let listener = UnixListener::bind(path).context("Could not bind management socket")?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .context("Could not secure management socket")?;
    let metadata = fs::symlink_metadata(path)?;
    Ok((
        listener,
        SocketGuard {
            path: path.to_path_buf(),
            device: metadata.dev(),
            inode: metadata.ino(),
        },
    ))
}

pub(super) async fn serve_management(
    listener: UnixListener,
    rpc_tx: mpsc::Sender<RpcCall>,
    cancel: CancellationToken,
) {
    let connections = TaskTracker::new();
    let permits = Arc::new(Semaphore::new(MAX_MANAGEMENT_CONNECTIONS));
    loop {
        tokio::select! {
            _ = cancel.cancelled() => break,
            accepted = listener.accept() => match accepted {
                Ok((stream, _)) => {
                    let Ok(permit) = permits.clone().try_acquire_owned() else {
                        continue;
                    };
                    let rpc_tx = rpc_tx.clone();
                    connections.spawn(async move {
                        let _permit = permit;
                        handle_connection(stream, rpc_tx).await;
                    });
                }
                Err(_) => {
                    tokio::select! {
                        _ = cancel.cancelled() => break,
                        _ = tokio::time::sleep(Duration::from_millis(100)) => {}
                    }
                },
            }
        }
    }
    connections.close();
    connections.wait().await;
}

async fn handle_connection(stream: UnixStream, rpc_tx: mpsc::Sender<RpcCall>) {
    let current_uid = current_uid();
    if stream
        .peer_cred()
        .ok()
        .is_none_or(|credentials| credentials.uid() != current_uid)
    {
        return;
    }

    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half.take(MAX_RPC_BYTES + 1));
    let mut line = String::new();
    let response =
        match tokio::time::timeout(MANAGEMENT_READ_TIMEOUT, reader.read_line(&mut line)).await {
            Err(_) => RpcResponse::failure(ApiError::new(
                "request_timeout",
                "Management request timed out",
            )),
            Ok(Ok(0)) => RpcResponse::failure(ApiError::new("empty_request", "Request was empty")),
            Ok(Ok(read)) if read as u64 > MAX_RPC_BYTES => RpcResponse::failure(ApiError::new(
                "request_too_large",
                "Request exceeds the management API limit",
            )),
            Ok(Ok(_)) if !line.ends_with('\n') => RpcResponse::failure(ApiError::new(
                "invalid_request",
                "Request must end with a newline",
            )),
            Ok(Ok(_)) => {
                match serde_json::from_str::<RpcRequest>(line.trim_end_matches(['\r', '\n'])) {
                    Ok(request) => {
                        let (reply, response) = oneshot::channel();
                        if rpc_tx.send(RpcCall { request, reply }).await.is_err() {
                            RpcResponse::failure(ApiError::new(
                                "daemon_stopping",
                                "Controller daemon is stopping",
                            ))
                        } else {
                            match tokio::time::timeout(Duration::from_secs(30), response).await {
                                Ok(Ok(response)) => response,
                                Ok(Err(_)) => RpcResponse::failure(ApiError::new(
                                    "daemon_stopping",
                                    "Controller daemon stopped before replying",
                                )),
                                Err(_) => RpcResponse::failure(ApiError::new(
                                    "request_timeout",
                                    "Controller did not reply in time",
                                )),
                            }
                        }
                    }
                    Err(error) => RpcResponse::failure(ApiError::new(
                        "invalid_request",
                        format!("Invalid RPC request: {error}"),
                    )),
                }
            }
            Ok(Err(_)) => RpcResponse::failure(ApiError::new(
                "invalid_request",
                "Request is not valid UTF-8 JSON",
            )),
        };
    let _ = tokio::time::timeout(
        Duration::from_secs(5),
        write_response(&mut write_half, &response),
    )
    .await;
}

async fn write_response(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    response: &RpcResponse,
) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec(response).unwrap_or_else(|_| {
        br#"{"ok":false,"error":{"code":"serialization_error","message":"Could not serialize response"}}"#.to_vec()
    });
    if bytes.len() as u64 > MAX_RPC_BYTES {
        bytes = br#"{"ok":false,"error":{"code":"response_too_large","message":"Controller response exceeds the management API limit"}}"#.to_vec();
    }
    bytes.push(b'\n');
    writer.write_all(&bytes).await?;
    writer.shutdown().await
}
