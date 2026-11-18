//! The Wayland clipboard through `wl-paste` and `wl-copy`.

use crate::files::MAX_TEXT_BYTES;
use crate::rpc::{ApiError, ApiResult};
use serde::Serialize;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;

const TIMEOUT: Duration = Duration::from_secs(5);

/// MIME type password managers (KeePassXC and others) offer next to a copied
/// secret.
const PASSWORD_HINT_TYPE: &str = "x-kde-passwordManagerHint";

/// What the panel shows before a clipboard send.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Preview {
    /// SHA-256 of the whole text; `send-clipboard --expect-sha256` takes it.
    pub sha256: String,
    pub preview: String,
    pub truncated: bool,
}

/// Reads the clipboard text for a preview: its hash and the first
/// characters, with control characters other than `\n` and `\t` removed.
pub async fn preview(chars: usize) -> ApiResult<Preview> {
    let text = read().await?;
    if text.is_empty() {
        return Err(ApiError::new("empty_text", "The clipboard holds no text"));
    }
    let mut characters = text.chars();
    let preview = characters
        .by_ref()
        .take(chars)
        .filter(|c| matches!(c, '\n' | '\t') || !c.is_control())
        .collect();
    Ok(Preview {
        sha256: localsend::crypto::hash::sha256_hex(text.as_bytes()),
        preview,
        truncated: characters.next().is_some(),
    })
}

/// Reads the clipboard as text, the same type the preview uses
/// (`wl-paste --type text`), so what is sent is what was shown. A secret
/// marked by a password manager is refused before it is read.
pub async fn read() -> ApiResult<String> {
    ensure_not_secret().await?;
    let mut child = Command::new("wl-paste")
        .args(["--no-newline", "--type", "text"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| unavailable("Could not execute wl-paste"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| unavailable("Could not read the clipboard"))?;
    let mut output = Vec::new();
    match tokio::time::timeout(
        TIMEOUT,
        stdout
            .take(MAX_TEXT_BYTES as u64 + 1)
            .read_to_end(&mut output),
    )
    .await
    {
        Err(_) => return Err(unavailable("Reading the clipboard timed out")),
        Ok(Err(_)) => return Err(unavailable("Could not read the clipboard")),
        Ok(Ok(_)) => {}
    }
    if output.len() > MAX_TEXT_BYTES {
        return Err(ApiError::new(
            "text_too_large",
            format!("Clipboard text is limited to {MAX_TEXT_BYTES} UTF-8 bytes"),
        ));
    }
    match tokio::time::timeout(Duration::from_secs(1), child.wait()).await {
        Ok(Ok(status)) if status.success() => {}
        Ok(Ok(_)) => return Err(unavailable("wl-paste could not read the clipboard")),
        Ok(Err(_)) => return Err(unavailable("wl-paste failed")),
        Err(_) => return Err(unavailable("wl-paste did not exit")),
    }
    String::from_utf8(output).map_err(|_| {
        ApiError::new(
            "clipboard_not_text",
            "Clipboard contents are not valid UTF-8 text",
        )
    })
}

/// Refuses a clipboard that a password manager marked as a secret.
async fn ensure_not_secret() -> ApiResult<()> {
    let output = tokio::time::timeout(
        TIMEOUT,
        Command::new("wl-paste")
            .arg("--list-types")
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(|_| unavailable("Reading the clipboard timed out"))?
    .map_err(|_| unavailable("Could not execute wl-paste"))?;
    if String::from_utf8_lossy(&output.stdout)
        .lines()
        .any(|line| line.trim() == PASSWORD_HINT_TYPE)
    {
        return Err(ApiError::new(
            "clipboard_secret",
            "The clipboard holds a password; it is not sent",
        ));
    }
    Ok(())
}

/// Compares the clipboard text with the SHA-256 the user confirmed in the
/// preview, so a clipboard that changed after the preview is not sent.
pub fn ensure_unchanged(text: &str, expected: &str) -> ApiResult<()> {
    let actual = localsend::crypto::hash::sha256_hex(text.as_bytes());
    if actual.eq_ignore_ascii_case(expected.trim()) {
        Ok(())
    } else {
        Err(ApiError::new(
            "clipboard_changed",
            "The clipboard changed after the preview; it is not sent",
        ))
    }
}

/// Puts received text on the clipboard as plain text. Without `--type`,
/// wl-copy would infer a type from the content, so text that looks like HTML
/// would be offered (and pasted) as HTML.
pub async fn copy(text: &str) -> ApiResult<()> {
    let mut child = Command::new("wl-copy")
        .args(["--type", "text/plain;charset=utf-8"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| unavailable("Could not execute wl-copy"))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| unavailable("Could not write the clipboard"))?;
    let result = tokio::time::timeout(TIMEOUT, async {
        stdin.write_all(text.as_bytes()).await?;
        stdin.shutdown().await?;
        drop(stdin);
        child.wait().await
    })
    .await;
    match result {
        Ok(Ok(status)) if status.success() => Ok(()),
        Ok(Ok(_)) => Err(unavailable("wl-copy could not write the clipboard")),
        Ok(Err(_)) => Err(unavailable("Could not write the clipboard")),
        Err(_) => Err(unavailable("Writing the clipboard timed out")),
    }
}

fn unavailable(message: &str) -> ApiError {
    ApiError::new("clipboard_unavailable", message)
}
