use super::*;

const MOST: u64 = 1 << 20;

/// A scratch directory, gone when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("max-work-{:016x}", rand::random::<u64>()));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn paths_stay_in_work() {
    let ok = |path: &str| beneath_work(path).unwrap();
    assert_eq!(ok("/work/charts/a.png"), Path::new("charts/a.png"));
    assert_eq!(ok("charts/./a.png"), Path::new("charts/a.png"));
    for bad in [
        "/etc/passwd",
        "../a.png",
        "charts/../../a.png",
        "/work",
        "/workshop/a.png",
        "",
    ] {
        assert_eq!(beneath_work(bad).unwrap_err().code, "bad_path", "{bad}");
    }
}

#[test]
fn symlinks_and_big_files_are_refused() {
    let scratch = Scratch::new();
    let work = scratch.0.join("work");
    std::fs::create_dir_all(work.join("charts")).unwrap();
    std::fs::write(work.join("charts/a.png"), b"png").unwrap();
    let outside = scratch.0.join("secret.png");
    std::fs::write(&outside, b"secret").unwrap();
    std::os::unix::fs::symlink(&outside, work.join("link.png")).unwrap();
    std::os::unix::fs::symlink(&scratch.0, work.join("up")).unwrap();
    let big = File::create(work.join("big.png")).unwrap();
    big.set_len(MOST + 1).unwrap();

    assert_eq!(
        read(&work, Path::new("charts/a.png"), MOST).unwrap(),
        b"png"
    );
    let code = |path: &str| read(&work, Path::new(path), MOST).unwrap_err().code;
    assert_eq!(code("link.png"), "bad_path");
    assert_eq!(code("up/secret.png"), "bad_path");
    assert_eq!(code("charts"), "bad_path", "a directory");
    assert_eq!(code("big.png"), "too_big");
    assert_eq!(code("charts/b.png"), "not_found");
}
