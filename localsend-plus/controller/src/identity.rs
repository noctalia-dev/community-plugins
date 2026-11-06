use anyhow::{Context, Result};
use localsend::crypto::cert::fingerprint_from_cert_der;
use localsend::http::dto_v2::RegisterDtoV2;
use localsend::http::server::TlsConfig;
use localsend::http::state::ClientInfo;
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use localsend::multicast::MulticastDevice;
use rcgen::PublicKeyData;
use std::fs;
use std::io::{ErrorKind, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;

const MAX_IDENTITY_BYTES: u64 = 128 * 1024;

#[derive(Clone)]
pub struct Identity {
    pub alias: String,
    pub device_model: String,
    pub port: u16,
    pub cert_pem: String,
    pub key_pem: String,
    pub fingerprint: String,
}

impl Identity {
    pub fn load_or_generate(
        dir: &Path,
        alias: Option<String>,
        device_model: String,
        port: u16,
    ) -> Result<Self> {
        fs::create_dir_all(dir)
            .with_context(|| format!("Could not create state directory {}", dir.display()))?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
            .with_context(|| format!("Could not secure state directory {}", dir.display()))?;
        let alias = resolve_alias(dir, alias)?;

        let path = dir.join("identity.pem");
        match fs::symlink_metadata(&path) {
            Ok(metadata) => {
                anyhow::ensure!(
                    metadata.file_type().is_file(),
                    "Identity path is not a file"
                );
                anyhow::ensure!(
                    metadata.len() <= MAX_IDENTITY_BYTES,
                    "Identity file is too large"
                );
                fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
                    .context("Could not secure identity file")?;
                let text = fs::read_to_string(&path).context("Could not read identity file")?;
                Self::from_pem(&text, alias, device_model, port).context(
                    "Invalid identity file; remove it to generate a new LocalSend identity",
                )
            }
            Err(error) if error.kind() == ErrorKind::NotFound => {
                let identity = Self::generate(alias, device_model, port)?;
                identity.save(&path)?;
                Ok(identity)
            }
            Err(error) => Err(error).context("Could not inspect identity file"),
        }
    }

    fn from_pem(text: &str, alias: String, device_model: String, port: u16) -> Result<Self> {
        let blocks = pem::parse_many(text)?;
        let cert = blocks
            .iter()
            .find(|block| block.tag() == "CERTIFICATE")
            .context("missing certificate")?;
        let key = blocks
            .iter()
            .find(|block| block.tag().ends_with("PRIVATE KEY"))
            .context("missing private key")?;
        let key_pem = pem::encode(key);
        let key_pair = rcgen::KeyPair::from_pem(&key_pem).context("unusable private key")?;
        anyhow::ensure!(
            key_matches_certificate(&key_pair, cert.contents()),
            "the private key does not belong to the certificate"
        );

        Ok(Self {
            alias,
            device_model,
            port,
            cert_pem: pem::encode(cert),
            key_pem,
            fingerprint: fingerprint_from_cert_der(cert.contents()),
        })
    }

    fn generate(alias: String, device_model: String, port: u16) -> Result<Self> {
        let generated = localsend::crypto::cert::generate_self_signed()?;
        Ok(Self {
            alias,
            device_model,
            port,
            cert_pem: generated.certificate_pem,
            key_pem: generated.private_key_pem,
            fingerprint: generated.fingerprint,
        })
    }

    fn save(&self, path: &Path) -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(path)
            .context("Could not create identity file")?;
        file.write_all(self.cert_pem.as_bytes())?;
        file.write_all(self.key_pem.as_bytes())?;
        file.sync_all()?;
        Ok(())
    }

    pub fn tls_config(&self) -> TlsConfig {
        TlsConfig {
            cert: self.cert_pem.clone(),
            private_key: self.key_pem.clone(),
        }
    }

    pub fn client_info(&self) -> ClientInfo {
        ClientInfo {
            alias: self.alias.clone(),
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: Some(self.device_model.clone()),
            device_type: Some(DeviceType::Desktop),
            token: self.fingerprint.clone(),
        }
    }

    pub fn register_dto(&self) -> RegisterDtoV2 {
        RegisterDtoV2 {
            alias: self.alias.clone(),
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: Some(self.device_model.clone()),
            device_type: Some(DeviceType::Desktop),
            fingerprint: self.fingerprint.clone(),
            port: self.port,
            protocol: ProtocolType::Https,
            download: false,
        }
    }

    pub fn multicast_device(&self) -> MulticastDevice {
        MulticastDevice {
            alias: self.alias.clone(),
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: Some(self.device_model.clone()),
            device_type: Some(DeviceType::Desktop),
            fingerprint: self.fingerprint.clone(),
            port: self.port,
            protocol: ProtocolType::Https,
            download: false,
        }
    }
}

/// The model other devices show under the alias: the override, else the
/// distribution name from os-release, else "Linux".
pub fn resolve_device_model(override_model: Option<String>) -> Result<String> {
    if let Some(model) = override_model {
        validate_device_model(&model)?;
        return Ok(model);
    }
    Ok(["/etc/os-release", "/usr/lib/os-release"]
        .iter()
        .find_map(|path| fs::read_to_string(path).ok())
        .and_then(|text| os_release_name(&text))
        .unwrap_or_else(|| "Linux".to_string()))
}

/// The `NAME` field of an os-release file, unquoted.
fn os_release_name(text: &str) -> Option<String> {
    let value = text.lines().find_map(|line| line.strip_prefix("NAME="))?;
    let name = value.trim().trim_matches(['"', '\'']).trim().to_string();
    validate_device_model(&name).ok()?;
    Some(name)
}

fn validate_device_model(model: &str) -> Result<()> {
    anyhow::ensure!(!model.trim().is_empty(), "Device model must not be empty");
    anyhow::ensure!(model.chars().count() <= 64, "Device model is too long");
    anyhow::ensure!(
        !model.chars().any(char::is_control),
        "Device model contains control characters"
    );
    Ok(())
}

fn validate_alias(alias: &str) -> Result<()> {
    anyhow::ensure!(!alias.trim().is_empty(), "Alias must not be empty");
    anyhow::ensure!(alias.chars().count() <= 128, "Alias is too long");
    anyhow::ensure!(
        !alias.chars().any(char::is_control),
        "Alias contains control characters"
    );
    Ok(())
}

const ALIAS_ADJECTIVES: [&str; 24] = [
    "Bright", "Calm", "Clever", "Cool", "Cosy", "Curious", "Fast", "Fresh", "Gentle", "Golden",
    "Happy", "Kind", "Lively", "Lucky", "Mellow", "Nimble", "Quiet", "Rapid", "Shiny", "Silent",
    "Smart", "Sunny", "Swift", "Witty",
];

const ALIAS_NOUNS: [&str; 24] = [
    "Apple",
    "Apricot",
    "Avocado",
    "Banana",
    "Cherry",
    "Coconut",
    "Fig",
    "Grape",
    "Kiwi",
    "Lemon",
    "Lime",
    "Lychee",
    "Mango",
    "Melon",
    "Olive",
    "Orange",
    "Papaya",
    "Peach",
    "Pear",
    "Plum",
    "Pumpkin",
    "Quince",
    "Raspberry",
    "Tomato",
];

/// The name shown to other devices: the one given, else the one picked on
/// the first start and kept in `alias` in the state directory. A random
/// name like the LocalSend app's keeps the host name off the network.
fn resolve_alias(dir: &Path, given: Option<String>) -> Result<String> {
    if let Some(alias) = given {
        validate_alias(&alias)?;
        return Ok(alias);
    }
    let path = dir.join("alias");
    match fs::symlink_metadata(&path) {
        Ok(metadata) if metadata.file_type().is_file() && metadata.len() <= 512 => {
            let alias = fs::read_to_string(&path).context("Could not read the saved alias")?;
            let alias = alias.trim().to_string();
            if validate_alias(&alias).is_ok() {
                return Ok(alias);
            }
        }
        Ok(_) => anyhow::bail!("Alias path is not a small file"),
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => return Err(error).context("Could not inspect the saved alias"),
    }
    let alias = random_alias();
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)
        .context("Could not save the alias")?;
    file.write_all(alias.as_bytes())?;
    Ok(alias)
}

fn random_alias() -> String {
    let bytes = uuid::Uuid::new_v4().into_bytes();
    format!(
        "{} {}",
        ALIAS_ADJECTIVES[bytes[0] as usize % ALIAS_ADJECTIVES.len()],
        ALIAS_NOUNS[bytes[1] as usize % ALIAS_NOUNS.len()]
    )
}

/// Whether the certificate carries the public key of this key pair: its
/// SubjectPublicKeyInfo appears verbatim in the certificate's DER.
fn key_matches_certificate(key: &rcgen::KeyPair, cert_der: &[u8]) -> bool {
    let spki = key.subject_public_key_info();
    !spki.is_empty() && cert_der.windows(spki.len()).any(|window| window == spki)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_name_from_os_release() {
        let fedora = "NAME=\"Fedora Linux\"\nVERSION=\"44 (Workstation Edition)\"\nID=fedora\n";
        assert_eq!(os_release_name(fedora).as_deref(), Some("Fedora Linux"));
        assert_eq!(
            os_release_name("ID=arch\nNAME='Arch Linux'\n").as_deref(),
            Some("Arch Linux")
        );
        assert_eq!(os_release_name("PRETTY_NAME=\"Debian\"\n"), None);
        assert_eq!(os_release_name("NAME=\"\"\n"), None);
        assert!(resolve_device_model(Some("x".repeat(65))).is_err());
        assert_eq!(resolve_device_model(Some("NixOS".into())).unwrap(), "NixOS");
    }

    #[test]
    fn picks_a_random_alias_once_and_keeps_it() {
        let dir = tempfile::tempdir().unwrap();
        let first = resolve_alias(dir.path(), None).unwrap();
        assert_eq!(first.split(' ').count(), 2);
        assert_eq!(resolve_alias(dir.path(), None).unwrap(), first);
        assert_eq!(
            resolve_alias(dir.path(), Some("Desk".into())).unwrap(),
            "Desk"
        );
        assert!(resolve_alias(dir.path(), Some(" ".into())).is_err());
    }

    #[test]
    fn rejects_a_key_from_another_identity() {
        let a = localsend::crypto::cert::generate_self_signed().unwrap();
        let b = localsend::crypto::cert::generate_self_signed().unwrap();
        let mixed = format!("{}{}", a.certificate_pem, b.private_key_pem);
        assert!(Identity::from_pem(&mixed, "x".into(), "y".into(), 1).is_err());
        let own = format!("{}{}", a.certificate_pem, a.private_key_pem);
        assert!(Identity::from_pem(&own, "x".into(), "y".into(), 1).is_ok());
    }
}
