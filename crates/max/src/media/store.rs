//! The content store: files named by the SHA-256 of their bytes, under
//! `objects/<first two hex digits>/`, read-only once written. The Haskell
//! version used the same layout, so its files move over as they are. A
//! file is written in `tmp/` first.

use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use max_core::message::Sha256;
use sha2::Digest;
use tokio::fs;
use tokio::io::AsyncWriteExt;

#[derive(Debug)]
pub struct Store {
    objects: PathBuf,
    tmp: PathBuf,
}

impl Store {
    /// The store in `dir`. What a write left in `tmp/` when max stopped is
    /// thrown away.
    pub async fn open(dir: &Path) -> io::Result<Self> {
        let tmp = dir.join("tmp");
        match fs::remove_dir_all(&tmp).await {
            Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
            _ => {}
        }
        fs::create_dir_all(&tmp).await?;
        Ok(Self {
            objects: dir.join("objects"),
            tmp,
        })
    }

    /// Where the file of this name is, or would be.
    #[must_use]
    pub fn path(&self, sha256: &Sha256) -> PathBuf {
        let name = sha256.as_str();
        self.objects.join(name.get(..2).unwrap_or("00")).join(name)
    }

    /// Stores `bytes` and returns their SHA-256. Bytes already there are
    /// left alone. A new file is renamed into its place, so no one reads
    /// half of one.
    pub async fn put(&self, bytes: Vec<u8>) -> io::Result<Sha256> {
        let (sha256, bytes) = named(bytes).await?;
        let path = self.path(&sha256);
        if fs::try_exists(&path).await? {
            return Ok(sha256);
        }
        let partial = self
            .tmp
            .join(format!("{sha256}.{:016x}", rand::random::<u64>()));
        let written = async {
            fs::write(&partial, bytes).await?;
            self.place(&partial, &path).await
        }
        .await;
        if written.is_err() {
            let _ = fs::remove_file(&partial).await;
        }
        written.map(|()| sha256)
    }

    /// A file to store a piece at a time, hashed as it's written: one
    /// too large to hold.
    pub async fn partial(&self) -> io::Result<Partial<'_>> {
        let path = self.tmp.join(format!("{:016x}", rand::random::<u64>()));
        let file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .await?;
        Ok(Partial {
            store: self,
            file,
            path,
            hasher: sha2::Sha256::new(),
            size: 0,
            placed: false,
        })
    }

    /// Makes the file written at `written` read-only and renames it to
    /// `path`, its place.
    async fn place(&self, written: &Path, path: &Path) -> io::Result<()> {
        fs::create_dir_all(path.parent().unwrap_or(&self.objects)).await?;
        fs::set_permissions(written, std::fs::Permissions::from_mode(0o444)).await?;
        fs::rename(written, path).await
    }
}

/// A file being written into the store. One dropped before it's
/// finished is removed, and so is one whose bytes were there already.
#[derive(Debug)]
pub struct Partial<'a> {
    store: &'a Store,
    file: fs::File,
    path: PathBuf,
    hasher: sha2::Sha256,
    size: u64,
    placed: bool,
}

impl Partial<'_> {
    pub async fn write(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.hasher.update(bytes);
        self.size += bytes.len() as u64;
        self.file.write_all(bytes).await
    }

    /// Puts what was written in its place, and returns its SHA-256 and
    /// size.
    pub async fn finish(mut self) -> io::Result<(Sha256, u64)> {
        self.file.flush().await?;
        let sha256 = Sha256::of(std::mem::take(&mut self.hasher).finalize().into());
        let path = self.store.path(&sha256);
        if !fs::try_exists(&path).await? {
            self.store.place(&self.path, &path).await?;
            self.placed = true;
        }
        Ok((sha256, self.size))
    }
}

impl Drop for Partial<'_> {
    fn drop(&mut self) {
        // One unlink, quick enough not to need a blocking thread.
        if !self.placed {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

/// The name `bytes` are stored by, without storing them; and the bytes
/// back.
pub async fn named(bytes: Vec<u8>) -> io::Result<(Sha256, Vec<u8>)> {
    // A video's hash takes a while: not on the runtime's threads.
    let hashed = move || (Sha256::of(sha2::Sha256::digest(&bytes).into()), bytes);
    tokio::task::spawn_blocking(hashed)
        .await
        .map_err(io::Error::other)
}
