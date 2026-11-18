//! The length of an MP4, by its movie header, for `tools.video`: the host
//! never decodes a video, the VM's ffmpeg made it (video.js).

/// The length in seconds of the MP4 in `bytes`, by its movie header: one
/// that starts with `ftyp` and has `moov/mvhd`.
#[must_use]
pub fn length(bytes: &[u8]) -> Option<f64> {
    let (kind, _) = Boxes(bytes).next()?;
    if kind != *b"ftyp" {
        return None;
    }
    let (_, moov) = Boxes(bytes).find(|(kind, _)| kind == b"moov")?;
    let (_, mvhd) = Boxes(moov).find(|(kind, _)| kind == b"mvhd")?;
    let number = |at: usize, width: usize| {
        let field = mvhd.get(at..at + width)?;
        Some(field.iter().fold(0u64, |n, byte| n << 8 | u64::from(*byte)))
    };
    // After the version and flags: two times, the time scale, the length.
    let (scale, units) = match mvhd.first()? {
        0 => (number(12, 4)?, number(16, 4)?),
        1 => (number(20, 4)?, number(24, 8)?),
        _ => return None,
    };
    (scale > 0).then(|| units as f64 / scale as f64)
}

/// One level of an MP4's boxes: each one's type and contents.
struct Boxes<'a>(&'a [u8]);

impl<'a> Iterator for Boxes<'a> {
    type Item = ([u8; 4], &'a [u8]);

    fn next(&mut self) -> Option<Self::Item> {
        let size = u32::from_be_bytes(self.0.get(..4)?.try_into().ok()?);
        let kind: [u8; 4] = self.0.get(4..8)?.try_into().ok()?;
        let (header, size) = match size {
            // To the end.
            0 => (8, self.0.len()),
            // A 64-bit size after the type.
            1 => {
                let large = u64::from_be_bytes(self.0.get(8..16)?.try_into().ok()?);
                (16, usize::try_from(large).ok()?)
            }
            size => (8, usize::try_from(size).ok()?),
        };
        let contents = self.0.get(header..size)?;
        self.0 = &self.0[size..];
        Some((kind, contents))
    }
}
