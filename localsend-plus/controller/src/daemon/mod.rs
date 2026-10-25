//! The long-running daemon: the LocalSend receiver, discovery and the
//! management socket, driven from one event loop.

mod management;
mod offer;
mod outgoing;

use crate::clipboard;
use crate::files::{
    collect_selection, remove_empty_directories, remove_reservations, replace_invisible,
    reserve_unique_destination, OutgoingItem, OutgoingSource,
};
use crate::identity::Identity;
use crate::rpc::{
    AddressSnapshot, ApiError, ApiResult, AutoAccept, ControllerError, DaemonSnapshot,
    DaemonStatus, DeviceSnapshot, FavoriteSpec, IncomingRequestSnapshot, OfferedFileSnapshot,
    PeerSnapshot, Pin, RpcRequest, RpcResponse, Snapshot, TransferDirection, TransferFileSnapshot,
    TransferFileState, TransferSnapshot, TransferState, Visibility, MIN_AUTO_ACCEPT_PIN_CHARS,
};
use anyhow::{Context, Result};
use localsend::discovery::{
    ChannelStatus, DeviceChannel, DeviceIdentity, DiscoveredDevice, DiscoveryConfig,
    DiscoveryEvent, DiscoveryHandle, HttpChannel, StatefulDevice, DEFAULT_DISCOVERY_TIMEOUT,
};
use localsend::http::client::LsHttpClientV2;
use localsend::http::dto_v2::RegisterDtoV2;
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2, SessionEndReasonV2};
use localsend::http::server::web::WebConfig;
use localsend::http::server::{start_with_port, ServerConfigV2, ServerHandle};
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use localsend::model::transfer::FileDto;
use localsend::multicast::{DEFAULT_MULTICAST_GROUP, DEFAULT_MULTICAST_GROUP_V6};
use localsend::util::interface::{local_interface_addresses, InterfaceFilter};
use management::{bind_management_socket, serve_management, RpcCall};
use offer::{
    embedded_message, message_preview, sanitize_message, validate_current_request,
    validate_fingerprint, validate_incoming_offer, validate_sender_info, validate_uuid,
};
use serde_json::json;
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
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
const ONLINE_TTL: Duration = Duration::from_secs(90);
const ANNOUNCE_INTERVAL: Duration = Duration::from_secs(30);
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
/// How long probing one favorite may take.
const FAVORITE_PROBE_TIMEOUT: Duration = Duration::from_secs(5);

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

#[derive(Clone)]
struct SenderTarget {
    host: String,
    port: u16,
    protocol: ProtocolType,
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
    /// count then; see [`INCOMING_IDLE_TIMEOUT`].
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
    /// Sender fingerprints (uppercase) whose requests are declined silently
    /// until the given instant.
    cooldown: HashMap<String, Instant>,
    internal_tx: mpsc::Sender<InternalEvent>,
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
    let (discovery_stop_tx, discovery_stop_rx) = oneshot::channel();
    let discovery = Arc::new(
        localsend::discovery::start(
            DiscoveryConfig {
                group: DEFAULT_MULTICAST_GROUP,
                group_v6: Some(DEFAULT_MULTICAST_GROUP_V6),
                port: config.port,
                interface_filter: InterfaceFilter::default(),
                device: identity.multicast_device(),
                identity: DeviceIdentity {
                    cert_pem: identity.cert_pem.clone(),
                    private_key_pem: identity.key_pem.clone(),
                },
                timeout: DEFAULT_DISCOVERY_TIMEOUT,
                event_tx: Some(discovery_tx),
            },
            discovery_stop_rx,
        )
        .await,
    );
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
        discovery,
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
        cooldown: HashMap::new(),
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
            _ = progress_tick.tick() => {
                controller.sync_progress();
                controller.expire_pending();
                controller.expire_incoming().await;
            }
            _ = announce_tick.tick() => {
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

    let _ = discovery_stop_tx.send(());
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
                    let _ = call.reply.send(RpcResponse::failure(ApiError::new(
                        "outgoing_busy",
                        "An outgoing transfer is already active",
                    )));
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
                    RpcResponse::failure(ApiError::new(
                        "outgoing_busy",
                        "An outgoing transfer is already active",
                    ))
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
                active.record.started_at = Some(now());
                active.record.updated_at = now();
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
        if state == TransferState::Completed && active.record.started_at.is_none() {
            active.record.started_at = Some(now());
        }
        active.record.updated_at = now();
        active.record.finished_at = Some(now());
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
            } => {
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
                    || self.in_cooldown(&fingerprint)
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

                let host = ip.to_string();
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
                        protocol: info.protocol,
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
                    self.start_cooldown(&pending.sender.fingerprint);
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

    fn handle_file_upload(
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

    fn handle_incoming_file_result(
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

    fn finish_incoming_if_ready(&mut self) {
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
    fn finish_incoming(&mut self, mut active: IncomingActive) {
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
        active.record.updated_at = now();
        active.record.finished_at = Some(now());
        self.push_recent(active.record);
    }

    fn handle_discovery_event(&mut self, event: DiscoveryEvent) {
        if matches!(event, DiscoveryEvent::MulticastFailed) {
            self.set_error(
                "multicast_stopped",
                "Multicast discovery stopped; manual HTTP refresh remains available",
            );
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
            return Err(ApiError::new(
                "outgoing_busy",
                "An outgoing transfer is already active",
            ));
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
        let task = tokio::spawn(outgoing::run_outgoing(
            transfer_id,
            self.identity.clone(),
            device,
            http.clone(),
            items,
            pin,
            progress.clone(),
            cancel.clone(),
            by_peer.clone(),
            self.internal_tx.clone(),
        ));
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

    async fn accept_pending(&mut self, request_id: &str) -> ApiResult<TransferSnapshot> {
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
                .map_err(|_| {
                    ApiError::new("stale_request", "Incoming request is no longer pending")
                })?;
            record.completed_bytes = record.total_bytes;
            for file in &mut record.files {
                file.state = TransferFileState::Completed;
                file.completed_bytes = file.size;
            }
            record.started_at = Some(now());
            record.updated_at = now();
            record.finished_at = Some(now());
            self.push_recent(record.clone());
            return Ok(record);
        }

        self.accept_files_pending(false)
    }

    /// Accepts the pending file request while no incoming transfer runs:
    /// checks the free space, reserves every destination path and starts
    /// receiving.
    fn accept_files_pending(&mut self, auto_accepted: bool) -> ApiResult<TransferSnapshot> {
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
            return Err(ApiError::new(
                "stale_request",
                "Incoming request is no longer pending",
            ));
        }

        record.started_at = Some(now());
        record.updated_at = now();
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

    fn decline_pending(&mut self, request_id: &str) -> ApiResult<TransferSnapshot> {
        validate_current_request(
            self.pending
                .as_ref()
                .map(|pending| pending.snapshot.id.as_str()),
            request_id,
        )?;
        let pending = self.pending.take().expect("pending was validated");
        self.start_cooldown(&pending.sender.fingerprint);
        let mut record = transfer_from_pending(&pending, TransferState::Declined);
        pending
            .decision_tx
            .send(PrepareUploadDecisionV2::Decline)
            .map_err(|_| ApiError::new("stale_request", "Incoming request is no longer pending"))?;
        let finished = now();
        record.updated_at = finished.clone();
        record.finished_at = Some(finished);
        self.push_recent(record.clone());
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

    /// Ends the incoming transfer at once: the session is dropped, the
    /// sender told, and files still being written are removed (an upload
    /// that is still running writes to a deleted file). Waiting for those
    /// uploads could take forever when the sender has gone away.
    async fn cancel_incoming(&mut self, error: Option<ApiError>) -> TransferSnapshot {
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
    async fn expire_incoming(&mut self) {
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

    fn in_cooldown(&self, fingerprint: &str) -> bool {
        self.cooldown
            .get(&fingerprint.to_ascii_uppercase())
            .is_some_and(|until| Instant::now() < *until)
    }

    fn start_cooldown(&mut self, fingerprint: &str) {
        self.cooldown.insert(
            fingerprint.to_ascii_uppercase(),
            Instant::now() + DECLINE_COOLDOWN,
        );
    }

    /// Declines a request left unanswered for too long and forgets expired
    /// cooldowns.
    fn expire_pending(&mut self) {
        let now = Instant::now();
        self.cooldown.retain(|_, until| now < *until);
        let expired = self
            .pending
            .as_ref()
            .filter(|pending| now.duration_since(pending.received) >= PENDING_TIMEOUT)
            .map(|pending| pending.snapshot.id.clone());
        if let Some(id) = expired {
            let _ = self.decline_pending(&id);
        }
    }

    fn sync_progress(&mut self) {
        if let Some(active) = &mut self.outgoing {
            sync_record_progress(&mut active.record, &active.progress);
        }
        if let Some(active) = &mut self.incoming {
            sync_record_progress(&mut active.record, &active.progress);
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

/// Registers with each favorite at its known addresses. The connection is
/// pinned to the favorite's certificate, so whoever holds an address now
/// (another device after a DHCP change, say) fails the TLS handshake and
/// learns nothing about this device.
async fn probe_favorites(
    identity: &Identity,
    discovery: &DiscoveryHandle,
    channels: Vec<(String, HttpChannel)>,
) {
    let probes = channels
        .into_iter()
        .map(|(fingerprint, channel)| async move {
            let client = LsHttpClientV2::try_new(
                &identity.key_pem,
                &identity.cert_pem,
                Some(fingerprint.clone()),
                Some(FAVORITE_PROBE_TIMEOUT),
            )
            .ok()?;
            let response = client
                .register(
                    ProtocolType::Https,
                    &channel.host,
                    channel.port,
                    identity.register_dto(),
                )
                .await
                .ok()?;
            let info = response.body;
            Some(DiscoveredDevice {
                alias: info.alias,
                version: info.version,
                device_model: info.device_model,
                device_type: info.device_type,
                fingerprint,
                channel: DeviceChannel::Http(channel),
                download: info.download,
            })
        });
    for device in futures_util::future::join_all(probes)
        .await
        .into_iter()
        .flatten()
    {
        discovery.add_device(device).await;
    }
}

fn transfer_from_pending(pending: &PendingIncoming, state: TransferState) -> TransferSnapshot {
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
fn ensure_free_space(destination: &Path, needed: u64) -> ApiResult<()> {
    let path = std::ffi::CString::new(destination.as_os_str().as_encoded_bytes())
        .map_err(|_| ApiError::new("destination_error", "Destination path is invalid"))?;
    let mut stats: libc::statvfs = unsafe { std::mem::zeroed() };
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

/// The best HTTPS channel of a device. Plain HTTP channels are skipped: their
/// fingerprint is only claimed, so anyone on the network can announce one for
/// a known device and would otherwise receive its transfers unencrypted.
fn secure_channel(device: &StatefulDevice) -> Option<&HttpChannel> {
    device
        .get_ranked_channels()
        .into_iter()
        .filter_map(DeviceChannel::http)
        .find(|channel| channel.protocol == ProtocolType::Https)
}

fn device_snapshot(device: &StatefulDevice, favorite: bool) -> DeviceSnapshot {
    let address = secure_channel(device).map(address_snapshot);
    DeviceSnapshot {
        fingerprint: device.device.fingerprint.clone(),
        alias: device.device.alias.clone(),
        device_type: device.device.device_type.as_ref().map(device_type_name),
        model: device.device.device_model.clone(),
        address,
        online: device_online(device),
        last_seen_at: device
            .logs
            .last()
            .map(|log| format_system_time(log.timestamp)),
        favorite,
    }
}

fn peer_from_device(device: &StatefulDevice, channel: &HttpChannel) -> PeerSnapshot {
    PeerSnapshot {
        fingerprint: device.device.fingerprint.clone(),
        alias: device.device.alias.clone(),
        device_type: device.device.device_type.as_ref().map(device_type_name),
        model: device.device.device_model.clone(),
        address: address_snapshot(channel),
    }
}

fn address_snapshot(channel: &HttpChannel) -> AddressSnapshot {
    AddressSnapshot {
        host: channel.host.clone(),
        port: channel.port,
        protocol: protocol_name(channel.protocol).to_string(),
    }
}

/// Online means an available HTTPS channel that was confirmed recently. Plain
/// HTTP confirmations do not count: their fingerprint is only claimed, so
/// anyone could keep an absent device looking online.
fn device_online(device: &StatefulDevice) -> bool {
    let now = SystemTime::now();
    device.channels.iter().any(|(channel, status)| {
        *status == ChannelStatus::Available
            && channel
                .http()
                .is_some_and(|http| http.protocol == ProtocolType::Https)
            && device
                .logs
                .iter()
                .rev()
                .find(|log| log.channel == *channel)
                .is_some_and(|log| {
                    now.duration_since(log.timestamp).unwrap_or_default() <= ONLINE_TTL
                })
    })
}

fn device_type_name(device_type: &DeviceType) -> String {
    match device_type {
        DeviceType::Mobile => "mobile",
        DeviceType::Desktop => "desktop",
        DeviceType::Web => "web",
        DeviceType::Headless => "headless",
        DeviceType::Server => "server",
    }
    .to_string()
}

fn protocol_name(protocol: ProtocolType) -> &'static str {
    match protocol {
        ProtocolType::Http => "http",
        ProtocolType::Https => "https",
    }
}

fn spawn_cancel_notification(identity: Arc<Identity>, sender: SenderTarget, session_id: String) {
    tokio::spawn(async move {
        let expected = match sender.protocol {
            ProtocolType::Https => Some(sender.fingerprint),
            ProtocolType::Http => None,
        };
        let Ok(client) = LsHttpClientV2::try_new(
            &identity.key_pem,
            &identity.cert_pem,
            expected,
            Some(Duration::from_secs(5)),
        ) else {
            return;
        };
        let _ = client
            .cancel(sender.protocol, &sender.host, sender.port, &session_id)
            .await;
    });
}

fn prepare_destination(path: &Path) -> Result<PathBuf> {
    fs::create_dir_all(path)
        .with_context(|| format!("Could not create destination {}", path.display()))?;
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("Could not inspect destination {}", path.display()))?;
    anyhow::ensure!(metadata.is_dir(), "Destination is not a directory");
    fs::canonicalize(path).context("Could not resolve destination")
}

async fn shutdown_signal() {
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("SIGTERM handler should be available on Linux");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = terminate.recv() => {}
    }
}

fn emit_daemon_event(event: &str, result: serde_json::Value) {
    let value = json!({"ok": true, "event": event, "result": result});
    println!("{value}");
}

fn now() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
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
    fn free_space_check_refuses_impossible_transfers() {
        let temp = std::env::temp_dir();
        assert!(ensure_free_space(&temp, 0).is_ok());
        assert_eq!(
            ensure_free_space(&temp, u64::MAX / 2).unwrap_err().code,
            "insufficient_space"
        );
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
