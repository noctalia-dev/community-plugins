//! The devices discovery knows, as the snapshot reports them, and probing
//! the favorites.

use super::format_system_time;
use crate::files::display_text;
use crate::identity::Identity;
use crate::rpc::{AddressSnapshot, DeviceSnapshot, PeerSnapshot};
use localsend::discovery::{
    ChannelStatus, DeviceChannel, DiscoveredDevice, DiscoveryHandle, HttpChannel, StatefulDevice,
};
use localsend::http::client::LsHttpClientV2;
use localsend::model::discovery::{DeviceType, ProtocolType};
use std::time::{Duration, SystemTime};

const ONLINE_TTL: Duration = Duration::from_secs(90);
/// How long probing one favorite may take.
const FAVORITE_PROBE_TIMEOUT: Duration = Duration::from_secs(5);

/// Registers with each favorite at its known addresses. The connection is
/// pinned to the favorite's certificate, so whoever holds an address now
/// (another device after a DHCP change, say) fails the TLS handshake and
/// learns nothing about this device.
pub(super) async fn probe_favorites(
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

/// The best HTTPS channel of a device. Plain HTTP channels are skipped: their
/// fingerprint is only claimed, so anyone on the network can announce one for
/// a known device and would otherwise receive its transfers unencrypted.
pub(super) fn secure_channel(device: &StatefulDevice) -> Option<&HttpChannel> {
    device
        .get_ranked_channels()
        .into_iter()
        .filter_map(DeviceChannel::http)
        .find(|channel| channel.protocol == ProtocolType::Https)
}

pub(super) fn device_snapshot(device: &StatefulDevice, favorite: bool) -> DeviceSnapshot {
    let address = secure_channel(device).map(address_snapshot);
    DeviceSnapshot {
        fingerprint: device.device.fingerprint.clone(),
        alias: shown_alias(device),
        device_type: device.device.device_type.as_ref().map(device_type_name),
        model: shown_model(device),
        address,
        online: device_online(device),
        last_seen_at: device
            .logs
            .last()
            .map(|log| format_system_time(log.timestamp)),
        favorite,
    }
}

pub(super) fn peer_from_device(device: &StatefulDevice, channel: &HttpChannel) -> PeerSnapshot {
    PeerSnapshot {
        fingerprint: device.device.fingerprint.clone(),
        alias: shown_alias(device),
        device_type: device.device.device_type.as_ref().map(device_type_name),
        model: shown_model(device),
        address: address_snapshot(channel),
    }
}

/// Discovery stores what peers announce unchecked, and the snapshot reaches
/// terminals and the panel, so names are cleaned on the way out.
fn shown_alias(device: &StatefulDevice) -> String {
    display_text(&device.device.alias)
}

fn shown_model(device: &StatefulDevice) -> Option<String> {
    device.device.device_model.as_deref().map(display_text)
}

pub(super) fn address_snapshot(channel: &HttpChannel) -> AddressSnapshot {
    AddressSnapshot {
        host: channel.host.clone(),
        port: channel.port,
        protocol: protocol_name(channel.protocol).to_string(),
    }
}

/// Online means an available HTTPS channel that was confirmed recently. Plain
/// HTTP confirmations do not count: their fingerprint is only claimed, so
/// anyone could keep an absent device looking online.
pub(super) fn device_online(device: &StatefulDevice) -> bool {
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

pub(super) fn device_type_name(device_type: &DeviceType) -> String {
    match device_type {
        DeviceType::Mobile => "mobile",
        DeviceType::Desktop => "desktop",
        DeviceType::Web => "web",
        DeviceType::Headless => "headless",
        DeviceType::Server => "server",
    }
    .to_string()
}

pub(super) fn protocol_name(protocol: ProtocolType) -> &'static str {
    match protocol {
        ProtocolType::Http => "http",
        ProtocolType::Https => "https",
    }
}
