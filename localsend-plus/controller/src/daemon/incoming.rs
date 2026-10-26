//! Receiving: a sender's request from the offer to the last file, and the
//! limits on who may send and for how long.

use super::devices::{device_type_name, protocol_name};
use super::offer::{
    embedded_message, message_preview, sanitize_message, stale_request, validate_current_request,
    validate_incoming_offer, validate_sender_info,
};
use super::{
    now, sync_record_progress, Controller, IncomingActive, IncomingEnd, InternalEvent,
    PendingIncoming, SenderTarget,
};
use crate::clipboard;
use crate::files::{
    remove_empty_directories, remove_reservations, replace_invisible, reserve_unique_destination,
};
use crate::identity::Identity;
use crate::rpc::{
    AddressSnapshot, ApiError, ApiResult, IncomingRequestSnapshot, OfferedFileSnapshot,
    PeerSnapshot, TransferDirection, TransferFileSnapshot, TransferFileState, TransferSnapshot,
    TransferState,
};
use localsend::http::client::LsHttpClientV2;
use localsend::http::dto_v2::RegisterDtoV2;
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::PrepareUploadDecisionV2;
use localsend::model::discovery::ProtocolType;
use localsend::model::transfer::FileDto;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};

/// A request nobody answered is declined after this long, so a peer cannot
/// hold the single session slot indefinitely.
const PENDING_TIMEOUT: Duration = Duration::from_secs(5 * 60);
/// An accepted transfer that has not received a byte for this long is
/// cancelled: LocalSend sessions never expire on their own, and a sender
/// that went away would otherwise keep the slot until a restart.
const INCOMING_IDLE_TIMEOUT: Duration = Duration::from_secs(2 * 60);
/// After a declined, withdrawn or expired request, further requests from the
/// same sender are declined silently for this long.
const DECLINE_COOLDOWN: Duration = Duration::from_secs(60);
/// Free space kept beyond the incoming bytes before a transfer is accepted.
const SPACE_RESERVE_BYTES: u64 = 64 * 1024 * 1024;

impl Controller {
    /// A sender's prepare-upload: declined unless this mode takes requests
    /// from it and nothing else is pending, else kept for the user to answer
    /// or accepted at once by the auto-accept mode.
    pub(super) fn receive_offer(
        &mut self,
        session_id: String,
        host: String,
        info: RegisterDtoV2,
        cert_fingerprint: Option<String>,
        files: HashMap<String, FileDto>,
        decision_tx: oneshot::Sender<PrepareUploadDecisionV2>,
    ) {
        let Some(fingerprint) = cert_fingerprint else {
            let _ = decision_tx.send(PrepareUploadDecisionV2::Decline);
            self.set_error(
                "unverified_sender",
                "Rejected an incoming request without a TLS certificate",
            );
            return;
        };
        if self.pending.is_some()
            || self.incoming.is_some()
            || !self.accepts_peer(&fingerprint)
            || self.cooldown.holds(&fingerprint, &host)
        {
            let _ = decision_tx.send(PrepareUploadDecisionV2::Decline);
            return;
        }
        if let Err(error) = validate_sender_info(&info) {
            let _ = decision_tx.send(PrepareUploadDecisionV2::Decline);
            self.set_error(error.code, error.message);
            return;
        }
        let total_bytes = match validate_incoming_offer(&files) {
            Ok(total) => total,
            Err(error) => {
                let _ = decision_tx.send(PrepareUploadDecisionV2::Decline);
                self.set_error(error.code, error.message);
                return;
            }
        };

        self.add_confirmed_device(host.clone(), info.clone(), fingerprint.clone());
        let address = AddressSnapshot {
            host: host.clone(),
            port: info.port,
            protocol: protocol_name(info.protocol).to_string(),
        };
        let sender = PeerSnapshot {
            fingerprint: fingerprint.clone(),
            alias: info.alias.clone(),
            device_type: info.device_type.as_ref().map(device_type_name),
            model: info.device_model.clone(),
            address,
        };
        let mut offered: Vec<OfferedFileSnapshot> = files
            .values()
            .map(|file| OfferedFileSnapshot {
                id: file.id.clone(),
                // Shown as it will be saved, with bidi and zero-width characters replaced.
                name: replace_invisible(&file.file_name),
                size: file.size,
                mime_type: file.file_type.clone(),
            })
            .collect();
        offered.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.id.cmp(&b.id)));
        let (message_preview, message_preview_truncated) = message_preview(&files);
        // Text is never accepted unasked: accepting replaces the clipboard.
        let auto_accept = message_preview.is_none() && self.auto_accepts(&fingerprint);
        self.pending = Some(PendingIncoming {
            snapshot: IncomingRequestSnapshot {
                id: session_id,
                sender,
                files: offered,
                total_bytes,
                message_preview,
                message_preview_truncated,
                received_at: now(),
            },
            received: Instant::now(),
            sender: SenderTarget {
                host,
                port: info.port,
                fingerprint,
            },
            files,
            decision_tx,
        });
        if auto_accept {
            // On failure (no space, say) the request stays for the
            // user to decide, with the reason shown.
            if let Err(error) = self.accept_files_pending(true) {
                self.set_error(error.code, error.message);
            }
        }
    }

    pub(super) fn handle_file_upload(
        &mut self,
        session_id: String,
        file_id: String,
        target_tx: oneshot::Sender<FileUploadTarget>,
    ) {
        let Some(active) = self
            .incoming
            .as_mut()
            .filter(|active| active.record.id == session_id)
        else {
            return;
        };
        if active.in_flight.contains(&file_id) {
            return;
        }
        let Some(file) = active
            .record
            .files
            .iter_mut()
            .find(|file| file.id == file_id)
        else {
            return;
        };
        let Some(path) = file.destination_path.as_ref().map(PathBuf::from) else {
            return;
        };

        let progress = active
            .progress
            .entry(file_id.clone())
            .or_insert_with(|| Arc::new(AtomicU64::new(0)))
            .clone();
        progress.store(0, Ordering::Relaxed);
        file.state = TransferFileState::Transferring;
        file.completed_bytes = 0;
        file.error = None;
        active.in_flight.insert(file_id.clone());
        active.record.updated_at = now();
        active.last_activity = Instant::now();

        let (progress_tx, mut progress_rx) = mpsc::channel::<u64>(16);
        tokio::spawn(async move {
            while let Some(written) = progress_rx.recv().await {
                progress.store(written, Ordering::Relaxed);
            }
        });

        let (result_tx, result_rx) = oneshot::channel::<Result<(), String>>();
        let internal = self.internal_tx.clone();
        tokio::spawn(async move {
            let result = match result_rx.await {
                Ok(result) => result,
                Err(_) => Err("Upload aborted".to_string()),
            };
            let _ = internal
                .send(InternalEvent::IncomingFileResult {
                    transfer_id: session_id,
                    file_id,
                    result,
                })
                .await;
        });

        let _ = target_tx.send(FileUploadTarget::Path {
            path,
            result_tx,
            progress_tx: Some(progress_tx),
        });
    }

    pub(super) fn handle_incoming_file_result(
        &mut self,
        transfer_id: &str,
        file_id: &str,
        result: Result<(), String>,
    ) {
        let Some(active) = self
            .incoming
            .as_mut()
            .filter(|active| active.record.id == transfer_id)
        else {
            return;
        };
        active.in_flight.remove(file_id);
        active.last_activity = Instant::now();
        let Some(file) = active
            .record
            .files
            .iter_mut()
            .find(|file| file.id == file_id)
        else {
            return;
        };
        match result {
            Ok(()) => {
                file.state = TransferFileState::Completed;
                file.completed_bytes = file.size;
                file.error = None;
            }
            Err(_) => {
                if let Some(path) = file.destination_path.as_deref() {
                    let _ = fs::remove_file(path);
                }
                file.state = TransferFileState::Failed;
                file.error = Some(ApiError::new(
                    "receive_file_failed",
                    format!("Could not receive {}", file.name),
                ));
            }
        }
        active.record.updated_at = now();
        self.finish_incoming_if_ready();
    }

    pub(super) fn finish_incoming_if_ready(&mut self) {
        let ready = self
            .incoming
            .as_ref()
            .is_some_and(|active| active.end.is_some() && active.in_flight.is_empty());
        if !ready {
            return;
        }
        let active = self.incoming.take().expect("incoming was checked");
        self.finish_incoming(active);
    }

    /// Moves an ended incoming transfer to the recent list, removing the
    /// files that did not arrive and the folders left empty.
    pub(super) fn finish_incoming(&mut self, mut active: IncomingActive) {
        sync_record_progress(&mut active.record, &active.progress);
        match active.end.unwrap_or(IncomingEnd::Cancelled) {
            IncomingEnd::Cancelled => {
                // A transfer the daemon gave up on failed; one the user or
                // the sender cancelled did not.
                active.record.state = if active.record.error.is_some() {
                    TransferState::Failed
                } else {
                    TransferState::Cancelled
                };
                for file in &mut active.record.files {
                    if matches!(
                        file.state,
                        TransferFileState::Queued | TransferFileState::Transferring
                    ) {
                        if let Some(path) = file.destination_path.as_deref() {
                            let _ = fs::remove_file(path);
                        }
                        file.state = TransferFileState::Cancelled;
                    }
                }
            }
            IncomingEnd::Finished => {
                if active
                    .record
                    .files
                    .iter()
                    .any(|file| file.state == TransferFileState::Failed)
                {
                    active.record.state = TransferState::Failed;
                    active.record.error = Some(ApiError::new(
                        "receive_failed",
                        "One or more files could not be received",
                    ));
                } else {
                    active.record.state = TransferState::Completed;
                }
            }
        }
        remove_empty_directories(&active.created_dirs);
        active.record.completed_bytes = active
            .record
            .files
            .iter()
            .map(|file| file.completed_bytes)
            .sum();
        let at = now();
        active.record.updated_at = at.clone();
        active.record.finished_at = Some(at);
        self.push_recent(active.record);
    }

    pub(super) async fn accept_pending(&mut self, request_id: &str) -> ApiResult<TransferSnapshot> {
        validate_current_request(
            self.pending
                .as_ref()
                .map(|pending| pending.snapshot.id.as_str()),
            request_id,
        )?;
        if self.incoming.is_some() {
            return Err(ApiError::new(
                "incoming_busy",
                "An incoming transfer is already active",
            ));
        }
        let embedded_text = self
            .pending
            .as_ref()
            .and_then(|pending| embedded_message(&pending.files))
            .map(str::to_string);
        if let Some(text) = embedded_text {
            clipboard::copy(&sanitize_message(&text)).await?;
            let pending = self.pending.take().expect("pending was validated");
            let mut record = transfer_from_pending(&pending, TransferState::Completed);
            pending
                .decision_tx
                .send(PrepareUploadDecisionV2::Accept(HashSet::new()))
                .map_err(|_| stale_request())?;
            record.completed_bytes = record.total_bytes;
            for file in &mut record.files {
                file.state = TransferFileState::Completed;
                file.completed_bytes = file.size;
            }
            let at = now();
            record.started_at = Some(at.clone());
            record.updated_at = at.clone();
            record.finished_at = Some(at);
            self.push_recent(record.clone());
            return Ok(record);
        }

        self.accept_files_pending(false)
    }

    /// Accepts the pending file request while no incoming transfer runs:
    /// checks the free space, reserves every destination path and starts
    /// receiving.
    pub(super) fn accept_files_pending(
        &mut self,
        auto_accepted: bool,
    ) -> ApiResult<TransferSnapshot> {
        let needed = self
            .pending
            .as_ref()
            .map_or(0, |pending| pending.snapshot.total_bytes);
        ensure_free_space(&self.destination, needed)?;

        let mut offered: Vec<(String, String)> = self
            .pending
            .as_ref()
            .expect("pending was validated")
            .files
            .iter()
            .map(|(id, file)| (id.clone(), file.file_name.clone()))
            .collect();
        offered.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
        let mut paths = HashMap::new();
        let mut created_dirs = Vec::new();
        for (id, name) in offered {
            match reserve_unique_destination(&self.destination, &name, &mut created_dirs) {
                Ok(path) => {
                    paths.insert(id, path);
                }
                Err(error) => {
                    remove_reservations(paths.into_values(), &created_dirs);
                    return Err(error);
                }
            }
        }

        let pending = self.pending.take().expect("pending was validated");
        let accepted: HashSet<String> = pending.files.keys().cloned().collect();
        let mut record = transfer_from_pending(&pending, TransferState::Transferring);
        if pending
            .decision_tx
            .send(PrepareUploadDecisionV2::Accept(accepted))
            .is_err()
        {
            remove_reservations(paths.into_values(), &created_dirs);
            return Err(stale_request());
        }

        let at = now();
        record.started_at = Some(at.clone());
        record.updated_at = at;
        record.auto_accepted = auto_accepted;
        for file in &mut record.files {
            file.destination_path = paths
                .get(&file.id)
                .and_then(|path| path.to_str())
                .map(str::to_string);
        }
        self.incoming = Some(IncomingActive {
            record: record.clone(),
            sender: pending.sender,
            progress: HashMap::new(),
            in_flight: HashSet::new(),
            end: None,
            created_dirs,
            last_activity: Instant::now(),
            last_bytes: 0,
        });
        Ok(record)
    }

    pub(super) fn decline_pending(&mut self, request_id: &str) -> ApiResult<TransferSnapshot> {
        validate_current_request(
            self.pending
                .as_ref()
                .map(|pending| pending.snapshot.id.as_str()),
            request_id,
        )?;
        let pending = self.pending.take().expect("pending was validated");
        self.cooldown.start(&pending.sender);
        let mut record = transfer_from_pending(&pending, TransferState::Declined);
        pending
            .decision_tx
            .send(PrepareUploadDecisionV2::Decline)
            .map_err(|_| stale_request())?;
        let finished = now();
        record.updated_at = finished.clone();
        record.finished_at = Some(finished);
        self.push_recent(record.clone());
        Ok(record)
    }

    /// Ends the incoming transfer at once: the session is dropped, the
    /// sender told, and files still being written are removed (an upload
    /// that is still running writes to a deleted file). Waiting for those
    /// uploads could take forever when the sender has gone away.
    pub(super) async fn cancel_incoming(&mut self, error: Option<ApiError>) -> TransferSnapshot {
        let mut active = self.incoming.take().expect("incoming was checked");
        if let Some(server) = &self.server {
            server.handle.cancel_v2_session(&active.record.id).await;
        }
        spawn_cancel_notification(
            self.identity.clone(),
            active.sender.clone(),
            active.record.id.clone(),
        );
        active.end = Some(IncomingEnd::Cancelled);
        active.record.error = error;
        let id = active.record.id.clone();
        self.finish_incoming(active);
        self.recent
            .iter()
            .find(|record| record.id == id)
            .cloned()
            .expect("finish_incoming keeps the record")
    }

    /// Cancels an accepted transfer that has not received a byte for
    /// [`INCOMING_IDLE_TIMEOUT`].
    pub(super) async fn expire_incoming(&mut self) {
        let Some(active) = self.incoming.as_mut() else {
            return;
        };
        let bytes: u64 = active
            .progress
            .values()
            .map(|counter| counter.load(Ordering::Relaxed))
            .sum();
        if bytes != active.last_bytes {
            active.last_bytes = bytes;
            active.last_activity = Instant::now();
            return;
        }
        if active.last_activity.elapsed() >= INCOMING_IDLE_TIMEOUT {
            self.cancel_incoming(Some(ApiError::new(
                "receive_stalled",
                "The sender stopped sending",
            )))
            .await;
        }
    }

    /// Declines a request left unanswered for too long and forgets expired
    /// cooldowns.
    pub(super) fn expire_pending(&mut self) {
        let now = Instant::now();
        self.cooldown.expire(now);
        let expired = self
            .pending
            .as_ref()
            .filter(|pending| now.duration_since(pending.received) >= PENDING_TIMEOUT)
            .map(|pending| pending.snapshot.id.clone());
        if let Some(id) = expired {
            let _ = self.decline_pending(&id);
        }
    }
}

/// Senders whose requests are declined silently for a while, by certificate
/// fingerprint and by address, so a fresh certificate alone does not get a
/// declined sender past it.
#[derive(Default)]
pub(super) struct Cooldown {
    /// Uppercase fingerprints.
    fingerprints: HashMap<String, Instant>,
    hosts: HashMap<String, Instant>,
}

impl Cooldown {
    pub(super) fn start(&mut self, sender: &SenderTarget) {
        let until = Instant::now() + DECLINE_COOLDOWN;
        self.fingerprints
            .insert(sender.fingerprint.to_ascii_uppercase(), until);
        self.hosts.insert(sender.host.clone(), until);
    }

    pub(super) fn holds(&self, fingerprint: &str, host: &str) -> bool {
        let now = Instant::now();
        let active = |map: &HashMap<String, Instant>, key: &str| {
            map.get(key).is_some_and(|until| now < *until)
        };
        active(&self.fingerprints, &fingerprint.to_ascii_uppercase()) || active(&self.hosts, host)
    }

    pub(super) fn expire(&mut self, now: Instant) {
        self.fingerprints.retain(|_, until| now < *until);
        self.hosts.retain(|_, until| now < *until);
    }
}

pub(super) fn transfer_from_pending(
    pending: &PendingIncoming,
    state: TransferState,
) -> TransferSnapshot {
    let created = pending.snapshot.received_at.clone();
    let file_state = match state {
        TransferState::Declined => TransferFileState::Declined,
        TransferState::Cancelled => TransferFileState::Cancelled,
        TransferState::Completed => TransferFileState::Completed,
        _ => TransferFileState::Queued,
    };
    TransferSnapshot {
        id: pending.snapshot.id.clone(),
        direction: TransferDirection::Incoming,
        state,
        peer: pending.snapshot.sender.clone(),
        file_count: pending.snapshot.files.len(),
        files: pending
            .snapshot
            .files
            .iter()
            .map(|file| TransferFileSnapshot {
                id: file.id.clone(),
                name: file.name.clone(),
                size: file.size,
                mime_type: file.mime_type.clone(),
                state: file_state,
                completed_bytes: if file_state == TransferFileState::Completed {
                    file.size
                } else {
                    0
                },
                source_path: None,
                destination_path: None,
                error: None,
            })
            .collect(),
        total_bytes: pending.snapshot.total_bytes,
        completed_bytes: 0,
        created_at: created.clone(),
        started_at: None,
        updated_at: created,
        finished_at: None,
        error: None,
        auto_accepted: false,
        text_message: pending.snapshot.message_preview.is_some(),
    }
}

/// Refuses an incoming transfer that would not fit, keeping a reserve free.
pub(super) fn ensure_free_space(destination: &Path, needed: u64) -> ApiResult<()> {
    let path = std::ffi::CString::new(destination.as_os_str().as_encoded_bytes())
        .map_err(|_| ApiError::new("destination_error", "Destination path is invalid"))?;
    // SAFETY: statvfs is a plain C struct, valid when all zeroes.
    let mut stats: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `path` is a NUL-terminated string that outlives the call, and
    // `stats` is a writable statvfs.
    if unsafe { libc::statvfs(path.as_ptr(), &mut stats) } != 0 {
        // Unknown free space does not block the transfer; writing fails
        // cleanly if the disk fills up.
        return Ok(());
    }
    let available = (stats.f_bavail as u64).saturating_mul(stats.f_frsize as u64);
    if available < needed.saturating_add(SPACE_RESERVE_BYTES) {
        return Err(ApiError::new(
            "insufficient_space",
            format!(
                "Not enough free space: {} MiB needed, {} MiB available",
                needed.div_ceil(1024 * 1024),
                available / (1024 * 1024)
            ),
        ));
    }
    Ok(())
}

pub(super) fn spawn_cancel_notification(
    identity: Arc<Identity>,
    sender: SenderTarget,
    session_id: String,
) {
    tokio::spawn(async move {
        let Ok(client) = LsHttpClientV2::try_new(
            &identity.key_pem,
            &identity.cert_pem,
            Some(sender.fingerprint),
            Some(Duration::from_secs(5)),
        ) else {
            return;
        };
        let _ = client
            .cancel(ProtocolType::Https, &sender.host, sender.port, &session_id)
            .await;
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cooldown_covers_the_certificate_and_the_address() {
        let mut cooldown = Cooldown::default();
        cooldown.start(&SenderTarget {
            host: "10.0.0.7".to_string(),
            port: 53317,
            fingerprint: "ab12".to_string(),
        });
        assert!(cooldown.holds("AB12", "10.0.0.8"));
        assert!(cooldown.holds("CD34", "10.0.0.7"));
        assert!(!cooldown.holds("CD34", "10.0.0.8"));

        cooldown.expire(Instant::now() + DECLINE_COOLDOWN);
        assert!(!cooldown.holds("AB12", "10.0.0.7"));
    }

    #[test]
    fn free_space_check_refuses_impossible_transfers() {
        let temp = std::env::temp_dir();
        assert!(ensure_free_space(&temp, 0).is_ok());
        assert_eq!(
            ensure_free_space(&temp, u64::MAX / 2).unwrap_err().code,
            "insufficient_space"
        );
    }
}
