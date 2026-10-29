//! A group's /work as the host sees it. The guest writes it, symlinks
//! included, so a path in it is opened one component at a time without
//! following them.

use std::fs::File;
use std::io::Read;
use std::path::{Component, Path, PathBuf};

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
                    "只能用 /work 下的文件，路径里不能有 ..",
                ));
            }
        }
    }
    if relative.as_os_str().is_empty() {
        return Err(Failure::new("bad_path", "path 得是一个文件"));
    }
    Ok(relative)
}

/// Reads `relative` under `work`, at most `most` bytes, opening one component at a time
/// without following a symlink: the guest writes /work, and a link there
/// would point into the host. Blocking.
pub(super) fn read(work: &Path, relative: &Path, most: u64) -> Result<Vec<u8>, Failure> {
    let shown = Path::new("/work").join(relative).display().to_string();
    let failed = |errno: Errno| match errno {
        Errno::NOENT => Failure::new("not_found", format!("{shown} 不存在")),
        Errno::LOOP | Errno::NOTDIR | Errno::MLINK => Failure::new(
            "bad_path",
            format!("{shown}：路径上有符号链接，或者有一段不是目录"),
        ),
        errno => Failure::new("unreadable", format!("读不了 {shown}：{errno}")),
    };
    let flags = OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    let mut dir =
        rustix::fs::open(work, flags | OFlags::DIRECTORY, Mode::empty()).map_err(failed)?;
    let names: Vec<_> = relative.iter().collect();
    let Some((last, parents)) = names.split_last() else {
        return Err(Failure::new("bad_path", "path 得是一个文件"));
    };
    for name in parents {
        dir = rustix::fs::openat(&dir, *name, flags | OFlags::DIRECTORY, Mode::empty())
            .map_err(failed)?;
    }
    // Without blocking, so that a FIFO can't hold the open.
    let file =
        rustix::fs::openat(&dir, *last, flags | OFlags::NONBLOCK, Mode::empty()).map_err(failed)?;
    let mut file = File::from(file);
    let unreadable =
        |error: std::io::Error| Failure::new("unreadable", format!("读不了 {shown}：{error}"));
    let metadata = file.metadata().map_err(unreadable)?;
    if !metadata.is_file() {
        return Err(Failure::new("bad_path", format!("{shown} 不是普通文件")));
    }
    let too_big = || Failure::new("too_big", format!("{shown} 超过 {} MiB 了", most >> 20));
    if metadata.len() > most {
        return Err(too_big());
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take(most + 1)
        .read_to_end(&mut bytes)
        .map_err(unreadable)?;
    if bytes.len() as u64 > most {
        return Err(too_big());
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests;
