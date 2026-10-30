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

#[test]
fn files_are_put_in_place() {
    let scratch = Scratch::new();
    let work = scratch.0.join("work");
    std::fs::create_dir_all(&work).unwrap();
    let from = scratch.0.join("stored");
    std::fs::write(&from, b"%PDF").unwrap();
    let listed = |dir: &Path| -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    };

    // The directory is made, and the file put there again replaces it.
    put(&work, "chat", "1.0-周报.pdf", &from).unwrap();
    std::fs::write(&from, b"%PDF-1.4").unwrap();
    put(&work, "chat", "1.0-周报.pdf", &from).unwrap();
    assert_eq!(
        std::fs::read(work.join("chat/1.0-周报.pdf")).unwrap(),
        b"%PDF-1.4"
    );
    assert_eq!(listed(&work.join("chat")), ["1.0-周报.pdf"]);

    // A link in its place is replaced, not followed.
    let outside = scratch.0.join("host.txt");
    std::fs::write(&outside, b"host").unwrap();
    std::os::unix::fs::symlink(&outside, work.join("chat/2.0.txt")).unwrap();
    put(&work, "chat", "2.0.txt", &from).unwrap();
    assert_eq!(std::fs::read(&outside).unwrap(), b"host");
    assert!(!work.join("chat/2.0.txt").is_symlink());

    // The directory a link to the host: nothing is written there.
    let host = scratch.0.join("host");
    std::fs::create_dir_all(&host).unwrap();
    std::os::unix::fs::symlink(&host, work.join("linked")).unwrap();
    assert_eq!(
        put(&work, "linked", "3.0.txt", &from).unwrap_err().code,
        "bad_path"
    );
    assert!(listed(&host).is_empty());
    // A directory where the file goes is left alone.
    std::fs::create_dir_all(work.join("chat/4.0.txt/inside")).unwrap();
    assert_eq!(
        put(&work, "chat", "4.0.txt", &from).unwrap_err().code,
        "bad_path"
    );
    assert_eq!(
        listed(&work.join("chat")),
        ["1.0-周报.pdf", "2.0.txt", "4.0.txt"]
    );

    // A deeper directory: no component of it is followed.
    put(&work, ".max/jobs", "job-1.md", &from).unwrap();
    assert!(work.join(".max/jobs/job-1.md").is_file());
    std::os::unix::fs::symlink(&host, work.join("deep")).unwrap();
    assert_eq!(
        put(&work, "deep/jobs", "job-2.md", &from).unwrap_err().code,
        "bad_path"
    );
    assert_eq!(put(&work, "../x", "y", &from).unwrap_err().code, "bad_path");
    assert!(listed(&host).is_empty());
}

#[test]
fn a_file_is_created_only_where_nothing_is() {
    let scratch = Scratch::new();
    let work = scratch.0.join("work");
    std::fs::create_dir_all(&work).unwrap();
    let mut file = create(&work, ".max/out", "a.txt").unwrap();
    file.write_all(b"out").unwrap();
    assert_eq!(std::fs::read(work.join(".max/out/a.txt")).unwrap(), b"out");
    let outside = scratch.0.join("host.txt");
    std::fs::write(&outside, b"host").unwrap();
    std::os::unix::fs::symlink(&outside, work.join(".max/out/b.txt")).unwrap();
    for name in ["a.txt", "b.txt"] {
        assert_eq!(
            create(&work, ".max/out", name).unwrap_err().code,
            "bad_path"
        );
    }
    assert_eq!(std::fs::read(&outside).unwrap(), b"host");
}
