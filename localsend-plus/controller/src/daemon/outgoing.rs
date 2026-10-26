//! Sending: one outgoing transfer from prepare-upload to the last file.

use super::offer::embedded_message;
use super::InternalEvent;
use crate::files::{OutgoingItem, OutgoingSource};
use crate::identity::Identity;
use crate::rpc::{ApiError, ApiResult, Pin, TransferState};
use bytes::Bytes;
use futures_util::StreamExt;
use localsend::discovery::{HttpChannel, StatefulDevice};
use localsend::http::client::{ClientError, LsHttpClientV2};
use localsend::http::dto_v2::PrepareUploadRequestDtoV2;
use localsend::model::discovery::ProtocolType;
use localsend::model::transfer::FileDto;
use localsend::reqwest;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tokio_util::sync::CancellationToken;

/// Waiting for the receiver to take note of a cancel is not worth more.
const CANCEL_TIMEOUT: Duration = Duration::from_secs(2);

/// Everything one send needs; the daemon keeps clones of `progress`,
/// `cancel` and `by_peer` to follow and stop it.
pub(super) struct OutgoingJob {
    pub transfer_id: String,
    pub identity: Arc<Identity>,
    pub device: StatefulDevice,
    pub channel: HttpChannel,
    pub items: Vec<OutgoingItem>,
    pub pin: Option<Pin>,
    pub progress: HashMap<String, Arc<AtomicU64>>,
    pub cancel: CancellationToken,
    /// Set when the receiver cancelled, so it is not told again.
    pub by_peer: Arc<AtomicBool>,
    pub internal: mpsc::Sender<InternalEvent>,
}

/// The receiver's upload session.
struct Session<'a> {
    client: &'a LsHttpClientV2,
    channel: &'a HttpChannel,
    id: &'a str,
}

impl Session<'_> {
    async fn upload(
        &self,
        file_id: &str,
        token: &str,
        body: reqwest::Body,
        cancel: CancellationToken,
    ) -> Result<(), ClientError> {
        let channel = self.channel;
        self.client
            .upload(
                channel.protocol,
                &channel.host,
                channel.port,
                None,
                self.id,
                file_id,
                token,
                body,
                cancel,
            )
            .await
    }

    /// Tells the receiver the transfer is over.
    async fn cancel(&self) {
        let channel = self.channel;
        let _ = tokio::time::timeout(
            CANCEL_TIMEOUT,
            self.client
                .cancel(channel.protocol, &channel.host, channel.port, self.id),
        )
        .await;
    }
}

enum UploadError {
    Cancelled,
    Failed(ApiError),
}

pub(super) async fn run_outgoing(job: OutgoingJob) {
    let OutgoingJob {
        transfer_id,
        identity,
        device,
        channel,
        items,
        pin,
        progress,
        cancel,
        by_peer,
        internal,
    } = job;
    let expected_fingerprint = match channel.protocol {
        ProtocolType::Https => Some(device.device.fingerprint.clone()),
        ProtocolType::Http => None,
    };
    let Ok(client) = LsHttpClientV2::try_new(
        &identity.key_pem,
        &identity.cert_pem,
        expected_fingerprint,
        None,
    ) else {
        let error = ApiError::new(
            "tls_client_error",
            "Could not initialize the LocalSend TLS client",
        );
        send_outgoing_finished(&internal, transfer_id, TransferState::Failed, Some(error)).await;
        return;
    };

    let files: HashMap<String, FileDto> = items
        .iter()
        .map(|item| (item.file.id.clone(), item.file.clone()))
        .collect();
    let embedded_text = embedded_message(&files).is_some();
    let sources: HashMap<String, OutgoingSource> = items
        .into_iter()
        .map(|item| (item.file.id, item.source))
        .collect();
    let prepared = client
        .prepare_upload(
            channel.protocol,
            &channel.host,
            channel.port,
            None,
            PrepareUploadRequestDtoV2 {
                info: identity.register_dto(),
                files: files.clone(),
            },
            pin.as_ref().map(Pin::as_str),
            cancel.clone(),
        )
        .await;

    let prepared = match prepared {
        Ok(prepared) => prepared,
        Err(ClientError::Cancelled) => {
            send_outgoing_finished(&internal, transfer_id, TransferState::Cancelled, None).await;
            return;
        }
        Err(ClientError::StatusCode(error)) if error.status == 403 => {
            send_outgoing_finished(&internal, transfer_id, TransferState::Declined, None).await;
            return;
        }
        Err(error) => {
            let error = prepare_error(&error, pin.is_some());
            send_outgoing_finished(&internal, transfer_id, TransferState::Failed, Some(error))
                .await;
            return;
        }
    };

    // An embedded text message travels in the request itself, so there is
    // nothing to upload once the receiver has taken it.
    let Some(response) = prepared.response else {
        let state = if embedded_text {
            for (id, file) in &files {
                if let Some(progress) = progress.get(id) {
                    progress.store(file.size, Ordering::Relaxed);
                }
            }
            TransferState::Completed
        } else {
            TransferState::Declined
        };
        send_outgoing_finished(&internal, transfer_id, state, None).await;
        return;
    };

    let accepted: HashSet<String> = response
        .files
        .keys()
        .filter(|id| files.contains_key(*id))
        .cloned()
        .collect();
    if accepted.is_empty() {
        send_outgoing_finished(&internal, transfer_id, TransferState::Declined, None).await;
        return;
    }
    let _ = internal
        .send(InternalEvent::OutgoingPrepared {
            transfer_id: transfer_id.clone(),
            session_id: response.session_id.clone(),
            accepted: accepted.clone(),
        })
        .await;

    let session = Session {
        client: &client,
        channel: &channel,
        id: &response.session_id,
    };
    let mut ids: Vec<String> = accepted.into_iter().collect();
    ids.sort_by(|a, b| files[a].file_name.cmp(&files[b].file_name));
    for file_id in ids {
        if cancel.is_cancelled() {
            finish_cancelled(&session, &by_peer, &internal, transfer_id).await;
            return;
        }
        let _ = internal
            .send(InternalEvent::OutgoingFileStarted {
                transfer_id: transfer_id.clone(),
                file_id: file_id.clone(),
            })
            .await;

        let file_progress = progress
            .get(&file_id)
            .cloned()
            .unwrap_or_else(|| Arc::new(AtomicU64::new(0)));
        let result = match upload_body(sources[&file_id].clone(), move |written| {
            file_progress.store(written, Ordering::Relaxed)
        }) {
            Ok(body) => session
                .upload(&file_id, &response.files[&file_id], body, cancel.clone())
                .await
                .map_err(|error| match error {
                    ClientError::Cancelled => UploadError::Cancelled,
                    _ => UploadError::Failed(ApiError::new(
                        "upload_failed",
                        format!("Could not upload {}", files[&file_id].file_name),
                    )),
                }),
            Err(error) => Err(UploadError::Failed(error)),
        };
        match result {
            Ok(()) => {
                if let Some(file_progress) = progress.get(&file_id) {
                    file_progress.store(files[&file_id].size, Ordering::Relaxed);
                }
                let _ = internal
                    .send(InternalEvent::OutgoingFileCompleted {
                        transfer_id: transfer_id.clone(),
                        file_id,
                    })
                    .await;
            }
            Err(UploadError::Cancelled) => {
                finish_cancelled(&session, &by_peer, &internal, transfer_id).await;
                return;
            }
            Err(UploadError::Failed(error)) => {
                let _ = internal
                    .send(InternalEvent::OutgoingFileFailed {
                        transfer_id: transfer_id.clone(),
                        file_id,
                        error: error.clone(),
                    })
                    .await;
                session.cancel().await;
                send_outgoing_finished(&internal, transfer_id, TransferState::Failed, Some(error))
                    .await;
                return;
            }
        }
    }

    send_outgoing_finished(&internal, transfer_id, TransferState::Completed, None).await;
}

/// Ends a send the user or the receiver cancelled; only the receiver's own
/// cancel needs no notice.
async fn finish_cancelled(
    session: &Session<'_>,
    by_peer: &AtomicBool,
    internal: &mpsc::Sender<InternalEvent>,
    transfer_id: String,
) {
    if !by_peer.load(Ordering::Relaxed) {
        session.cancel().await;
    }
    send_outgoing_finished(internal, transfer_id, TransferState::Cancelled, None).await;
}

async fn send_outgoing_finished(
    internal: &mpsc::Sender<InternalEvent>,
    transfer_id: String,
    state: TransferState,
    error: Option<ApiError>,
) {
    let _ = internal
        .send(InternalEvent::OutgoingFinished {
            transfer_id,
            state,
            error,
        })
        .await;
}

/// The receiver answers 401 both without and with a wrong PIN, and 429 to
/// every request from an address after three wrong PINs, until it restarts.
fn prepare_error(error: &ClientError, pin_sent: bool) -> ApiError {
    match error {
        ClientError::StatusCode(error) => match (error.status, pin_sent) {
            (401, false) => ApiError::new("pin_required", "Receiver requires a PIN"),
            (401, true) => ApiError::new("pin_invalid", "The PIN is not correct"),
            (409, _) => ApiError::new("peer_busy", "Receiver is handling another transfer"),
            (429, true) => ApiError::new(
                "pin_locked",
                "Too many wrong PINs; LocalSend on the receiver has to restart",
            ),
            (429, false) => ApiError::new("rate_limited", "Receiver rejected too many requests"),
            (status, _) => ApiError::new(
                "remote_error",
                format!("Receiver returned HTTP status {status}"),
            ),
        },
        ClientError::Json(_) => ApiError::new(
            "protocol_error",
            "Receiver returned an invalid LocalSend response",
        ),
        ClientError::Cancelled => ApiError::new("cancelled", "Transfer was cancelled"),
        _ => ApiError::new("network_error", "Could not contact the receiver"),
    }
}

fn upload_body(
    source: OutgoingSource,
    progress: impl Fn(u64) + Send + 'static,
) -> ApiResult<reqwest::Body> {
    let receiver = match source {
        OutgoingSource::Path {
            path,
            device,
            inode,
            size,
        } => {
            let file = fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&path)
                .map_err(|_| {
                    ApiError::new(
                        "source_changed",
                        "Selected source file is no longer readable",
                    )
                })?;
            let metadata = file.metadata().map_err(|_| {
                ApiError::new(
                    "source_changed",
                    "Selected source file could not be verified",
                )
            })?;
            if !metadata.is_file()
                || metadata.dev() != device
                || metadata.ino() != inode
                || metadata.len() != size
            {
                return Err(ApiError::new(
                    "source_changed",
                    "Selected source file changed before it could be sent",
                ));
            }
            let (tx, rx) = mpsc::channel(16);
            tokio::spawn(async move {
                let mut file = tokio::fs::File::from_std(file);
                let mut buffer = vec![0u8; 512 * 1024];
                loop {
                    match file.read(&mut buffer).await {
                        Ok(0) => break,
                        Ok(read) => {
                            if tx
                                .send(Ok(Bytes::copy_from_slice(&buffer[..read])))
                                .await
                                .is_err()
                            {
                                break;
                            }
                        }
                        // Fail the body so the request aborts; ending it early
                        // would send a complete but truncated upload.
                        Err(error) => {
                            let _ = tx.send(Err(error)).await;
                            break;
                        }
                    }
                }
            });
            rx
        }
        OutgoingSource::Bytes(bytes) => {
            let (tx, rx) = mpsc::channel(1);
            let _ = tx.try_send(Ok(Bytes::copy_from_slice(bytes.as_slice())));
            rx
        }
    };
    let mut sent = 0u64;
    let stream = ReceiverStream::new(receiver).map(move |chunk: std::io::Result<Bytes>| {
        let chunk = chunk?;
        sent += chunk.len() as u64;
        progress(sent);
        Ok::<Bytes, anyhow::Error>(chunk)
    });
    Ok(reqwest::Body::wrap_stream(stream))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_pin_responses_by_whether_a_pin_was_sent() {
        let status = |status| {
            ClientError::StatusCode(localsend::http::StatusCodeError {
                status,
                message: None,
            })
        };
        let code = |status_code, pin_sent| prepare_error(&status(status_code), pin_sent).code;
        assert_eq!(code(401, false), "pin_required");
        assert_eq!(code(401, true), "pin_invalid");
        assert_eq!(code(429, true), "pin_locked");
        assert_eq!(code(429, false), "rate_limited");
        assert_eq!(code(409, true), "peer_busy");
        assert_eq!(code(500, false), "remote_error");
    }
}
