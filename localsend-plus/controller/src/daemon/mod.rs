//! The long-running daemon: the LocalSend receiver, discovery and the
//! management socket, driven from one event loop.

mod devices;
mod incoming;
mod management;
mod offer;
mod outgoing;

use crate::files::{collect_selection, OutgoingItem, OutgoingSource};
use crate::identity::Identity;
use crate::rpc::{
    ApiError, ApiResult, AutoAccept, ControllerError, DaemonSnapshot, DaemonStatus, DeviceSnapshot,
    FavoriteSpec, IncomingRequestSnapshot, Pin, RpcRequest, RpcResponse, Snapshot,
    TransferDirection, TransferFileSnapshot, TransferFileState, TransferSnapshot, TransferState,
    Visibility, MIN_AUTO_ACCEPT_PIN_CHARS,
};
use anyhow::{Context, Result};
use devices::{device_online, device_snapshot, peer_from_device, probe_favorites, secure_channel};
use incoming::{spawn_cancel_notification, transfer_from_pending, Cooldown};
use localsend::discovery::{
    DeviceChannel, DeviceIdentity, DiscoveredDevice, DiscoveryConfig, DiscoveryEvent,
    DiscoveryHandle, HttpChannel, DEFAULT_DISCOVERY_TIMEOUT,
};
use localsend::http::dto_v2::RegisterDtoV2;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2, SessionEndReasonV2};
use localsend::http::server::web::WebConfig;
use localsend::http::server::{start_with_port, ServerConfigV2, ServerHandle};
use localsend::model::discovery::{ProtocolType, PROTOCOL_VERSION_V2};
use localsend::model::transfer::FileDto;
use localsend::multicast::{DEFAULT_MULTICAST_GROUP, DEFAULT_MULTICAST_GROUP_V6};
use localsend::util::interface::{local_interface_addresses, InterfaceFilter};
use management::{bind_management_socket, serve_management, RpcCall};
use offer::{validate_fingerprint, validate_sender_info, validate_uuid};
use outgoing::OutgoingJob;
use serde_json::json;
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

const MAX_RECENT_TRANSFERS: usize = 8;
const MAX_RECENT_FILES: usize = 32;
const MAX_DEVICES: usize = 128;
const ANNOUNCE_INTERVAL: Duration = Duration::from_secs(30);

pub struct DaemonConfig {
    pub socket: PathBuf,
    pub port: u16,
    pub destination: PathBuf,
    pub alias: Option<String>,
    pub state_directory: PathBuf,
    pub visibility: Visibility,
    pub pin: Option<Pin>,
    pub auto_accept: AutoAccept,
    pub device_model: String,
}

/// The LocalSend receiver while it runs; hidden mode stops it.
struct RunningServer {
    handle: Arc<ServerHandle>,
    stop_tx: oneshot::Sender<()>,
}

impl RunningServer {
    async fn start(
        identity: &Identity,
        pin: Option<&Pin>,
        event_tx: mpsc::Sender<ServerEventV2>,
    ) -> Result<Self> {
        let (stop_tx, stop_rx) = oneshot::channel();
        let handle = start_with_port(
            identity.port,
            Some(identity.tls_config()),
            identity.client_info(),
            None,
            Some(ServerConfigV2 {
                pin: pin.map(|pin| pin.as_str().to_string()),
                verify_checksums: true,
                event_tx,
            }),
            // Web sharing stays disabled, which also keeps mTLS mandatory.
            WebConfig::default(),
            stop_rx,
        )
        .await
        .context("Could not start the LocalSend receiver")?;
        Ok(Self {
            handle: Arc::new(handle),
            stop_tx,
        })
    }

    /// Stops the listeners and waits until the port is free again.
    async fn stop(self) {
        let _ = self.stop_tx.send(());
        let _ = tokio::time::timeout(Duration::from_secs(2), self.handle.wait_stopped()).await;
    }
}

enum InternalEvent {
    SelectionReady {
        device: String,
        pin: Option<Pin>,
        result: ApiResult<Vec<OutgoingItem>>,
        reply: oneshot::Sender<RpcResponse>,
    },
    RefreshFinished {
        id: String,
        result: Result<(), String>,
    },
    OutgoingPrepared {
        transfer_id: String,
        session_id: String,
        accepted: HashSet<String>,
    },
    OutgoingFileStarted {
        transfer_id: String,
        file_id: String,
    },
    OutgoingFileCompleted {
        transfer_id: String,
        file_id: String,
    },
    OutgoingFileFailed {
        transfer_id: String,
        file_id: String,
        error: ApiError,
    },
    OutgoingFinished {
        transfer_id: String,
        state: TransferState,
        error: Option<ApiError>,
    },
    IncomingFileResult {
        transfer_id: String,
        file_id: String,
        result: Result<(), String>,
    },
}

struct PendingIncoming {
    snapshot: IncomingRequestSnapshot,
    received: Instant,
    sender: SenderTarget,
    files: HashMap<String, FileDto>,
    decision_tx: oneshot::Sender<PrepareUploadDecisionV2>,
}

/// Where to tell a sender that its transfer ended. Its request came over
/// mutual TLS, so the reply goes over HTTPS pinned to that certificate,
/// whatever protocol the sender claimed.
#[derive(Clone)]
struct SenderTarget {
    host: String,
    port: u16,
    fingerprint: String,
}

struct IncomingActive {
    record: TransferSnapshot,
    sender: SenderTarget,
    progress: HashMap<String, Arc<AtomicU64>>,
    in_flight: HashSet<String>,
    end: Option<IncomingEnd>,
    /// Directories created for the reserved files, removed again when they
    /// end up empty.
    created_dirs: Vec<PathBuf>,
    /// When a byte last arrived (or the transfer started), and the byte
    /// count then; see [`incoming::INCOMING_IDLE_TIMEOUT`].
    last_activity: Instant,
    last_bytes: u64,
}

#[derive(Clone, Copy)]
enum IncomingEnd {
    Finished,
    Cancelled,
}

struct OutgoingActive {
    record: TransferSnapshot,
    progress: HashMap<String, Arc<AtomicU64>>,
    cancel: CancellationToken,
    by_peer: Arc<AtomicBool>,
    host: String,
    remote_session_id: Option<String>,
    task: tokio::task::JoinHandle<()>,
}

struct Controller {
    identity: Arc<Identity>,
    server: Option<RunningServer>,
    server_tx: mpsc::Sender<ServerEventV2>,
    /// The PIN senders must give; it is fixed while the receiver runs.
    pin: Option<Pin>,
    auto_accept: AutoAccept,
    visibility: Visibility,
    /// Favorite fingerprints (uppercase) with their last known HTTPS address.
    favorites: HashMap<String, Option<HttpChannel>>,
    discovery: Arc<DiscoveryHandle>,
    discovery_tx: mpsc::Sender<DiscoveryEvent>,
    discovery_stop_tx: Option<oneshot::Sender<()>>,
    multicast_down: bool,
    socket: PathBuf,
    destination: PathBuf,
    started_at: String,
    status: DaemonStatus,
    error: Option<ControllerError>,
    pending: Option<PendingIncoming>,
    incoming: Option<IncomingActive>,
    outgoing: Option<OutgoingActive>,
    selecting_outgoing: bool,
    recent: VecDeque<TransferSnapshot>,
    refresh_id: Option<String>,
    early_remote_cancel: Option<(String, String)>,
    /// Senders recently declined, whose requests are declined silently.
    cooldown: Cooldown,
    internal_tx: mpsc::Sender<InternalEvent>,
}

/// The part of the snapshot the plugin needs to hear about at once, even with
/// its panel closed: a request waiting for an answer, transfers starting and
/// ending, and errors. Progress and the device list are left out, since the
/// plugin polls while a transfer runs or its panel is open.
#[derive(PartialEq)]
struct Activity {
    status: DaemonStatus,
    visibility: Visibility,
    receiving: bool,
    pending: Option<String>,
    transfers: Vec<(String, TransferState)>,
    error: Option<(String, String)>,
}

pub async fn run(config: DaemonConfig) -> Result<()> {
    anyhow::ensure!(config.port != 0, "Port 0 is not supported");
    anyhow::ensure!(config.socket.is_absolute(), "Socket path must be absolute");
    anyhow::ensure!(
        config.destination.is_absolute(),
        "Destination path must be absolute"
    );

    // Keep the socket private from the instant it is created; chmod below
    // narrows it further to exactly 0600.
    // SAFETY: umask only swaps the process's file creation mask, and no
    // other thread creates files yet.
    unsafe {
        libc::umask(0o077);
    }

    let (listener, socket_guard) = bind_management_socket(&config.socket)?;
    let destination = prepare_destination(&config.destination)?;
    anyhow::ensure!(
        destination.to_str().is_some(),
        "Destination path must be valid UTF-8"
    );
    let identity = Arc::new(Identity::load_or_generate(
        &config.state_directory,
        config.alias,
        config.device_model,
        config.port,
    )?);

    // One event channel outlives every receiver started and stopped below.
    let (server_tx, mut server_rx) = mpsc::channel::<ServerEventV2>(64);
    let server = if config.visibility == Visibility::Hidden {
        None
    } else {
        Some(RunningServer::start(&identity, config.pin.as_ref(), server_tx.clone()).await?)
    };

    let (discovery_tx, mut discovery_rx) = mpsc::channel::<DiscoveryEvent>(64);
    let (discovery, discovery_stop_tx) = start_discovery(&identity, discovery_tx.clone()).await;
    // Answering an announcement registers with the announcer, revealing this
    // device, so only the everyone mode does it.
    discovery.set_answer_announcements(config.visibility == Visibility::Everyone);

    let (rpc_tx, mut rpc_rx) = mpsc::channel::<RpcCall>(64);
    let socket_cancel = CancellationToken::new();
    let socket_task = tokio::spawn(serve_management(listener, rpc_tx, socket_cancel.clone()));
    let (internal_tx, mut internal_rx) = mpsc::channel::<InternalEvent>(64);

    let mut controller = Controller {
        identity,
        server,
        server_tx,
        pin: config.pin,
        auto_accept: config.auto_accept,
        visibility: config.visibility,
        favorites: HashMap::new(),
        multicast_down: discovery.multicast_error().is_some(),
        discovery,
        discovery_tx,
        discovery_stop_tx: Some(discovery_stop_tx),
        socket: config.socket,
        destination,
        started_at: now(),
        status: DaemonStatus::Running,
        error: None,
        pending: None,
        incoming: None,
        outgoing: None,
        selecting_outgoing: false,
        recent: VecDeque::new(),
        refresh_id: None,
        early_remote_cancel: None,
        cooldown: Cooldown::default(),
        internal_tx,
    };
    if let Some(error) = controller.discovery.multicast_error() {
        controller.set_error(
            "multicast_unavailable",
            format!("Discovery is running without multicast: {error}"),
        );
    }
    // The favorites arrive with the first set-visibility; hidden mode
    // contacts nobody until the user refreshes.
    if controller.visibility != Visibility::Hidden {
        controller.start_refresh();
    }

    emit_daemon_event(
        "ready",
        json!({
            "socket": controller.socket,
            "port": controller.identity.port,
            "alias": controller.identity.alias,
            "pid": std::process::id(),
            "visibility": controller.visibility,
            "pinRequired": controller.pin.is_some(),
            "autoAccept": controller.effective_auto_accept()
        }),
    );

    let mut progress_tick = tokio::time::interval(Duration::from_millis(250));
    progress_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut announce_tick = tokio::time::interval(ANNOUNCE_INTERVAL);
    announce_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    // The staged refresh already announces immediately.
    announce_tick.tick().await;
    let shutdown_signal = shutdown_signal();
    tokio::pin!(shutdown_signal);

    let mut activity = controller.activity();
    let mut stop = false;
    while !stop {
        tokio::select! {
            Some(call) = rpc_rx.recv() => {
                stop = controller.handle_rpc(call).await;
            }
            Some(event) = server_rx.recv() => {
                controller.handle_server_event(event);
                if controller.status == DaemonStatus::Error {
                    stop = true;
                }
            }
            Some(event) = discovery_rx.recv() => {
                controller.handle_discovery_event(event);
            }
            Some(event) = internal_rx.recv() => {
                controller.handle_internal_event(event);
            }
            _ = progress_tick.tick(), if controller.has_work_in_progress() => {
                controller.sync_progress();
                controller.expire_pending();
                controller.expire_incoming().await;
            }
            _ = announce_tick.tick() => {
                controller.retry_multicast().await;
                match controller.visibility {
                    Visibility::Everyone if controller.refresh_id.is_none() => {
                        let discovery = controller.discovery.clone();
                        tokio::spawn(async move { discovery.announce().await; });
                    }
                    // Keeps the favorites (and their view of this device) fresh.
                    Visibility::Favorites => {
                        controller.start_refresh();
                    }
                    _ => {}
                }
            }
            _ = &mut shutdown_signal => {
                stop = true;
            }
        }
        // Hidden mode keeps the receiver only until the transfer it was
        // serving has finished.
        if controller.should_stop_server() {
            controller.stop_server().await;
        }
        // Tells the plugin to fetch a snapshot now instead of at its next
        // idle poll.
        let current = controller.activity();
        if current != activity {
            activity = current;
            emit_daemon_event("changed", json!({}));
        }
    }

    controller.status = DaemonStatus::ShuttingDown;
    if let Some(pending) = controller.pending.take() {
        let _ = pending.decision_tx.send(PrepareUploadDecisionV2::Decline);
    }
    let outgoing_task = controller.outgoing.take().map(|outgoing| {
        outgoing.cancel.cancel();
        outgoing.task
    });
    if let Some(incoming) = controller.incoming.take() {
        if let Some(server) = &controller.server {
            server.handle.cancel_v2_session(&incoming.record.id).await;
        }
        spawn_cancel_notification(
            controller.identity.clone(),
            incoming.sender,
            incoming.record.id,
        );
    }

    if let Some(stop_tx) = controller.discovery_stop_tx.take() {
        let _ = stop_tx.send(());
    }
    socket_cancel.cancel();

    controller.stop_server().await;
    let _ = tokio::time::timeout(Duration::from_secs(2), controller.discovery.wait_stopped()).await;
    if let Some(task) = outgoing_task {
        let _ = tokio::time::timeout(Duration::from_secs(2), task).await;
    }
    let _ = tokio::time::timeout(Duration::from_secs(2), socket_task).await;
    drop(socket_guard);

    emit_daemon_event("stopped", json!({"status": "stopped"}));
    Ok(())
}

impl Controller {
    async fn handle_rpc(&mut self, call: RpcCall) -> bool {
        match call.request {
            RpcRequest::Snapshot {} => {
                self.sync_progress();
                let snapshot = self.snapshot();
                let _ = call.reply.send(RpcResponse::success(snapshot));
            }
            RpcRequest::Refresh {} => {
                let started = self.refresh_id.is_none();
                let id = self.start_refresh();
                let _ = call.reply.send(RpcResponse::success(json!({
                    "refreshId": id,
                    "started": started
                })));
            }
            RpcRequest::SendFiles { device, paths, pin } => {
                if self.outgoing.is_some() || self.selecting_outgoing {
                    let _ = call.reply.send(RpcResponse::failure(outgoing_busy()));
                } else {
                    self.selecting_outgoing = true;
                    let internal = self.internal_tx.clone();
                    tokio::spawn(async move {
                        let result =
                            match tokio::task::spawn_blocking(move || collect_selection(&paths))
                                .await
                            {
                                Ok(result) => result,
                                Err(_) => Err(ApiError::new(
                                    "selection_failed",
                                    "The file selection task failed",
                                )),
                            };
                        let _ = internal
                            .send(InternalEvent::SelectionReady {
                                device,
                                pin,
                                result,
                                reply: call.reply,
                            })
                            .await;
                    });
                }
            }
            RpcRequest::SendText { device, text, pin } => {
                let response = if self.outgoing.is_some() || self.selecting_outgoing {
                    RpcResponse::failure(outgoing_busy())
                } else {
                    RpcResponse::from_result(
                        crate::files::text_item(text)
                            .and_then(|item| self.start_outgoing(&device, vec![item], pin))
                            .map(|transfer| json!({"transfer": transfer})),
                    )
                };
                let _ = call.reply.send(response);
            }
            RpcRequest::AddDevice { host, port } => {
                // The probe registers with that address, so it learns about
                // this device; the user asked for exactly that.
                let discovery = self.discovery.clone();
                tokio::spawn(async move {
                    let response = match discovery.discover(&host, port, ProtocolType::Https).await
                    {
                        Ok(Some(device)) => {
                            RpcResponse::success(json!({"device": device_snapshot(&device, false)}))
                        }
                        _ => RpcResponse::failure(ApiError::new(
                            "device_unreachable",
                            format!("No LocalSend device answered over HTTPS at {host}:{port}"),
                        )),
                    };
                    let _ = call.reply.send(response);
                });
            }
            RpcRequest::Accept { request } => {
                let response = RpcResponse::from_result(
                    self.accept_pending(&request)
                        .await
                        .map(|transfer| json!({"transfer": transfer})),
                );
                let _ = call.reply.send(response);
            }
            RpcRequest::Decline { request } => {
                let response = RpcResponse::from_result(
                    self.decline_pending(&request)
                        .map(|transfer| json!({"transfer": transfer})),
                );
                let _ = call.reply.send(response);
            }
            RpcRequest::Cancel { transfer } => {
                let response = RpcResponse::from_result(
                    self.cancel_transfer(&transfer)
                        .await
                        .map(|transfer| json!({"transfer": transfer})),
                );
                let _ = call.reply.send(response);
            }
            RpcRequest::SetVisibility {
                visibility,
                favorites,
            } => {
                let favorites_changed = self.set_favorites(favorites);
                let response = RpcResponse::from_result(
                    self.set_visibility(visibility, favorites_changed)
                        .await
                        .map(|()| {
                            json!({
                                "visibility": self.visibility,
                                "receiving": self.server.is_some()
                            })
                        }),
                );
                let _ = call.reply.send(response);
            }
            RpcRequest::Shutdown {} => {
                let _ = call.reply.send(RpcResponse::success(json!({
                    "status": "shutting_down"
                })));
                return true;
            }
        }
        false
    }

    /// Replaces the favorites; true when the list or an address changed.
    fn set_favorites(&mut self, favorites: Vec<FavoriteSpec>) -> bool {
        let favorites: HashMap<String, Option<HttpChannel>> = favorites
            .into_iter()
            .map(|favorite| {
                let channel = match (favorite.host, favorite.port) {
                    (Some(host), Some(port)) => Some(HttpChannel {
                        host,
                        port,
                        protocol: ProtocolType::Https,
                    }),
                    _ => None,
                };
                (favorite.fingerprint.to_ascii_uppercase(), channel)
            })
            .collect();
        let changed = favorites != self.favorites;
        self.favorites = favorites;
        changed
    }

    /// Everyone without a long PIN would let any device on the network
    /// write to the disk unasked, so it is narrowed to favorites.
    fn effective_auto_accept(&self) -> AutoAccept {
        effective_auto_accept(self.auto_accept, self.pin.as_ref())
    }

    fn auto_accepts(&self, fingerprint: &str) -> bool {
        match self.effective_auto_accept() {
            AutoAccept::Off => false,
            AutoAccept::Favorites => self.is_favorite(fingerprint),
            AutoAccept::Everyone => true,
        }
    }

    fn is_favorite(&self, fingerprint: &str) -> bool {
        self.favorites
            .contains_key(&fingerprint.to_ascii_uppercase())
    }

    /// Whether the current mode accepts registrations and requests from a
    /// sender with this (verified) fingerprint.
    fn accepts_peer(&self, fingerprint: &str) -> bool {
        match self.visibility {
            Visibility::Everyone => true,
            Visibility::Favorites => self.is_favorite(fingerprint),
            Visibility::Hidden => false,
        }
    }

    /// HTTPS addresses to probe the favorites at, each with the fingerprint
    /// expected there: the ones last saved by the plugin plus every HTTPS
    /// channel discovery knows for them.
    fn favorite_channels(&self) -> Vec<(String, HttpChannel)> {
        let mut channels: HashSet<(String, HttpChannel)> = self
            .favorites
            .iter()
            .filter_map(|(fingerprint, channel)| {
                channel
                    .clone()
                    .map(|channel| (fingerprint.clone(), channel))
            })
            .collect();
        for device in self.discovery.devices() {
            let fingerprint = device.device.fingerprint.to_ascii_uppercase();
            if self.favorites.contains_key(&fingerprint) {
                channels.extend(
                    device
                        .channels
                        .keys()
                        .filter_map(DeviceChannel::http)
                        .filter(|channel| channel.protocol == ProtocolType::Https)
                        .map(|channel| (fingerprint.clone(), channel.clone())),
                );
            }
        }
        channels.into_iter().collect()
    }

    async fn set_visibility(
        &mut self,
        visibility: Visibility,
        favorites_changed: bool,
    ) -> ApiResult<()> {
        if visibility != Visibility::Hidden && self.server.is_none() {
            let server =
                RunningServer::start(&self.identity, self.pin.as_ref(), self.server_tx.clone())
                    .await
                    .map_err(|error| ApiError::new("receiver_unavailable", format!("{error:#}")))?;
            self.server = Some(server);
        }
        let changed = visibility != self.visibility;
        self.visibility = visibility;
        self.discovery
            .set_answer_announcements(visibility == Visibility::Everyone);

        // A waiting request the new mode would not have let in is declined.
        let rejected = self
            .pending
            .as_ref()
            .filter(|pending| !self.accepts_peer(&pending.sender.fingerprint))
            .map(|pending| pending.snapshot.id.clone());
        if let Some(id) = rejected {
            let _ = self.decline_pending(&id);
        }

        if self.should_stop_server() {
            self.stop_server().await;
        }
        if (changed || favorites_changed) && visibility != Visibility::Hidden {
            self.start_refresh();
        }
        Ok(())
    }

    fn should_stop_server(&self) -> bool {
        self.visibility == Visibility::Hidden
            && self.server.is_some()
            && self.pending.is_none()
            && self.incoming.is_none()
    }

    async fn stop_server(&mut self) {
        if let Some(server) = self.server.take() {
            server.stop().await;
        }
    }

    fn handle_internal_event(&mut self, event: InternalEvent) {
        match event {
            InternalEvent::SelectionReady {
                device,
                pin,
                result,
                reply,
            } => {
                self.selecting_outgoing = false;
                if reply.is_closed() {
                    return;
                }
                let response = RpcResponse::from_result(
                    result
                        .and_then(|items| self.start_outgoing(&device, items, pin))
                        .map(|transfer| json!({"transfer": transfer})),
                );
                let _ = reply.send(response);
            }
            InternalEvent::RefreshFinished { id, result } => {
                if self.refresh_id.as_deref() == Some(&id) {
                    self.refresh_id = None;
                    match result {
                        Err(message) => self.set_error("refresh_failed", message),
                        Ok(())
                            if self
                                .error
                                .as_ref()
                                .is_some_and(|error| error.code == "refresh_failed") =>
                        {
                            self.error = None;
                        }
                        Ok(()) => {}
                    }
                }
            }
            InternalEvent::OutgoingPrepared {
                transfer_id,
                session_id,
                accepted,
            } => {
                let Some(active) = self
                    .outgoing
                    .as_mut()
                    .filter(|active| active.record.id == transfer_id)
                else {
                    return;
                };
                active.remote_session_id = Some(session_id);
                active.record.state = TransferState::Transferring;
                let at = now();
                active.record.started_at = Some(at.clone());
                active.record.updated_at = at;
                for file in &mut active.record.files {
                    if !accepted.contains(&file.id) {
                        file.state = TransferFileState::Declined;
                    }
                }
                if self
                    .early_remote_cancel
                    .take()
                    .is_some_and(|(host, remote_id)| {
                        host == active.host
                            && active.remote_session_id.as_deref() == Some(remote_id.as_str())
                    })
                {
                    active.by_peer.store(true, Ordering::Relaxed);
                    active.cancel.cancel();
                    active.record.state = TransferState::Cancelling;
                }
            }
            InternalEvent::OutgoingFileStarted {
                transfer_id,
                file_id,
            } => {
                if let Some(file) = self.outgoing_file_mut(&transfer_id, &file_id) {
                    file.state = TransferFileState::Transferring;
                    file.error = None;
                }
            }
            InternalEvent::OutgoingFileCompleted {
                transfer_id,
                file_id,
            } => {
                if let Some(file) = self.outgoing_file_mut(&transfer_id, &file_id) {
                    file.state = TransferFileState::Completed;
                    file.completed_bytes = file.size;
                }
            }
            InternalEvent::OutgoingFileFailed {
                transfer_id,
                file_id,
                error,
            } => {
                if let Some(file) = self.outgoing_file_mut(&transfer_id, &file_id) {
                    file.state = TransferFileState::Failed;
                    file.error = Some(error);
                }
            }
            InternalEvent::OutgoingFinished {
                transfer_id,
                state,
                error,
            } => self.finish_outgoing(&transfer_id, state, error),
            InternalEvent::IncomingFileResult {
                transfer_id,
                file_id,
                result,
            } => self.handle_incoming_file_result(&transfer_id, &file_id, result),
        }
    }

    fn outgoing_file_mut(
        &mut self,
        transfer_id: &str,
        file_id: &str,
    ) -> Option<&mut TransferFileSnapshot> {
        let active = self
            .outgoing
            .as_mut()
            .filter(|active| active.record.id == transfer_id)?;
        active.record.updated_at = now();
        active
            .record
            .files
            .iter_mut()
            .find(|file| file.id == file_id)
    }

    fn finish_outgoing(
        &mut self,
        transfer_id: &str,
        state: TransferState,
        error: Option<ApiError>,
    ) {
        let Some(mut active) = self.outgoing.take() else {
            return;
        };
        if active.record.id != transfer_id {
            self.outgoing = Some(active);
            return;
        }
        sync_record_progress(&mut active.record, &active.progress);
        active.record.state = state;
        active.record.error = error;
        let at = now();
        if state == TransferState::Completed && active.record.started_at.is_none() {
            active.record.started_at = Some(at.clone());
        }
        active.record.updated_at = at.clone();
        active.record.finished_at = Some(at);
        let transfer_error = active.record.error.clone();
        for file in &mut active.record.files {
            match state {
                TransferState::Completed if file.state != TransferFileState::Declined => {
                    file.state = TransferFileState::Completed;
                    file.completed_bytes = file.size;
                }
                TransferState::Cancelled
                    if matches!(
                        file.state,
                        TransferFileState::Queued | TransferFileState::Transferring
                    ) =>
                {
                    file.state = TransferFileState::Cancelled;
                }
                TransferState::Declined => file.state = TransferFileState::Declined,
                TransferState::Failed
                    if matches!(
                        file.state,
                        TransferFileState::Queued | TransferFileState::Transferring
                    ) =>
                {
                    file.state = TransferFileState::Failed;
                    if file.error.is_none() {
                        file.error = transfer_error.clone();
                    }
                }
                _ => {}
            }
        }
        active.record.completed_bytes = active
            .record
            .files
            .iter()
            .map(|file| file.completed_bytes)
            .sum();
        self.early_remote_cancel = None;
        self.push_recent(active.record);
    }

    fn handle_server_event(&mut self, event: ServerEventV2) {
        match event {
            ServerEventV2::Register { ip, info } => {
                // Only emitted with a verified fingerprint, see ServerEventV2.
                if !self.accepts_peer(&info.fingerprint) {
                    return;
                }
                if let Err(error) = validate_sender_info(&info) {
                    self.set_error(error.code, error.message);
                    return;
                }
                let fingerprint = info.fingerprint.clone();
                self.add_confirmed_device(ip.to_string(), info, fingerprint);
            }
            ServerEventV2::PrepareUpload {
                session_id,
                ip,
                info,
                cert_fingerprint,
                files,
                decision_tx,
            } => self.receive_offer(
                session_id,
                ip.to_string(),
                info,
                cert_fingerprint,
                files,
                decision_tx,
            ),
            ServerEventV2::FileUpload {
                session_id,
                file_id,
                file: _,
                target_tx,
            } => self.handle_file_upload(session_id, file_id, target_tx),
            ServerEventV2::SessionEnd { session_id, reason } => {
                let Some(active) = self
                    .incoming
                    .as_mut()
                    .filter(|active| active.record.id == session_id)
                else {
                    return;
                };
                active.end = Some(match reason {
                    SessionEndReasonV2::Finished => IncomingEnd::Finished,
                    SessionEndReasonV2::Cancelled => IncomingEnd::Cancelled,
                });
                self.finish_incoming_if_ready();
            }
            ServerEventV2::PrepareUploadAborted { session_id } => {
                if self
                    .pending
                    .as_ref()
                    .map(|pending| pending.snapshot.id.as_str())
                    == Some(session_id.as_str())
                {
                    let pending = self.pending.take().expect("pending was checked");
                    self.cooldown.start(&pending.sender);
                    let mut record = transfer_from_pending(&pending, TransferState::Cancelled);
                    let finished = now();
                    record.updated_at = finished.clone();
                    record.finished_at = Some(finished);
                    self.push_recent(record);
                }
            }
            ServerEventV2::CancelReceived { ip, session_id } => {
                let Some(active) = self.outgoing.as_mut() else {
                    return;
                };
                let host = ip.to_string();
                if active.host != host {
                    return;
                }
                if active.remote_session_id.as_deref() == Some(session_id.as_str()) {
                    active.by_peer.store(true, Ordering::Relaxed);
                    active.cancel.cancel();
                    active.record.state = TransferState::Cancelling;
                    active.record.updated_at = now();
                } else if active.remote_session_id.is_none() {
                    self.early_remote_cancel = Some((host, session_id));
                }
            }
            ServerEventV2::ListenerFailed { error } => {
                self.discovery.set_answer_announcements(false);
                self.status = DaemonStatus::Error;
                self.set_error("receiver_stopped", error);
            }
        }
    }

    fn handle_discovery_event(&mut self, event: DiscoveryEvent) {
        if matches!(event, DiscoveryEvent::MulticastFailed) {
            self.multicast_down = true;
            self.set_error(
                "multicast_stopped",
                "Multicast discovery stopped; manual HTTP refresh remains available",
            );
        }
    }

    /// Multicast needs a network interface when discovery starts, which the
    /// network may not have yet at login. The new discovery replaces the old
    /// one, and its devices, only once its multicast works.
    async fn retry_multicast(&mut self) {
        if !self.multicast_down {
            return;
        }
        let (discovery, stop_tx) = start_discovery(&self.identity, self.discovery_tx.clone()).await;
        if discovery.multicast_error().is_some() {
            let _ = stop_tx.send(());
            return;
        }
        if let Some(old_stop_tx) = self.discovery_stop_tx.replace(stop_tx) {
            let _ = old_stop_tx.send(());
        }
        self.discovery = discovery;
        self.discovery
            .set_answer_announcements(self.visibility == Visibility::Everyone);
        self.multicast_down = false;
        if self.error.as_ref().is_some_and(|error| {
            matches!(
                error.code.as_str(),
                "multicast_unavailable" | "multicast_stopped"
            )
        }) {
            self.error = None;
        }
        if self.visibility != Visibility::Hidden {
            self.refresh_id = None;
            self.start_refresh();
        }
    }

    fn add_confirmed_device(&self, host: String, mut info: RegisterDtoV2, fingerprint: String) {
        if fingerprint == self.identity.fingerprint {
            return;
        }
        info.fingerprint = fingerprint.clone();
        let device = DiscoveredDevice {
            alias: info.alias,
            version: info.version,
            device_model: info.device_model,
            device_type: info.device_type,
            fingerprint,
            channel: DeviceChannel::Http(HttpChannel {
                host,
                port: info.port,
                protocol: info.protocol,
            }),
            download: info.download,
        };
        let discovery = self.discovery.clone();
        tokio::spawn(async move {
            discovery.add_device(device).await;
        });
    }

    fn start_refresh(&mut self) -> String {
        if let Some(id) = &self.refresh_id {
            return id.clone();
        }
        let id = Uuid::new_v4().to_string();
        self.refresh_id = Some(id.clone());
        let discovery = self.discovery.clone();
        let internal = self.internal_tx.clone();
        let port = self.identity.port;
        let mut known = HashSet::new();
        for device in discovery.devices() {
            for channel in device.channels.keys() {
                if let Some(http) = channel.http() {
                    known.insert(http.clone());
                }
            }
        }
        let interfaces = local_interface_addresses(&InterfaceFilter::default()).unwrap_or_default();
        let visibility = self.visibility;
        let favorites = self.favorite_channels();
        let identity = self.identity.clone();
        let event_id = id.clone();
        tokio::spawn(async move {
            let result = match visibility {
                Visibility::Everyone => discovery
                    .discover_staged(
                        known.into_iter().collect(),
                        interfaces,
                        port,
                        ProtocolType::Https,
                        Duration::from_secs(1),
                    )
                    .await
                    .map_err(|_| "Staged discovery did not complete".to_string()),
                // No announcement and no subnet scan: only the favorites are
                // contacted, so only they learn about this device.
                Visibility::Favorites | Visibility::Hidden => {
                    probe_favorites(&identity, &discovery, favorites).await;
                    Ok(())
                }
            };
            let _ = internal
                .send(InternalEvent::RefreshFinished {
                    id: event_id,
                    result,
                })
                .await;
        });
        id
    }

    fn start_outgoing(
        &mut self,
        fingerprint: &str,
        items: Vec<OutgoingItem>,
        pin: Option<Pin>,
    ) -> ApiResult<TransferSnapshot> {
        if self.outgoing.is_some() {
            return Err(outgoing_busy());
        }
        validate_fingerprint(fingerprint)?;
        let device = self
            .discovery
            .devices()
            .into_iter()
            .find(|device| device.device.fingerprint.eq_ignore_ascii_case(fingerprint))
            .ok_or_else(|| ApiError::new("device_not_found", "Device is not in discovery state"))?;
        if !device_online(&device) {
            return Err(ApiError::new(
                "device_offline",
                "Device has not been confirmed recently; refresh discovery first",
            ));
        }
        let http = secure_channel(&device).cloned().ok_or_else(|| {
            ApiError::new(
                "device_unencrypted",
                "Device has no confirmed HTTPS address; unencrypted transfers are not supported",
            )
        })?;

        let total_bytes = items.iter().try_fold(0u64, |total, item| {
            total
                .checked_add(item.file.size)
                .ok_or_else(|| ApiError::new("selection_too_large", "Total byte count overflowed"))
        })?;
        let transfer_id = Uuid::new_v4().to_string();
        let text_message = items
            .iter()
            .any(|item| matches!(item.source, OutgoingSource::Bytes(_)));
        let peer = peer_from_device(&device, &http);
        let created = now();
        let mut files: Vec<TransferFileSnapshot> = items
            .iter()
            .map(|item| TransferFileSnapshot {
                id: item.file.id.clone(),
                name: item.file.file_name.clone(),
                size: item.file.size,
                mime_type: item.file.file_type.clone(),
                state: TransferFileState::Queued,
                completed_bytes: 0,
                source_path: item.source_path.clone(),
                destination_path: None,
                error: None,
            })
            .collect();
        files.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.id.cmp(&b.id)));
        let record = TransferSnapshot {
            id: transfer_id.clone(),
            direction: TransferDirection::Outgoing,
            state: TransferState::Preparing,
            peer,
            file_count: files.len(),
            files,
            total_bytes,
            completed_bytes: 0,
            created_at: created.clone(),
            started_at: None,
            updated_at: created,
            finished_at: None,
            error: None,
            auto_accepted: false,
            text_message,
        };
        let progress: HashMap<String, Arc<AtomicU64>> = items
            .iter()
            .map(|item| (item.file.id.clone(), Arc::new(AtomicU64::new(0))))
            .collect();
        let cancel = CancellationToken::new();
        let by_peer = Arc::new(AtomicBool::new(false));
        let task = tokio::spawn(outgoing::run_outgoing(OutgoingJob {
            transfer_id,
            identity: self.identity.clone(),
            device,
            channel: http.clone(),
            items,
            pin,
            progress: progress.clone(),
            cancel: cancel.clone(),
            by_peer: by_peer.clone(),
            internal: self.internal_tx.clone(),
        }));
        self.outgoing = Some(OutgoingActive {
            record: record.clone(),
            progress,
            cancel,
            by_peer,
            host: http.host,
            remote_session_id: None,
            task,
        });
        Ok(record)
    }

    async fn cancel_transfer(&mut self, transfer_id: &str) -> ApiResult<TransferSnapshot> {
        validate_uuid(transfer_id, "transfer")?;
        if let Some(active) = self
            .outgoing
            .as_mut()
            .filter(|active| active.record.id == transfer_id)
        {
            active.cancel.cancel();
            active.record.state = TransferState::Cancelling;
            active.record.updated_at = now();
            return Ok(active.record.clone());
        }
        if self
            .incoming
            .as_ref()
            .is_some_and(|active| active.record.id == transfer_id)
        {
            return Ok(self.cancel_incoming(None).await);
        }
        Err(ApiError::new("stale_transfer", "Transfer is not active"))
    }

    fn sync_progress(&mut self) {
        if let Some(active) = &mut self.outgoing {
            sync_record_progress(&mut active.record, &active.progress);
        }
        if let Some(active) = &mut self.incoming {
            sync_record_progress(&mut active.record, &active.progress);
        }
    }

    /// Whether the progress tick has anything to do: a request waiting for an
    /// answer, or a transfer whose progress and timeouts it tracks. An idle
    /// daemon then sleeps until the network or the plugin wakes it.
    fn has_work_in_progress(&self) -> bool {
        self.pending.is_some() || self.incoming.is_some() || self.outgoing.is_some()
    }

    fn activity(&self) -> Activity {
        let transfers = self
            .incoming
            .iter()
            .map(|active| &active.record)
            .chain(self.outgoing.iter().map(|active| &active.record))
            .chain(self.recent.iter())
            .map(|record| (record.id.clone(), record.state))
            .collect();
        Activity {
            status: self.status,
            visibility: self.visibility,
            receiving: self.server.is_some(),
            pending: self
                .pending
                .as_ref()
                .map(|pending| pending.snapshot.id.clone()),
            transfers,
            error: self
                .error
                .as_ref()
                .map(|error| (error.code.clone(), error.at.clone())),
        }
    }

    fn snapshot(&self) -> Snapshot {
        let mut devices: Vec<DeviceSnapshot> = self
            .discovery
            .devices()
            .iter()
            .map(|device| device_snapshot(device, self.is_favorite(&device.device.fingerprint)))
            .collect();
        devices.sort_by(|a, b| {
            b.online
                .cmp(&a.online)
                .then_with(|| a.alias.to_lowercase().cmp(&b.alias.to_lowercase()))
                .then_with(|| a.fingerprint.cmp(&b.fingerprint))
        });
        devices.truncate(MAX_DEVICES);

        let mut transfers = Vec::new();
        if let Some(incoming) = &self.incoming {
            transfers.push(incoming.record.clone());
        }
        if let Some(outgoing) = &self.outgoing {
            transfers.push(outgoing.record.clone());
        }
        transfers.extend(self.recent.iter().cloned());

        Snapshot {
            daemon: DaemonSnapshot {
                status: self.status,
                alias: self.identity.alias.clone(),
                fingerprint: self.identity.fingerprint.clone(),
                port: self.identity.port,
                destination: self.destination.to_string_lossy().into_owned(),
                socket: self.socket.to_string_lossy().into_owned(),
                pid: std::process::id(),
                protocol_version: PROTOCOL_VERSION_V2.to_string(),
                controller_version: env!("CARGO_PKG_VERSION").to_string(),
                started_at: self.started_at.clone(),
                refreshing: self.refresh_id.is_some(),
                visibility: self.visibility,
                receiving: self.server.is_some(),
                pin_required: self.pin.is_some(),
                auto_accept: self.effective_auto_accept(),
            },
            devices,
            incoming: self
                .pending
                .as_ref()
                .map(|pending| pending.snapshot.clone()),
            transfers,
            error: self.error.clone(),
        }
    }

    fn set_error(&mut self, code: impl Into<String>, message: impl Into<String>) {
        self.error = Some(ControllerError {
            code: code.into(),
            message: message.into(),
            at: now(),
        });
    }

    fn push_recent(&mut self, mut record: TransferSnapshot) {
        debug_assert!(record.state.terminal());
        record.files.truncate(MAX_RECENT_FILES);
        for file in &mut record.files {
            file.source_path = None;
        }
        self.recent.push_front(record);
        self.recent.truncate(MAX_RECENT_TRANSFERS);
    }
}

async fn start_discovery(
    identity: &Identity,
    event_tx: mpsc::Sender<DiscoveryEvent>,
) -> (Arc<DiscoveryHandle>, oneshot::Sender<()>) {
    let (stop_tx, stop_rx) = oneshot::channel();
    let discovery = localsend::discovery::start(
        DiscoveryConfig {
            group: DEFAULT_MULTICAST_GROUP,
            group_v6: Some(DEFAULT_MULTICAST_GROUP_V6),
            port: identity.port,
            interface_filter: InterfaceFilter::default(),
            device: identity.multicast_device(),
            identity: DeviceIdentity {
                cert_pem: identity.cert_pem.clone(),
                private_key_pem: identity.key_pem.clone(),
            },
            timeout: DEFAULT_DISCOVERY_TIMEOUT,
            event_tx: Some(event_tx),
        },
        stop_rx,
    )
    .await;
    (Arc::new(discovery), stop_tx)
}

fn outgoing_busy() -> ApiError {
    ApiError::new("outgoing_busy", "An outgoing transfer is already active")
}

fn effective_auto_accept(mode: AutoAccept, pin: Option<&Pin>) -> AutoAccept {
    match mode {
        AutoAccept::Everyone
            if !pin.is_some_and(|pin| pin.chars() >= MIN_AUTO_ACCEPT_PIN_CHARS) =>
        {
            AutoAccept::Favorites
        }
        mode => mode,
    }
}

fn sync_record_progress(record: &mut TransferSnapshot, progress: &HashMap<String, Arc<AtomicU64>>) {
    let mut changed = false;
    for file in &mut record.files {
        if let Some(counter) = progress.get(&file.id) {
            let value = counter.load(Ordering::Relaxed).min(file.size);
            if value != file.completed_bytes {
                file.completed_bytes = value;
                changed = true;
            }
        }
    }
    let total = record.files.iter().map(|file| file.completed_bytes).sum();
    if total != record.completed_bytes {
        record.completed_bytes = total;
        changed = true;
    }
    if changed {
        record.updated_at = now();
    }
}

/// The save folder, resolved. It may itself be a symbolic link (to another
/// disk, say) to a directory; links inside it are refused as files arrive.
fn prepare_destination(path: &Path) -> Result<PathBuf> {
    fs::create_dir_all(path)
        .with_context(|| format!("Could not create destination {}", path.display()))?;
    let destination = fs::canonicalize(path).context("Could not resolve destination")?;
    anyhow::ensure!(destination.is_dir(), "Destination is not a directory");
    Ok(destination)
}

async fn shutdown_signal() {
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("SIGTERM handler should be available on Linux");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = terminate.recv() => {}
    }
}

/// One line on stdout for the plugin. Once nobody reads the pipe there is
/// nobody to tell, so a failed write is ignored rather than a panic.
fn emit_daemon_event(event: &str, result: serde_json::Value) {
    let line = json!({"ok": true, "event": event, "result": result});
    let _ = writeln!(std::io::stdout().lock(), "{line}");
}

fn now() -> String {
    format_system_time(SystemTime::now())
}

fn format_system_time(time: SystemTime) -> String {
    OffsetDateTime::from(time)
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_save_folder_may_be_a_link_to_a_directory() {
        let temp = tempfile::tempdir().unwrap();
        let target = temp.path().join("disk");
        fs::create_dir(&target).unwrap();
        let link = temp.path().join("LocalSend");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert_eq!(
            prepare_destination(&link).unwrap(),
            fs::canonicalize(&target).unwrap()
        );

        let file = temp.path().join("file");
        fs::write(&file, "x").unwrap();
        assert!(prepare_destination(&file).is_err());
    }

    #[test]
    fn auto_accept_everyone_needs_a_long_pin() {
        let pin = |text: &str| Pin::try_from(text.to_string()).unwrap();
        let long = pin("7391-secret");
        let short = pin("1234");
        assert_eq!(
            effective_auto_accept(AutoAccept::Everyone, None),
            AutoAccept::Favorites
        );
        assert_eq!(
            effective_auto_accept(AutoAccept::Everyone, Some(&short)),
            AutoAccept::Favorites
        );
        assert_eq!(
            effective_auto_accept(AutoAccept::Everyone, Some(&long)),
            AutoAccept::Everyone
        );
        assert_eq!(
            effective_auto_accept(AutoAccept::Off, Some(&long)),
            AutoAccept::Off
        );
        assert_eq!(
            effective_auto_accept(AutoAccept::Favorites, None),
            AutoAccept::Favorites
        );
    }
}
