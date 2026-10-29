//! The content store: files named by the SHA-256 of their bytes, under
//! `objects/<first two hex digits>/`, read-only once written. The Haskell
//! version used the same layout, so its files move over as they are. A
//! file is written in `tmp/` first.

use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use tokio::fs;

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
        let dir = path.parent().unwrap_or(&self.objects);
        fs::create_dir_all(dir).await?;
        let partial = self
            .tmp
            .join(format!("{sha256}.{:016x}", rand::random::<u64>()));
        let written = async {
            fs::write(&partial, bytes).await?;
            fs::set_permissions(&partial, std::fs::Permissions::from_mode(0o444)).await?;
            fs::rename(&partial, &path).await
        }
        .await;
        if written.is_err() {
            let _ = fs::remove_file(&partial).await;
        }
        written.map(|()| sha256)
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
}
