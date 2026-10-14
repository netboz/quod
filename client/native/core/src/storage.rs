//! Private, single-writer active identity storage. Backups are a separate format.
use crate::{identity::random32, require, Result};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};
use zeroize::Zeroizing;

pub struct Storage {
    directory: PathBuf,
    _lock: File,
}
impl Storage {
    pub fn open(directory: &Path) -> Result<Self> {
        if !directory.exists() {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(directory)
                .map_err(|e| e.to_string())?;
        }
        let metadata = fs::symlink_metadata(directory).map_err(|e| e.to_string())?;
        require(
            metadata.is_dir() && metadata.permissions().mode() & 0o077 == 0,
            "Identity directory must be private (mode 0700)",
        )?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(directory.join("lock"))
            .map_err(|e| e.to_string())?;
        lock.try_lock()
            .map_err(|_| "This identity is already open in another client")?;
        Ok(Self {
            directory: directory.into(),
            _lock: lock,
        })
    }
    pub fn read(&self) -> Result<Option<Zeroizing<Vec<u8>>>> {
        let path = self.directory.join("active.json");
        match fs::symlink_metadata(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.to_string()),
            Ok(metadata) => {
                require(
                    metadata.is_file() && metadata.permissions().mode() & 0o077 == 0,
                    "Saved identity must be a private regular file (mode 0600)",
                )?;
                fs::read(path)
                    .map(|b| Some(Zeroizing::new(b)))
                    .map_err(|e| e.to_string())
            }
        }
    }
    pub fn save(&self, bytes: &[u8]) -> Result<()> {
        let temporary = self
            .directory
            .join(format!("{}.tmp", crate::identity::b64(&random32()?)));
        let result = (|| -> std::io::Result<()> {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary)?;
            file.write_all(bytes)?;
            file.sync_all()?;
            fs::rename(&temporary, self.directory.join("active.json"))?;
            File::open(&self.directory)?.sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
        result.map_err(|e| format!("Could not save identity: {e}"))?;
        require(
            self.read()?.is_some_and(|saved| saved.as_slice() == bytes),
            "Saved identity read-back did not match",
        )
    }
}
