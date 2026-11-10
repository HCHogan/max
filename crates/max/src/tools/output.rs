//! A command's output: what the model is shown of it, and the file in
//! /work that has the whole.

use super::*;

/// Where a long output goes, under /work.
pub(super) const OUT: &str = ".max/out";

/// A command's output: all of it while short; past `SHOWN_BYTES`, its head and
/// tail, and the whole in a file, `name` in the guest's /work/.max/out,
/// or from the start once [`Output::create`] makes it.
pub(super) struct Output {
    pub(super) name: String,
    /// The host's side of /work.
    pub(super) work: PathBuf,
    pub(super) head: Vec<u8>,
    pub(super) tail: VecDeque<u8>,
    pub(super) total: usize,
    pub(super) file: Option<fs::File>,
}

impl Output {
    pub(super) fn new(work: &Path, name: String) -> Self {
        Self {
            work: work.to_owned(),
            name,
            head: Vec::new(),
            tail: VecDeque::new(),
            total: 0,
            file: None,
        }
    }

    pub(super) fn shown(&self) -> String {
        let head = String::from_utf8_lossy(&self.head);
        if self.total <= SHOWN_BYTES {
            return head.into_owned();
        }
        let tail: Vec<u8> = self.tail.iter().copied().collect();
        let left_out = self.total - self.head.len() - tail.len();
        format!(
            "{}\n…（中间省略 {left_out} 字节，全部输出在 /work/.max/out/{}）…\n{}",
            head.trim_end_matches('\u{fffd}'),
            self.name,
            String::from_utf8_lossy(&tail).trim_start_matches('\u{fffd}'),
        )
    }
}

impl Sink for Output {
    async fn output(&mut self, _: Stream, data: &[u8]) -> Result<()> {
        let before = self.total;
        self.total += data.len();
        if self.file.is_none() && self.total > SHOWN_BYTES {
            self.create().await?;
        }
        if let Some(file) = &mut self.file {
            // Read while the command runs, for a background one.
            file.write_all(data).await?;
            file.flush().await?;
        }
        if self.total <= SHOWN_BYTES {
            self.head.extend_from_slice(data);
        } else if before <= SHOWN_BYTES {
            // Long with this piece: only its ends are kept.
            let mut all = std::mem::take(&mut self.head);
            all.extend_from_slice(data);
            self.head = all[..SHOWN_BYTES / 2].to_vec();
            self.tail = all[all.len() - SHOWN_BYTES / 2..].iter().copied().collect();
        } else {
            self.tail.extend(data);
            let over = self.tail.len().saturating_sub(SHOWN_BYTES / 2);
            self.tail.drain(..over);
        }
        Ok(())
    }
}

impl Output {
    /// Makes the file now, with the output so far: all of it, since that
    /// is short.
    pub(super) async fn create(&mut self) -> Result<()> {
        let (work, name) = (self.work.clone(), self.name.clone());
        let file = tokio::task::spawn_blocking(move || mcp::work::create(&work, OUT, &name))
            .await?
            .map_err(|failure| eyre!(failure.message))?;
        let mut file = fs::File::from_std(file);
        file.write_all(&self.head).await?;
        file.flush().await?;
        self.file = Some(file);
        Ok(())
    }

    /// Writes out what the file has yet to get.
    pub(super) async fn finish(&mut self) -> Result<()> {
        if let Some(file) = &mut self.file {
            file.flush().await?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn short_output_is_shown_whole() {
        let work = std::env::temp_dir().join(format!("max-output-{}", std::process::id()));
        std::fs::create_dir_all(&work).unwrap();
        let mut output = Output::new(&work, "short.txt".into());
        output.output(Stream::Out, b"hello\n").await.unwrap();
        output.output(Stream::Out, b"world").await.unwrap();
        assert_eq!(output.shown(), "hello\nworld");
        assert!(!work.join(".max/out/short.txt").exists());
        let _ = std::fs::remove_dir_all(work);
    }

    #[tokio::test]
    async fn long_output_keeps_its_ends_and_goes_whole_to_a_file() {
        let work = std::env::temp_dir().join(format!("max-output-long-{}", std::process::id()));
        std::fs::create_dir_all(&work).unwrap();
        let path = work.join(".max/out/max-2.txt");
        let mut output = Output::new(&work, "max-2.txt".into());
        let mut all = Vec::new();
        for n in 0..5000 {
            let line = format!("{n:05}\n");
            all.extend_from_slice(line.as_bytes());
            output.output(Stream::Out, line.as_bytes()).await.unwrap();
        }
        output.finish().await.unwrap();
        let shown = output.shown();
        assert!(shown.starts_with("00000\n"), "{shown}");
        assert!(shown.ends_with("04999\n"), "{shown}");
        assert!(shown.contains("/work/.max/out/max-2.txt"), "{shown}");
        assert_eq!(output.head.len() + output.tail.len(), SHOWN_BYTES);
        assert_eq!(std::fs::read(&path).unwrap(), all);
        let _ = std::fs::remove_dir_all(work);
    }

    /// The guest's link at /work/.max: a long output isn't written through
    /// it.
    #[tokio::test]
    async fn long_output_follows_no_link() {
        let scratch = std::env::temp_dir().join(format!("max-output-link-{}", std::process::id()));
        let (work, host) = (scratch.join("work"), scratch.join("host"));
        std::fs::create_dir_all(&work).unwrap();
        std::fs::create_dir_all(host.join("out")).unwrap();
        std::os::unix::fs::symlink(&host, work.join(".max")).unwrap();
        let mut output = Output::new(&work, "max-3.txt".into());
        let long = vec![b'x'; SHOWN_BYTES + 1];
        assert!(output.output(Stream::Out, &long).await.is_err());
        assert!(!host.join("out/max-3.txt").exists());
        let _ = std::fs::remove_dir_all(scratch);
    }

    /// A background command's: the model reads it while the command runs.
    #[tokio::test]
    async fn a_created_file_has_the_output_from_the_start() {
        let work = std::env::temp_dir().join(format!("max-output-kept-{}", std::process::id()));
        std::fs::create_dir_all(&work).unwrap();
        let path = work.join(".max/out/max-4.txt");
        let mut output = Output::new(&work, "max-4.txt".into());
        output.create().await.unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"");
        output.output(Stream::Out, b"building\n").await.unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"building\n");
        output.output(Stream::Out, b"done").await.unwrap();
        assert_eq!(output.shown(), "building\ndone");
        let long = vec![b'x'; SHOWN_BYTES];
        output.output(Stream::Out, &long).await.unwrap();
        assert_eq!(std::fs::read(&path).unwrap().len(), SHOWN_BYTES + 13);
        let shown = output.shown();
        assert!(shown.starts_with("building\ndonex"), "{shown}");
        assert!(shown.contains("/work/.max/out/max-4.txt"), "{shown}");
        let _ = std::fs::remove_dir_all(work);
    }
}
