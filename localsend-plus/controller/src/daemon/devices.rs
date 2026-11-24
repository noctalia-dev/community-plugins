//! The devices discovery knows, as the snapshot reports them, and probing
//! the favorites.

use super::format_system_time;
use crate::files::display_text;
use crate::identity::Identity;
use crate::rpc::{AddressSnapshot, DeviceSnapshot, PeerSnapshot};
use localsend::discovery::{
    ChannelState, DeviceChannel, DeviceLogEvent, DiscoveredDevice, DiscoveryHandle, HttpChannel,
    Outbound, StatefulDevice,
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
/// learns nothing about this device. `DiscoveryHandle::discover` is not used
/// here because its client accepts any certificate.
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
            let result = client
                .register(
                    ProtocolType::Https,
                    &channel.host,
                    channel.port,
                    identity.register_dto(),
                )
                .await;
            Some((fingerprint, channel, result))
        });
    for (fingerprint, channel, result) in futures_util::future::join_all(probes)
        .await
        .into_iter()
        .flatten()
    {
        let reached = DeviceChannel::Http(channel.clone());
        match result {
            Ok(response) => {
                if discovery.report_outbound(&fingerprint, reached.clone(), Ok(())) {
                    continue;
                }
                // The device is not in the store yet, for example after a
                // restart. The core adds new devices only through discovery
                // or through requests they send to this server, so it is
                // added with `observe_inbound`. The core then sends its own
                // register request, also pinned, and `report_outbound` marks
                // the channel as reachable.
                let info = response.body;
                discovery
                    .observe_inbound(DiscoveredDevice {
                        alias: info.alias,
                        version: info.version,
                        device_model: info.device_model,
                        device_type: info.device_type,
                        fingerprint: fingerprint.clone(),
                        channel: reached.clone(),
                        download: info.download,
                    })
                    .await;
                discovery.report_outbound(&fingerprint, reached, Ok(()));
            }
            // A failed connection ranks the address lower. A device that
            // answered with an error status was reachable and is not reported.
            Err(error) if error.is_unreachable() => {
                discovery.report_outbound(&fingerprint, reached, Err(error.to_string()));
            }
            Err(_) => {}
        }
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
        last_seen_at: last_seen(device).map(format_system_time),
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

/// The time of the last request to or from the device over HTTPS.
/// Announcements and plain HTTP requests are ignored because anyone can send
/// them in the device's name.
fn last_seen(device: &StatefulDevice) -> Option<SystemTime> {
    device
        .logs
        .iter()
        .rev()
        .find(|log| match &log.event {
            DeviceLogEvent::Outbound { channel } | DeviceLogEvent::Inbound { channel } => {
                is_https(channel)
            }
            _ => false,
        })
        .map(|log| log.timestamp)
}

fn is_https(channel: &DeviceChannel) -> bool {
    channel
        .http()
        .is_some_and(|http| http.protocol == ProtocolType::Https)
}

/// A device is online when one of its HTTPS channels was used in either
/// direction within `ONLINE_TTL` and the last request this device sent over
/// it did not fail. Plain HTTP is ignored because its fingerprint is not
/// verified, so anyone could keep an absent device looking online.
pub(super) fn device_online(device: &StatefulDevice) -> bool {
    channels_online(&device.channels, SystemTime::now())
}

fn channels_online<'a>(
    channels: impl IntoIterator<Item = (&'a DeviceChannel, &'a ChannelState)>,
    now: SystemTime,
) -> bool {
    let recent = |at: SystemTime| now.duration_since(at).unwrap_or_default() <= ONLINE_TTL;
    channels.into_iter().any(|(channel, state)| {
        is_https(channel)
            && match state.outbound {
                Outbound::Failed(_) => false,
                Outbound::Reachable(at) => recent(at) || state.inbound.is_some_and(recent),
                Outbound::Untested => state.inbound.is_some_and(recent),
            }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn channel(protocol: ProtocolType) -> DeviceChannel {
        DeviceChannel::Http(HttpChannel {
            host: "192.168.1.20".to_string(),
            port: 53317,
            protocol,
        })
    }

    fn online(protocol: ProtocolType, outbound: Outbound, inbound: Option<SystemTime>) -> bool {
        let now = SystemTime::now();
        let channel = channel(protocol);
        let state = ChannelState { outbound, inbound };
        channels_online([(&channel, &state)], now)
    }

    #[test]
    fn online_needs_a_recent_https_exchange_that_did_not_fail() {
        let now = SystemTime::now();
        let old = now - ONLINE_TTL - Duration::from_secs(1);
        let https = ProtocolType::Https;

        assert!(online(https, Outbound::Reachable(now), None));
        assert!(online(https, Outbound::Untested, Some(now)));
        assert!(online(https, Outbound::Reachable(old), Some(now)));
        assert!(!online(https, Outbound::Reachable(old), None));
        assert!(!online(https, Outbound::Untested, Some(old)));
        assert!(!online(https, Outbound::Untested, None));
        // The last request to the device failed, so it cannot receive files.
        assert!(!online(https, Outbound::Failed(now), Some(now)));
        // Plain HTTP does not verify the fingerprint.
        assert!(!online(
            ProtocolType::Http,
            Outbound::Reachable(now),
            Some(now)
        ));
    }
}
