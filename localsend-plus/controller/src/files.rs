use crate::rpc::{ApiError, ApiResult};
use localsend::model::transfer::{FileDto, FileMetadata};
use localsend::util::filename::{self, Rules};
use std::fs;
use std::io::ErrorKind;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use uuid::Uuid;

const MAX_SELECTED_ROOTS: usize = 256;
const MAX_SELECTED_FILES: usize = 512;
const MAX_VISITED_ENTRIES: usize = 10_000;
const MAX_RECURSION_DEPTH: usize = 16;
pub const MAX_TEXT_BYTES: usize = 512 * 1024;
/// Longest peer name or model shown, as long as this device's own alias may be.
const MAX_SHOWN_CHARS: usize = 128;

#[derive(Clone)]
pub enum OutgoingSource {
    Path {
        path: PathBuf,
        device: u64,
        inode: u64,
        size: u64,
    },
    Bytes(Arc<Vec<u8>>),
}

#[derive(Clone)]
pub struct OutgoingItem {
    pub file: FileDto,
    pub source: OutgoingSource,
    pub source_path: Option<String>,
}

pub fn collect_selection(paths: &[String]) -> ApiResult<Vec<OutgoingItem>> {
    if paths.is_empty() {
        return Err(ApiError::new(
            "invalid_path",
            "At least one path is required",
        ));
    }
    if paths.len() > MAX_SELECTED_ROOTS {
        return Err(ApiError::new(
            "selection_too_large",
            format!("At most {MAX_SELECTED_ROOTS} root paths may be selected"),
        ));
    }

    let mut items = Vec::new();
    let mut visited = 0;
    for raw in paths {
        let path = PathBuf::from(raw);
        if !path.is_absolute() {
            return Err(ApiError::new(
                "invalid_path",
                format!("Path must be absolute: {raw}"),
            ));
        }
        let metadata = fs::symlink_metadata(&path).map_err(|error| path_error(&path, error))?;
        if metadata.file_type().is_symlink() {
            return Err(ApiError::new(
                "invalid_path",
                format!("Symbolic links are not accepted: {}", path.display()),
            ));
        }
        if metadata.is_file() {
            let name = safe_local_component(path.file_name(), &path)?;
            push_file(&path, name, metadata, &mut items)?;
        } else if metadata.is_dir() {
            let root = safe_local_component(path.file_name(), &path)?;
            collect_directory(&path, &root, 0, &mut visited, &mut items)?;
        } else {
            return Err(ApiError::new(
                "invalid_path",
                format!(
                    "Path is not a regular file or directory: {}",
                    path.display()
                ),
            ));
        }
    }

    if items.is_empty() {
        return Err(ApiError::new(
            "empty_selection",
            "The selected directories contain no regular files",
        ));
    }
    Ok(items)
}

pub fn text_item(text: String) -> ApiResult<OutgoingItem> {
    if text.is_empty() {
        return Err(ApiError::new("empty_text", "Text must not be empty"));
    }
    if text.len() > MAX_TEXT_BYTES {
        return Err(ApiError::new(
            "text_too_large",
            format!("Text is limited to {MAX_TEXT_BYTES} UTF-8 bytes"),
        ));
    }

    let id = Uuid::new_v4().to_string();
    let name = format!("{id}.txt");
    let bytes = text.into_bytes();
    Ok(OutgoingItem {
        file: FileDto {
            id: id.clone(),
            file_name: name,
            size: bytes.len() as u64,
            file_type: "text/plain".to_string(),
            sha256: None,
            preview: Some(String::from_utf8_lossy(&bytes).into_owned()),
            metadata: None,
        },
        source: OutgoingSource::Bytes(Arc::new(bytes)),
        source_path: None,
    })
}

fn collect_directory(
    directory: &Path,
    relative: &str,
    depth: usize,
    visited: &mut usize,
    items: &mut Vec<OutgoingItem>,
) -> ApiResult<()> {
    if depth >= MAX_RECURSION_DEPTH {
        return Err(ApiError::new(
            "selection_too_deep",
            format!("Directory nesting exceeds {MAX_RECURSION_DEPTH} levels"),
        ));
    }

    let mut entries = Vec::new();
    for entry in fs::read_dir(directory).map_err(|error| path_error(directory, error))? {
        *visited += 1;
        if *visited > MAX_VISITED_ENTRIES {
            return Err(ApiError::new(
                "selection_too_large",
                format!("Selection may contain at most {MAX_VISITED_ENTRIES} directory entries"),
            ));
        }
        entries.push(entry.map_err(|error| path_error(directory, error))?);
    }
    entries.sort_by_key(|entry| entry.file_name());

    for entry in entries {
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path).map_err(|error| path_error(&path, error))?;
        if metadata.file_type().is_symlink() {
            return Err(ApiError::new(
                "invalid_path",
                format!("Symbolic links are not accepted: {}", path.display()),
            ));
        }
        let component = safe_local_component(Some(&entry.file_name()), &path)?;
        let child_relative = format!("{relative}/{component}");
        if metadata.is_dir() {
            collect_directory(&path, &child_relative, depth + 1, visited, items)?;
        } else if metadata.is_file() {
            push_file(&path, child_relative, metadata, items)?;
        } else {
            return Err(ApiError::new(
                "invalid_path",
                format!("Special files are not accepted: {}", path.display()),
            ));
        }
    }
    Ok(())
}

fn push_file(
    path: &Path,
    relative_name: String,
    metadata: fs::Metadata,
    items: &mut Vec<OutgoingItem>,
) -> ApiResult<()> {
    if items.len() >= MAX_SELECTED_FILES {
        return Err(ApiError::new(
            "selection_too_large",
            format!("At most {MAX_SELECTED_FILES} files may be sent at once"),
        ));
    }
    let source_path = path.to_str().ok_or_else(|| {
        ApiError::new(
            "invalid_path",
            format!("Path is not valid UTF-8: {}", path.display()),
        )
    })?;
    let id = Uuid::new_v4().to_string();
    items.push(OutgoingItem {
        file: FileDto {
            id: id.clone(),
            file_name: relative_name,
            size: metadata.len(),
            file_type: mime_guess::from_path(path)
                .first_or_octet_stream()
                .to_string(),
            sha256: None,
            preview: None,
            metadata: FileMetadata::from_fs_metadata(&metadata),
        },
        source: OutgoingSource::Path {
            path: path.to_path_buf(),
            device: metadata.dev(),
            inode: metadata.ino(),
            size: metadata.len(),
        },
        source_path: Some(source_path.to_string()),
    });
    Ok(())
}

fn safe_local_component(name: Option<&std::ffi::OsStr>, path: &Path) -> ApiResult<String> {
    let name = name.and_then(std::ffi::OsStr::to_str).ok_or_else(|| {
        ApiError::new("invalid_path", format!("Invalid path: {}", path.display()))
    })?;
    Ok(filename::sanitize(name, Rules::Universal))
}

fn path_error(path: &Path, error: std::io::Error) -> ApiError {
    ApiError::new(
        "invalid_path",
        format!("Could not inspect {}: {error}", path.display()),
    )
}

/// The last component of a path, for messages.
pub fn display_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string())
}

/// A byte count in B, KB, MB, GB or TB (base 1024), like the plugin shows it.
pub fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

/// Invisible formatting characters: bidirectional controls and zero-width
/// characters. They are not control characters (`char::is_control`), yet a
/// right-to-left override can make `invoice\u{202E}fdp.sh` read as
/// `invoicehs.pdf`, so peer-supplied names and aliases must not carry them.
pub fn is_invisible_format(c: char) -> bool {
    matches!(
        c,
        '\u{061C}'
            | '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'
            | '\u{2066}'..='\u{2069}'
            | '\u{FEFF}'
    )
}

/// A peer-supplied name with invisible formatting characters replaced by `_`.
pub fn replace_invisible(name: &str) -> String {
    name.chars()
        .map(|c| if is_invisible_format(c) { '_' } else { c })
        .collect()
}

/// Peer-supplied text as it may be shown: without control characters
/// (terminal escapes, NUL) and invisible formatting, at most
/// [`MAX_SHOWN_CHARS`] characters, and `?` when nothing visible is left.
pub fn display_text(text: &str) -> String {
    let shown: String = text
        .chars()
        .filter(|&c| !c.is_control() && !is_invisible_format(c))
        .take(MAX_SHOWN_CHARS)
        .collect();
    if shown.trim().is_empty() {
        "?".to_string()
    } else {
        shown
    }
}

pub fn sanitize_relative_name(name: &str) -> ApiResult<Vec<String>> {
    if name.len() > 4096 {
        return Err(ApiError::new("unsafe_file_name", "File name is too long"));
    }
    if name.starts_with('/')
        || name.starts_with('\\')
        || name
            .as_bytes()
            .get(1)
            .is_some_and(|byte| *byte == b':' && name.as_bytes()[0].is_ascii_alphabetic())
    {
        return Err(ApiError::new(
            "unsafe_file_name",
            "Absolute file names are not accepted",
        ));
    }

    let mut components = Vec::new();
    for component in name.split(['/', '\\']) {
        match component {
            "" | "." => continue,
            ".." => {
                return Err(ApiError::new(
                    "unsafe_file_name",
                    "Parent path components are not accepted",
                ));
            }
            component => components.push(filename::sanitize(
                &replace_invisible(component),
                Rules::current(),
            )),
        }
        if components.len() > MAX_RECURSION_DEPTH {
            return Err(ApiError::new(
                "unsafe_file_name",
                "File path contains too many components",
            ));
        }
    }
    if components.is_empty() {
        components.push(filename::sanitize("", Rules::current()));
    }
    Ok(components)
}

/// Creates an empty file for `name` under `destination` and returns its
/// path. Directories it had to create are added to `created`, so a
/// cancelled transfer can remove them again.
pub fn reserve_unique_destination(
    destination: &Path,
    name: &str,
    created: &mut Vec<PathBuf>,
) -> ApiResult<PathBuf> {
    let components = sanitize_relative_name(name)?;
    let mut directory = destination.to_path_buf();
    for component in components.iter().take(components.len() - 1) {
        directory.push(component);
        if ensure_directory_component(destination, &directory)? {
            created.push(directory.clone());
        }
    }

    let base = components
        .last()
        .expect("sanitizer always returns a component");
    for index in 0..10_000u32 {
        let candidate_name = if index == 0 {
            base.clone()
        } else {
            counted_name(base, index)
        };
        let candidate = directory.join(candidate_name);
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&candidate)
        {
            Ok(_) => return Ok(candidate),
            Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(ApiError::new(
                    "destination_error",
                    format!("Could not reserve {}: {error}", candidate.display()),
                ));
            }
        }
    }
    Err(ApiError::new(
        "destination_error",
        format!("Could not find a unique name for {base}"),
    ))
}

/// Makes sure `directory` is a real directory inside `root`; true when it
/// had to be created.
fn ensure_directory_component(root: &Path, directory: &Path) -> ApiResult<bool> {
    let created = match fs::symlink_metadata(directory) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            return Err(ApiError::new(
                "unsafe_destination",
                format!(
                    "Destination contains a symbolic link: {}",
                    directory.display()
                ),
            ));
        }
        Ok(metadata) if !metadata.is_dir() => {
            return Err(ApiError::new(
                "destination_error",
                format!(
                    "Destination component is not a directory: {}",
                    directory.display()
                ),
            ));
        }
        Ok(_) => false,
        Err(error) if error.kind() == ErrorKind::NotFound => {
            fs::create_dir(directory).map_err(|error| {
                ApiError::new(
                    "destination_error",
                    format!("Could not create {}: {error}", directory.display()),
                )
            })?;
            true
        }
        Err(error) => {
            return Err(ApiError::new(
                "destination_error",
                format!("Could not inspect {}: {error}", directory.display()),
            ));
        }
    };

    let canonical = fs::canonicalize(directory).map_err(|error| {
        ApiError::new(
            "destination_error",
            format!("Could not resolve {}: {error}", directory.display()),
        )
    })?;
    if !canonical.starts_with(root) {
        return Err(ApiError::new(
            "unsafe_destination",
            "Destination path escapes the download directory",
        ));
    }
    Ok(created)
}

fn counted_name(name: &str, index: u32) -> String {
    match name.rsplit_once('.') {
        Some((stem, extension)) if !stem.is_empty() => {
            format!("{stem} ({index}).{extension}")
        }
        _ => format!("{name} ({index})"),
    }
}

/// Removes reserved files, then the directories created for them that are
/// empty now, deepest first.
pub fn remove_reservations(files: impl IntoIterator<Item = PathBuf>, directories: &[PathBuf]) {
    for path in files {
        let _ = fs::remove_file(path);
    }
    remove_empty_directories(directories);
}

/// Removes the directories that are empty, deepest first; the others stay.
pub fn remove_empty_directories(directories: &[PathBuf]) {
    for directory in directories.iter().rev() {
        let _ = fs::remove_dir(directory);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn sanitizes_relative_names_and_rejects_escape_attempts() {
        assert_eq!(
            sanitize_relative_name("outer/inner/file.txt").unwrap(),
            ["outer", "inner", "file.txt"]
        );
        assert_eq!(sanitize_relative_name("a/./b.txt").unwrap(), ["a", "b.txt"]);
        assert!(sanitize_relative_name("../outside.txt").is_err());
        assert!(sanitize_relative_name("a\\..\\outside.txt").is_err());
        assert!(sanitize_relative_name("/etc/passwd").is_err());
        assert!(sanitize_relative_name("C:\\Windows\\file.txt").is_err());
    }

    #[test]
    fn formats_sizes_like_the_plugin() {
        assert_eq!(format_bytes(512), "512 B");
        assert_eq!(format_bytes(2 * 1024 * 1024 + 512 * 1024), "2.5 MB");
        assert_eq!(display_name("/tmp/album/"), "album");
        assert_eq!(display_name("raport.pdf"), "raport.pdf");
    }

    #[test]
    fn replaces_invisible_formatting_in_names() {
        assert_eq!(
            sanitize_relative_name("dir\u{2066}/invoice\u{202E}fdp.sh").unwrap(),
            ["dir_", "invoice_fdp.sh"]
        );
        assert_eq!(replace_invisible("a\u{200B}b\u{FEFF}"), "a_b_");
        assert!(!is_invisible_format('ą'));
    }

    #[test]
    fn display_text_drops_escapes_and_invisible_formatting() {
        assert_eq!(
            display_text("Pho\u{1b}]52;c;aGk=\u{7}ne\u{202E}\0"),
            "Pho]52;c;aGk=ne"
        );
        assert_eq!(display_text(&"ą".repeat(200)), "ą".repeat(MAX_SHOWN_CHARS));
        assert_eq!(display_text("\u{1b}\u{200B} "), "?");
    }

    #[test]
    fn reserves_unique_destinations_atomically() {
        let temp = tempfile::tempdir().unwrap();
        let destination = fs::canonicalize(temp.path()).unwrap();
        fs::write(destination.join("report.txt"), b"existing").unwrap();

        let mut created = Vec::new();
        let first = reserve_unique_destination(&destination, "report.txt", &mut created).unwrap();
        let second = reserve_unique_destination(&destination, "report.txt", &mut created).unwrap();
        assert!(created.is_empty());
        assert_eq!(first.file_name().unwrap(), "report (1).txt");
        assert_eq!(second.file_name().unwrap(), "report (2).txt");
        assert!(first.exists());
        assert!(second.exists());
    }

    #[test]
    fn removing_reservations_also_removes_the_folders_they_needed() {
        let temp = tempfile::tempdir().unwrap();
        let destination = fs::canonicalize(temp.path()).unwrap();
        fs::create_dir(destination.join("kept")).unwrap();
        let mut created = Vec::new();
        let files = vec![
            reserve_unique_destination(&destination, "album/sub/a.txt", &mut created).unwrap(),
            reserve_unique_destination(&destination, "kept/b.txt", &mut created).unwrap(),
        ];
        assert_eq!(
            created,
            [destination.join("album"), destination.join("album/sub")]
        );

        remove_reservations(files, &created);
        assert!(!destination.join("album").exists());
        assert!(destination.join("kept").is_dir());
    }

    #[test]
    fn recursive_selection_preserves_safe_folder_names() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("picked");
        fs::create_dir_all(root.join("sub")).unwrap();
        fs::File::create(root.join("a.txt"))
            .unwrap()
            .write_all(b"a")
            .unwrap();
        fs::File::create(root.join("sub/b.txt"))
            .unwrap()
            .write_all(b"bb")
            .unwrap();

        let items = collect_selection(&[root.to_string_lossy().into_owned()]).unwrap();
        let names: Vec<&str> = items
            .iter()
            .map(|item| item.file.file_name.as_str())
            .collect();
        assert_eq!(names, ["picked/a.txt", "picked/sub/b.txt"]);
        assert_eq!(items.iter().map(|item| item.file.size).sum::<u64>(), 3);
    }
}
