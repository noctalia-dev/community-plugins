//! Checks on what a peer sends: its device info, the offered files and an
//! embedded text message.

use crate::files::{is_invisible_format, MAX_TEXT_BYTES};
use crate::rpc::{ApiError, ApiResult};
use localsend::http::dto_v2::RegisterDtoV2;
use localsend::model::transfer::FileDto;
use std::collections::HashMap;
use uuid::Uuid;

const MAX_INCOMING_FILES: usize = 512;
const MAX_INCOMING_NAME_BYTES: usize = 1024;
const MAX_INCOMING_METADATA_BYTES: usize = 512 * 1024;
const MAX_REMOTE_FIELD_BYTES: usize = 256;
const MAX_MESSAGE_PREVIEW_CHARS: usize = 4096;

/// Validates an incoming offer and returns its total size in bytes.
pub(super) fn validate_incoming_offer(files: &HashMap<String, FileDto>) -> ApiResult<u64> {
    if files.is_empty() || files.len() > MAX_INCOMING_FILES {
        return Err(ApiError::new(
            "invalid_offer",
            format!("Incoming request must contain 1 to {MAX_INCOMING_FILES} files"),
        ));
    }
    let mut total = 0u64;
    let mut metadata_bytes = 0usize;
    for (id, file) in files {
        validate_file_id(id)?;
        if file.id != *id {
            return Err(ApiError::new(
                "invalid_offer",
                "Incoming file ID does not match its map key",
            ));
        }
        if file.file_name.is_empty()
            || file.file_name.len() > MAX_INCOMING_NAME_BYTES
            || file.file_name.chars().any(char::is_control)
        {
            return Err(ApiError::new(
                "invalid_offer",
                "Incoming file name is invalid or too long",
            ));
        }
        if file.file_type.len() > MAX_REMOTE_FIELD_BYTES
            || file.file_type.chars().any(char::is_control)
        {
            return Err(ApiError::new(
                "invalid_offer",
                "Incoming file type is invalid or too long",
            ));
        }
        if file
            .preview
            .as_ref()
            .is_some_and(|preview| preview.len() > MAX_TEXT_BYTES)
        {
            return Err(ApiError::new(
                "invalid_offer",
                "Incoming text preview is too large",
            ));
        }
        metadata_bytes = metadata_bytes
            .checked_add(id.len() + file.file_name.len() + file.file_type.len())
            .and_then(|value| value.checked_add(file.preview.as_ref().map_or(0, String::len)))
            .ok_or_else(|| ApiError::new("invalid_offer", "Incoming metadata overflowed"))?;
        if metadata_bytes > MAX_INCOMING_METADATA_BYTES {
            return Err(ApiError::new(
                "invalid_offer",
                "Incoming transfer metadata is too large",
            ));
        }
        total = total
            .checked_add(file.size)
            .ok_or_else(|| ApiError::new("invalid_offer", "Incoming byte count overflowed"))?;
    }
    Ok(total)
}

pub(super) fn validate_sender_info(info: &RegisterDtoV2) -> ApiResult<()> {
    for (label, value) in [
        ("alias", info.alias.as_str()),
        ("version", info.version.as_str()),
        ("fingerprint", info.fingerprint.as_str()),
    ] {
        if value.is_empty()
            || value.len() > MAX_REMOTE_FIELD_BYTES
            || value
                .chars()
                .any(|c| c.is_control() || is_invisible_format(c))
        {
            return Err(ApiError::new(
                "invalid_sender",
                format!("Sender {label} is invalid or too long"),
            ));
        }
    }
    if info.device_model.as_ref().is_some_and(|model| {
        model.len() > MAX_REMOTE_FIELD_BYTES
            || model
                .chars()
                .any(|c| c.is_control() || is_invisible_format(c))
    }) {
        return Err(ApiError::new(
            "invalid_sender",
            "Sender device model is invalid or too long",
        ));
    }
    Ok(())
}

fn validate_file_id(value: &str) -> ApiResult<()> {
    if value.is_empty()
        || value.len() > MAX_REMOTE_FIELD_BYTES
        || value.chars().any(char::is_control)
    {
        return Err(ApiError::new(
            "invalid_offer",
            "Incoming file ID is invalid or too long",
        ));
    }
    Ok(())
}

pub(super) fn validate_current_request(current: Option<&str>, provided: &str) -> ApiResult<()> {
    validate_uuid(provided, "request")?;
    if current != Some(provided) {
        return Err(stale_request());
    }
    Ok(())
}

pub(super) fn stale_request() -> ApiError {
    ApiError::new("stale_request", "Incoming request is no longer pending")
}

pub(super) fn validate_uuid(value: &str, kind: &str) -> ApiResult<()> {
    Uuid::parse_str(value)
        .map_err(|_| ApiError::new("invalid_id", format!("{kind} ID must be a valid UUID")))?;
    Ok(())
}

pub(super) fn validate_fingerprint(value: &str) -> ApiResult<()> {
    if value.is_empty()
        || value.len() > 256
        || value.chars().any(|character| character.is_control())
    {
        return Err(ApiError::new(
            "invalid_fingerprint",
            "Device fingerprint is invalid",
        ));
    }
    Ok(())
}

/// The preview shown for an incoming text message. Only an embedded message
/// gets one: a text file whose preview differs from its content would
/// otherwise look like a message while accepting it saves the file.
pub(super) fn message_preview(files: &HashMap<String, FileDto>) -> (Option<String>, bool) {
    let Some(preview) = embedded_message(files) else {
        return (None, false);
    };
    let preview = sanitize_message(preview);
    let mut characters = preview.chars();
    let shortened: String = characters
        .by_ref()
        .take(MAX_MESSAGE_PREVIEW_CHARS)
        .collect();
    let truncated = characters.next().is_some();
    (Some(shortened), truncated)
}

pub(super) fn embedded_message(files: &HashMap<String, FileDto>) -> Option<&str> {
    if files.len() != 1 {
        return None;
    }
    let file = files.values().next()?;
    if (!file.file_type.starts_with("text/") && file.file_type != "text") || file.size == 0 {
        return None;
    }
    let preview = file.preview.as_deref()?;
    (preview.len() as u64 == file.size).then_some(preview)
}

/// Text as it is shown and copied: line breaks normalized to `\n`, and
/// control characters other than `\n`/`\t` (terminal escapes, a bracketed
/// paste terminator), bidirectional controls and zero-width characters
/// removed, so pasting it into a terminal runs nothing the preview did not
/// show.
pub(super) fn sanitize_message(text: &str) -> String {
    text.replace("\r\n", "\n")
        .chars()
        .filter(|character| {
            matches!(character, '\n' | '\t')
                || !(character.is_control() || is_invisible_format(*character))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};

    #[test]
    fn stale_request_ids_are_rejected() {
        let current = "550e8400-e29b-41d4-a716-446655440000";
        let stale = "550e8400-e29b-41d4-a716-446655440001";
        assert!(validate_current_request(Some(current), current).is_ok());
        assert_eq!(
            validate_current_request(Some(current), stale)
                .unwrap_err()
                .code,
            "stale_request"
        );
        assert_eq!(
            validate_current_request(None, current).unwrap_err().code,
            "stale_request"
        );
        assert_eq!(
            validate_current_request(Some(current), "not-a-uuid")
                .unwrap_err()
                .code,
            "invalid_id"
        );
    }

    fn text_file(name: &str, size: u64, preview: &str) -> HashMap<String, FileDto> {
        HashMap::from([(
            "file-a".to_string(),
            FileDto {
                id: "file-a".to_string(),
                file_name: name.to_string(),
                size,
                file_type: "text/plain".to_string(),
                sha256: None,
                preview: Some(preview.to_string()),
                metadata: None,
            },
        )])
    }

    #[test]
    fn accepts_opaque_file_ids_and_identifies_only_complete_embedded_text() {
        let mut files = text_file("message.txt", 5, "hello");
        assert_eq!(validate_incoming_offer(&files).unwrap(), 5);
        assert_eq!(embedded_message(&files), Some("hello"));

        files.get_mut("file-a").unwrap().size = 6;
        assert_eq!(embedded_message(&files), None);
    }

    #[test]
    fn rejects_offers_whose_size_overflows() {
        let mut files = text_file("a.txt", u64::MAX, "a");
        let mut second = files["file-a"].clone();
        second.id = "file-b".to_string();
        files.insert("file-b".to_string(), second);
        assert_eq!(
            validate_incoming_offer(&files).unwrap_err().code,
            "invalid_offer"
        );
    }

    #[test]
    fn previews_only_embedded_messages() {
        let mut files = text_file("notes.desktop", 4096, "harmless");
        assert_eq!(message_preview(&files), (None, false));

        files.get_mut("file-a").unwrap().size = 8;
        assert_eq!(
            message_preview(&files),
            (Some("harmless".to_string()), false)
        );
    }

    #[test]
    fn sanitizes_message_control_characters() {
        assert_eq!(
            sanitize_message("a\r\nb\tc\u{1b}[201~d\re\u{7f}\u{9b}f\u{202E}g\u{2066}h"),
            "a\nb\tc[201~defgh"
        );
        assert_eq!(sanitize_message("x\u{200F}y\u{200B}z\u{061C}"), "xyz");
    }

    fn sender(alias: &str, model: Option<&str>) -> RegisterDtoV2 {
        RegisterDtoV2 {
            alias: alias.to_string(),
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: model.map(str::to_string),
            device_type: Some(DeviceType::Mobile),
            fingerprint: "ABC123".to_string(),
            port: 53317,
            protocol: ProtocolType::Https,
            download: false,
        }
    }

    #[test]
    fn rejects_invisible_formatting_in_sender_info() {
        assert!(validate_sender_info(&sender("Phone", Some("Pixel"))).is_ok());
        assert!(validate_sender_info(&sender("Pho\u{202E}ne", None)).is_err());
        assert!(validate_sender_info(&sender("Phone", Some("Pi\u{200B}xel"))).is_err());
    }
}
