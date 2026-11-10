//! A group's /work as the host sees it. The guest writes it, symlinks
//! included, so a path in it is opened one component at a time without
//! following them. Everything the host reads or writes there goes through
//! here: tool output and job reports too, since 10-30, when a review
//! found a link the guest put at /work/.max/out would send them anywhere
//! the maxx user can write.

use std::fs::{File, Metadata};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::time::SystemTime;

use rustix::fd::OwnedFd;
use rustix::fs::{Mode, OFlags};
use rustix::io::Errno;

use super::Failure;

/// The path under /work that `path` names, from /work: absolute within
/// it, or relative to it. No `..`.
pub(super) fn beneath_work(path: &str) -> Result<PathBuf, Failure> {
    let path = Path::new(path);
    let path = path.strip_prefix("/work").unwrap_or(path);
    let mut relative = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(name) => relative.push(name),
            Component::CurDir => {}
            _ => {
                return Err(Failure::new(
                    "bad_path",
                    "only files under /work, and no .. in the path",
                ));
            }
        }
    }
    if relative.as_os_str().is_empty() {
        return Err(Failure::new("bad_path", "path must name a file"));
    }
    Ok(relative)
}

/// Reads `relative` under `work`, at most `most` bytes, opening one
/// component at a time without following a symlink: the guest writes
/// /work, and a link there would point into the host. Blocking.
pub(crate) fn read(work: &Path, relative: &Path, most: u64) -> Result<Vec<u8>, Failure> {
    read_stamped(work, relative, most).map(|(bytes, _)| bytes)
}

/// What [`read`] reads, and when the file was last written.
pub(crate) fn read_stamped(
    work: &Path,
    relative: &Path,
    most: u64,
) -> Result<(Vec<u8>, SystemTime), Failure> {
    let (mut file, metadata) = open(work, relative, most)?;
    let shown = shown(relative);
    let unreadable =
        |error: std::io::Error| Failure::new("unreadable", format!("can't read {shown}: {error}"));
    // As large as the file says: through Take, the read wouldn't know.
    let mut bytes = Vec::with_capacity(usize::try_from(metadata.len()).unwrap_or(0));
    (&mut file)
        .take(most + 1)
        .read_to_end(&mut bytes)
        .map_err(unreadable)?;
    if bytes.len() as u64 > most {
        return Err(too_big(relative, most));
    }
    let modified = metadata.modified().map_err(unreadable)?;
    Ok((bytes, modified))
}

/// Opens `relative` under `work` as [`read`] does, if it is a file of at
/// most `most` bytes: the file, and what it said of itself. It may grow
/// while it's read, the guest writing it. Blocking.
pub(super) fn open(work: &Path, relative: &Path, most: u64) -> Result<(File, Metadata), Failure> {
    let shown = shown(relative);
    let failed = |errno: Errno| match errno {
        Errno::NOENT => Failure::new("not_found", format!("{shown} doesn't exist")),
        Errno::LOOP | Errno::NOTDIR | Errno::MLINK => Failure::new(
            "bad_path",
            format!("{shown}: a symlink is on the path, or part of it isn't a directory"),
        ),
        errno => Failure::new("unreadable", format!("can't read {shown}: {errno}")),
    };
    let flags = OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    let mut dir =
        rustix::fs::open(work, flags | OFlags::DIRECTORY, Mode::empty()).map_err(failed)?;
    let names: Vec<_> = relative.iter().collect();
    let Some((last, parents)) = names.split_last() else {
        return Err(Failure::new("bad_path", "path must name a file"));
    };
    for name in parents {
        dir = rustix::fs::openat(&dir, *name, flags | OFlags::DIRECTORY, Mode::empty())
            .map_err(failed)?;
    }
    // Without blocking, so that a FIFO can't hold the open.
    let file =
        rustix::fs::openat(&dir, *last, flags | OFlags::NONBLOCK, Mode::empty()).map_err(failed)?;
    let file = File::from(file);
    let metadata = file
        .metadata()
        .map_err(|error| Failure::new("unreadable", format!("can't read {shown}: {error}")))?;
    if !metadata.is_file() {
        return Err(Failure::new(
            "bad_path",
            format!("{shown} isn't a regular file"),
        ));
    }
    if metadata.len() > most {
        return Err(too_big(relative, most));
    }
    Ok((file, metadata))
}

/// `relative` as the guest sees it.
pub(super) fn shown(relative: &Path) -> String {
    Path::new("/work").join(relative).display().to_string()
}

/// `relative` is past `most` bytes.
pub(super) fn too_big(relative: &Path, most: u64) -> Failure {
    Failure::new(
        "too_big",
        format!("{} is over {} MiB", shown(relative), most >> 20),
    )
}

/// Copies the host's file `from` to `dir/name` under `work`, as [`write`]
/// does. Blocking.
pub(super) fn put(work: &Path, dir: &str, name: &str, from: &Path) -> Result<(), Failure> {
    place(work, dir, name, |file| {
        File::open(from).and_then(|mut source| std::io::copy(&mut source, file))?;
        Ok(())
    })
}

/// Writes `bytes` to `dir/name` under `work`, making `dir` if it isn't
/// there and replacing what is at `name`; dated `modified`, if given.
/// Blocking.
pub(crate) fn write(
    work: &Path,
    dir: &str,
    name: &str,
    bytes: &[u8],
    modified: Option<SystemTime>,
) -> Result<(), Failure> {
    place(work, dir, name, |file| {
        file.write_all(bytes)?;
        match modified {
            Some(modified) => file.set_modified(modified),
            None => Ok(()),
        }
    })
}

/// A new file at `dir/name` under `work`, made as [`write`] makes `dir`,
/// for writing as it comes. Whatever is at `name` already, a link
/// included, is left alone and the file isn't made. Blocking.
pub(crate) fn create(work: &Path, dir: &str, name: &str) -> Result<File, Failure> {
    let failed = written(dir, name);
    let dir = make_dir(work, dir).map_err(&failed)?;
    let file = rustix::fs::openat(&dir, name, CREATED, Mode::from_raw_mode(0o644));
    Ok(File::from(file.map_err(failed)?))
}

const CREATED: OFlags = OFlags::WRONLY
    .union(OFlags::CREATE)
    .union(OFlags::EXCL)
    .union(OFlags::NOFOLLOW)
    .union(OFlags::CLOEXEC);

/// `dir` under `work`, made if it isn't there, one component at a time,
/// none of them followed if it is a link.
fn make_dir(work: &Path, dir: &str) -> Result<OwnedFd, Errno> {
    let flags = OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC | OFlags::DIRECTORY;
    let mut at = rustix::fs::open(work, flags, Mode::empty())?;
    for name in dir
        .split('/')
        .filter(|name| !name.is_empty() && *name != ".")
    {
        if name == ".." {
            return Err(Errno::INVAL);
        }
        match rustix::fs::mkdirat(&at, name, Mode::from_raw_mode(0o755)) {
            Ok(()) | Err(Errno::EXIST) => {}
            Err(errno) => return Err(errno),
        }
        at = rustix::fs::openat(&at, name, flags, Mode::empty())?;
    }
    Ok(at)
}

/// Why `dir/name` under /work couldn't be written.
fn written<'a>(dir: &'a str, name: &'a str) -> impl Fn(Errno) -> Failure + 'a {
    move |errno| {
        let shown = format!("/work/{dir}/{name}");
        match errno {
            Errno::LOOP | Errno::NOTDIR | Errno::MLINK | Errno::INVAL => Failure::new(
                "bad_path",
                format!("/work/{dir} isn't a directory, or is a symlink"),
            ),
            Errno::ISDIR | Errno::NOTEMPTY => {
                Failure::new("bad_path", format!("{shown} is a directory"))
            }
            Errno::EXIST => Failure::new("bad_path", format!("{shown} exists already")),
            errno => Failure::new("unwritable", format!("can't write {shown}: {errno}")),
        }
    }
}

/// What `fill` writes, put at `dir/name` under `work`. It goes to a new
/// file first and is renamed into place, all through descriptors opened
/// without following a symlink, so no link the guest puts in /work sends
/// it into the host.
fn place(
    work: &Path,
    dir: &str,
    name: &str,
    fill: impl FnOnce(&mut File) -> std::io::Result<()>,
) -> Result<(), Failure> {
    let shown = format!("/work/{dir}/{name}");
    let failed = written(dir, name);
    let dir = make_dir(work, dir).map_err(&failed)?;
    let temporary = format!(".{:016x}.part", rand::random::<u64>());
    let file = rustix::fs::openat(&dir, &temporary, CREATED, Mode::from_raw_mode(0o644))
        .map_err(&failed)?;
    let renamed = match fill(&mut File::from(file)) {
        // Over a directory: EISDIR, or EEXIST or ENOTEMPTY for one with
        // something in it.
        Ok(_) => rustix::fs::renameat(&dir, &temporary, &dir, name).map_err(|errno| match errno {
            Errno::EXIST => failed(Errno::ISDIR),
            errno => failed(errno),
        }),
        Err(error) => Err(Failure::new(
            "unwritable",
            format!("can't write {shown}: {error}"),
        )),
    };
    if renamed.is_err() {
        let _ = rustix::fs::unlinkat(&dir, &temporary, rustix::fs::AtFlags::empty());
    }
    renamed
}

#[cfg(test)]
mod tests;
