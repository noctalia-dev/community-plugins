use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ApiError {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

impl ApiError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            details: None,
        }
    }
}

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

pub type ApiResult<T> = Result<T, ApiError>;

/// The largest request or response the management socket carries.
pub const MAX_RPC_BYTES: u64 = 8 * 1024 * 1024;

/// The port LocalSend uses unless told otherwise.
pub const DEFAULT_PORT: u16 = 53317;

/// The effective user id. Both ends of the management socket must run as
/// this user.
pub fn current_uid() -> u32 {
    // SAFETY: geteuid has no preconditions and cannot fail.
    unsafe { libc::geteuid() }
}

/// Who can discover this device and send to it.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize, clap::ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum Visibility {
    /// Announces itself, answers every announcement and accepts requests
    /// from anyone.
    #[default]
    Everyone,
    /// Silent on the network; only probes the favorites, and only their
    /// registrations and requests are accepted.
    Favorites,
    /// Silent on the network with the receiver stopped; sending still works.
    Hidden,
}

/// Which incoming file transfers are accepted without asking. Text messages
/// always wait for a decision, since accepting one replaces the clipboard.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize, clap::ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum AutoAccept {
    /// Every request waits for accept or decline.
    #[default]
    Off,
    /// Requests from favorites are accepted.
    Favorites,
    /// Requests from anyone are accepted; only allowed while a PIN of at
    /// least [`MIN_AUTO_ACCEPT_PIN_CHARS`] characters is set.
    Everyone,
}

/// The receiver limits wrong PINs per address, and a sender on the local
/// network can switch addresses, so a PIN that alone lets files in must not
/// be guessable in a few thousand tries.
pub const MIN_AUTO_ACCEPT_PIN_CHARS: usize = 8;

/// A LocalSend PIN. It is validated on creation and never shown by `Debug`.
#[derive(Clone, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
pub struct Pin(String);

pub const MAX_PIN_CHARS: usize = 64;

impl Pin {
    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn chars(&self) -> usize {
        self.0.chars().count()
    }
}

impl TryFrom<String> for Pin {
    type Error = ApiError;

    /// Accepts 1 to 64 characters without control characters; one trailing
    /// newline (as left by most editors and `echo`) is dropped.
    fn try_from(value: String) -> ApiResult<Self> {
        let value = value.strip_suffix('\n').unwrap_or(&value);
        if value.is_empty()
            || value.chars().count() > MAX_PIN_CHARS
            || value.chars().any(char::is_control)
        {
            return Err(ApiError::new(
                "invalid_pin",
                format!("A PIN has 1 to {MAX_PIN_CHARS} characters and no control characters"),
            ));
        }
        Ok(Self(value.to_string()))
    }
}

impl From<Pin> for String {
    fn from(pin: Pin) -> Self {
        pin.0
    }
}

impl fmt::Debug for Pin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Pin(***)")
    }
}

/// Parses `HOST:PORT`; the port is split off at the last colon, so IPv6 hosts
/// need no brackets.
pub fn parse_address(address: &str) -> Result<(String, u16), String> {
    let (host, port) = address
        .rsplit_once(':')
        .ok_or("address must be HOST:PORT")?;
    let port: u16 = port.parse().map_err(|_| "port is invalid")?;
    if port == 0 || host.is_empty() || host.len() > 256 || host.chars().any(char::is_control) {
        return Err("address is invalid".to_string());
    }
    Ok((host.to_string(), port))
}

/// A favorite device: its certificate fingerprint and, when known, the
/// HTTPS address it was last seen at.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct FavoriteSpec {
    pub fingerprint: String,
    pub host: Option<String>,
    pub port: Option<u16>,
}

impl std::str::FromStr for FavoriteSpec {
    type Err = String;

    /// Parses `FINGERPRINT` or `FINGERPRINT=HOST:PORT`; the port is split off
    /// at the last colon, so IPv6 hosts need no brackets.
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let (fingerprint, address) = match value.split_once('=') {
            Some((fingerprint, address)) => (fingerprint, Some(address)),
            None => (value, None),
        };
        if fingerprint.is_empty()
            || fingerprint.len() > 256
            || !fingerprint.chars().all(|c| c.is_ascii_alphanumeric())
        {
            return Err("favorite fingerprint must be alphanumeric".to_string());
        }
        let (host, port) = match address {
            None => (None, None),
            Some(address) => {
                let (host, port) =
                    parse_address(address).map_err(|error| format!("favorite {error}"))?;
                (Some(host), Some(port))
            }
        };
        Ok(Self {
            fingerprint: fingerprint.to_string(),
            host,
            port,
        })
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, tag = "command", rename_all = "kebab-case")]
pub enum RpcRequest {
    Snapshot {},
    Refresh {},
    SendFiles {
        device: String,
        paths: Vec<String>,
        #[serde(default)]
        pin: Option<Pin>,
    },
    SendText {
        device: String,
        text: String,
        #[serde(default)]
        pin: Option<Pin>,
    },
    AddDevice {
        host: String,
        port: u16,
    },
    Accept {
        request: String,
    },
    Decline {
        request: String,
    },
    Cancel {
        transfer: String,
    },
    SetVisibility {
        visibility: Visibility,
        favorites: Vec<FavoriteSpec>,
    },
    Shutdown {},
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct RpcResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ApiError>,
}

impl RpcResponse {
    pub fn success<T: Serialize>(result: T) -> Self {
        match serde_json::to_value(result) {
            Ok(result) => Self {
                ok: true,
                result: Some(result),
                error: None,
            },
            Err(_) => Self::failure(ApiError::new(
                "serialization_error",
                "Could not serialize the response",
            )),
        }
    }

    pub fn failure(error: ApiError) -> Self {
        Self {
            ok: false,
            result: None,
            error: Some(error),
        }
    }

    pub fn from_result<T: Serialize>(result: ApiResult<T>) -> Self {
        match result {
            Ok(result) => Self::success(result),
            Err(error) => Self::failure(error),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub daemon: DaemonSnapshot,
    pub devices: Vec<DeviceSnapshot>,
    pub incoming: Option<IncomingRequestSnapshot>,
    pub transfers: Vec<TransferSnapshot>,
    pub error: Option<ControllerError>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DaemonStatus {
    Running,
    /// The receiver failed; the daemon stops.
    Error,
    ShuttingDown,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DaemonSnapshot {
    pub status: DaemonStatus,
    pub alias: String,
    pub fingerprint: String,
    pub port: u16,
    pub destination: String,
    pub socket: String,
    pub pid: u32,
    pub protocol_version: String,
    pub controller_version: String,
    pub started_at: String,
    pub refreshing: bool,
    pub visibility: Visibility,
    /// Whether the LocalSend receiver is running (it stays up in hidden
    /// mode until an incoming transfer has finished).
    pub receiving: bool,
    /// Whether senders must give a PIN; the PIN itself is never reported.
    pub pin_required: bool,
    /// The auto-accept mode in effect (everyone falls back to favorites
    /// without a long enough PIN).
    pub auto_accept: AutoAccept,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerError {
    pub code: String,
    pub message: String,
    pub at: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceSnapshot {
    pub fingerprint: String,
    pub alias: String,
    #[serde(rename = "type")]
    pub device_type: Option<String>,
    pub model: Option<String>,
    pub address: Option<AddressSnapshot>,
    pub online: bool,
    pub last_seen_at: Option<String>,
    /// One of the favorites the plugin passed with set-visibility.
    pub favorite: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AddressSnapshot {
    pub host: String,
    pub port: u16,
    pub protocol: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerSnapshot {
    pub fingerprint: String,
    pub alias: String,
    #[serde(rename = "type")]
    pub device_type: Option<String>,
    pub model: Option<String>,
    pub address: AddressSnapshot,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IncomingRequestSnapshot {
    pub id: String,
    pub sender: PeerSnapshot,
    pub files: Vec<OfferedFileSnapshot>,
    pub total_bytes: u64,
    pub message_preview: Option<String>,
    pub message_preview_truncated: bool,
    pub received_at: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OfferedFileSnapshot {
    pub id: String,
    pub name: String,
    pub size: u64,
    pub mime_type: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TransferDirection {
    Incoming,
    Outgoing,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TransferState {
    Preparing,
    Transferring,
    Cancelling,
    Completed,
    Declined,
    Cancelled,
    Failed,
}

impl TransferState {
    pub fn terminal(self) -> bool {
        matches!(
            self,
            Self::Completed | Self::Declined | Self::Cancelled | Self::Failed
        )
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TransferFileState {
    Queued,
    Transferring,
    Completed,
    Declined,
    Cancelled,
    Failed,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferFileSnapshot {
    pub id: String,
    pub name: String,
    pub size: u64,
    pub mime_type: String,
    pub state: TransferFileState,
    pub completed_bytes: u64,
    pub source_path: Option<String>,
    pub destination_path: Option<String>,
    pub error: Option<ApiError>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferSnapshot {
    pub id: String,
    pub direction: TransferDirection,
    pub state: TransferState,
    pub peer: PeerSnapshot,
    pub file_count: usize,
    pub files: Vec<TransferFileSnapshot>,
    pub total_bytes: u64,
    pub completed_bytes: u64,
    pub created_at: String,
    pub started_at: Option<String>,
    pub updated_at: String,
    pub finished_at: Option<String>,
    pub error: Option<ApiError>,
    /// An incoming transfer the auto-accept mode accepted without asking.
    pub auto_accepted: bool,
    /// A text message rather than files.
    pub text_message: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_serializes_rpc_commands() {
        let request: RpcRequest = serde_json::from_str(
            r#"{"command":"send-files","device":"ABC","paths":["/tmp/a","/tmp/b"]}"#,
        )
        .unwrap();
        match request {
            RpcRequest::SendFiles { device, paths, pin } => {
                assert_eq!(device, "ABC");
                assert_eq!(paths, ["/tmp/a", "/tmp/b"]);
                assert!(pin.is_none());
            }
            _ => panic!("wrong request variant"),
        }

        let serialized = serde_json::to_value(RpcRequest::Accept {
            request: "550e8400-e29b-41d4-a716-446655440000".to_string(),
        })
        .unwrap();
        assert_eq!(serialized["command"], "accept");
        assert_eq!(
            serialized["request"],
            "550e8400-e29b-41d4-a716-446655440000"
        );
    }

    #[test]
    fn response_envelopes_have_one_payload_branch() {
        let success = serde_json::to_value(RpcResponse::success(serde_json::json!({
            "status": "running"
        })))
        .unwrap();
        assert_eq!(success["ok"], true);
        assert!(success.get("result").is_some());
        assert!(success.get("error").is_none());

        let failure = serde_json::to_value(RpcResponse::failure(ApiError::new(
            "stale_request",
            "Request is no longer pending",
        )))
        .unwrap();
        assert_eq!(failure["ok"], false);
        assert_eq!(failure["error"]["code"], "stale_request");
        assert!(failure.get("result").is_none());
    }

    #[test]
    fn parses_favorite_specs() {
        let plain: FavoriteSpec = "ABC123".parse().unwrap();
        assert_eq!(plain.host, None);
        let v4: FavoriteSpec = "ABC123=192.168.1.5:53317".parse().unwrap();
        assert_eq!(
            (v4.host.as_deref(), v4.port),
            (Some("192.168.1.5"), Some(53317))
        );
        let v6: FavoriteSpec = "ABC123=fe80::1%3:53317".parse().unwrap();
        assert_eq!(v6.host.as_deref(), Some("fe80::1%3"));
        assert!("--path=/etc/passwd".parse::<FavoriteSpec>().is_err());
        assert!("ABC=host".parse::<FavoriteSpec>().is_err());

        let request: RpcRequest = serde_json::from_str(
            r#"{"command":"set-visibility","visibility":"favorites","favorites":[{"fingerprint":"ABC","host":null,"port":null}]}"#,
        )
        .unwrap();
        assert!(matches!(
            request,
            RpcRequest::SetVisibility {
                visibility: Visibility::Favorites,
                ..
            }
        ));
    }

    #[test]
    fn rejects_unknown_rpc_fields() {
        let parsed =
            serde_json::from_str::<RpcRequest>(r#"{"command":"ping","unexpected":"not accepted"}"#);
        assert!(parsed.is_err());
    }

    #[test]
    fn validates_pins_and_hides_them() {
        let pin = Pin::try_from("1234\n".to_string()).unwrap();
        assert_eq!(pin.as_str(), "1234");
        assert!(!format!("{pin:?}").contains("1234"));
        assert!(Pin::try_from(String::new()).is_err());
        assert!(Pin::try_from("12\t34".to_string()).is_err());
        assert!(Pin::try_from("x".repeat(MAX_PIN_CHARS + 1)).is_err());
        assert!(Pin::try_from("ąę-π".to_string()).is_ok());

        let request: RpcRequest = serde_json::from_str(
            r#"{"command":"send-text","device":"ABC","text":"hi","pin":"0000"}"#,
        )
        .unwrap();
        assert!(matches!(request, RpcRequest::SendText { pin: Some(_), .. }));
        assert!(serde_json::from_str::<RpcRequest>(
            r#"{"command":"send-text","device":"ABC","text":"hi","pin":""}"#
        )
        .is_err());
    }

    #[test]
    fn parses_addresses() {
        assert_eq!(
            parse_address("192.168.1.5:53317").unwrap(),
            ("192.168.1.5".to_string(), 53317)
        );
        assert_eq!(parse_address("fe80::1%3:1234").unwrap().0, "fe80::1%3");
        assert!(parse_address("phone.local").is_err());
        assert!(parse_address("phone.local:0").is_err());
        assert!(parse_address(":53317").is_err());
    }
}
