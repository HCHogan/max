//! The content store: files named by the SHA-256 of their bytes, under
//! `objects/<first two hex digits>/`, read-only once written. The Haskell
//! version used the same layout, so its files move over as they are. A
//! file is written in `tmp/` first.

use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use tokio::fs;
use tokio::io::AsyncWriteExt;

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

    /// Where the file with this lowercase hex SHA-256 is, or would be.
    pub fn path(&self, sha256: &str) -> PathBuf {
        self.objects
            .join(sha256.get(..2).unwrap_or("00"))
            .join(sha256)
    }

    /// Stores `bytes` and returns their SHA-256. Bytes already there are
    /// left alone. A new file is renamed into its place, so no one reads
    /// half of one.
    pub async fn put(&self, bytes: Vec<u8>) -> io::Result<String> {
        // A video's hash takes a while: not on the runtime's threads.
        let (sha256, bytes) =
            tokio::task::spawn_blocking(move || (hex(&Sha256::digest(&bytes)), bytes))
                .await
                .map_err(io::Error::other)?;
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
            hasher: Sha256::new(),
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
pub struct Partial<'a> {
    store: &'a Store,
    file: fs::File,
    path: PathBuf,
    hasher: Sha256,
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
    pub async fn finish(mut self) -> io::Result<(String, u64)> {
        self.file.flush().await?;
        let sha256 = hex(&std::mem::take(&mut self.hasher).finalize());
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

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const ABC: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    #[tokio::test]
    async fn bytes_by_their_hash_once() {
        let dir = std::env::temp_dir().join(format!("max-store-{:016x}", rand::random::<u64>()));
        let store = Store::open(&dir).await.unwrap();
        assert_eq!(store.put(b"abc".to_vec()).await.unwrap(), ABC);
        let path = dir.join("objects/ba").join(ABC);
        assert_eq!(store.path(ABC), path);
        assert_eq!(std::fs::read(&path).unwrap(), b"abc");
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o444);

        // Again: the file is there, read-only, and isn't written twice.
        assert_eq!(store.put(b"abc".to_vec()).await.unwrap(), ABC);
        let names: Vec<_> = std::fs::read_dir(dir.join("objects/ba"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(names, [ABC]);
        let partial = || std::fs::read_dir(dir.join("tmp")).unwrap().count();
        assert_eq!(partial(), 0, "nothing partial left");
        // What a write left when max stopped is gone on the next start.
        std::fs::write(dir.join("tmp/half"), b"a").unwrap();
        Store::open(&dir).await.unwrap();
        assert_eq!(partial(), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_file_written_in_pieces_is_stored_by_its_hash() {
        let dir = std::env::temp_dir().join(format!("max-store-{:016x}", rand::random::<u64>()));
        let store = Store::open(&dir).await.unwrap();
        let partial = || std::fs::read_dir(dir.join("tmp")).unwrap().count();
        let mut file = store.partial().await.unwrap();
        for piece in [&b"a"[..], b"", b"bc"] {
            file.write(piece).await.unwrap();
        }
        assert_eq!(file.finish().await.unwrap(), (ABC.to_owned(), 3));
        assert_eq!(std::fs::read(store.path(ABC)).unwrap(), b"abc");
        let mode = std::fs::metadata(store.path(ABC))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o444);
        // The same bytes again, and one given up: neither is left.
        let mut again = store.partial().await.unwrap();
        again.write(b"abc").await.unwrap();
        assert_eq!(again.finish().await.unwrap().0, ABC);
        let mut given_up = store.partial().await.unwrap();
        given_up.write(b"ab").await.unwrap();
        drop(given_up);
        assert_eq!(partial(), 0, "nothing partial left");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
