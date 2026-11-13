//! The length of an MP4, by its movie header, for `tools.video`: the host
//! never decodes a video, the VM's ffmpeg made it (video.js).

/// The length in seconds of the MP4 in `bytes`, by its movie header: one
/// that starts with `ftyp` and has `moov/mvhd`.
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

#[cfg(test)]
mod tests {
    use super::length;

    fn boxed(kind: &[u8; 4], contents: &[u8]) -> Vec<u8> {
        let size = u32::try_from(contents.len() + 8).unwrap();
        [&size.to_be_bytes()[..], kind, contents].concat()
    }

    fn mvhd(version: u8, scale: u32, units: u64) -> Vec<u8> {
        let mut contents = vec![version, 0, 0, 0];
        let times = if version == 0 { 8 } else { 16 };
        contents.extend(std::iter::repeat_n(0, times));
        contents.extend(scale.to_be_bytes());
        if version == 0 {
            contents.extend(u32::try_from(units).unwrap().to_be_bytes());
        } else {
            contents.extend(units.to_be_bytes());
        }
        boxed(b"mvhd", &contents)
    }

    #[test]
    fn the_length_is_the_movie_headers() {
        let ftyp = boxed(b"ftyp", b"isom\0\0\x02\0");
        let free = boxed(b"free", b"");
        let movie = |mvhd: Vec<u8>| boxed(b"moov", &[boxed(b"trak", b"x"), mvhd].concat());
        // The header first, as video.js writes it, or after the data.
        let file = [ftyp.clone(), movie(mvhd(0, 1000, 6500)), free.clone()].concat();
        assert_eq!(length(&file), Some(6.5));
        let file = [ftyp.clone(), free.clone(), movie(mvhd(1, 600, 600 * 90))].concat();
        assert_eq!(length(&file), Some(90.0));
        // An mdat with a 64-bit size before the header.
        let mut mdat = 1u32.to_be_bytes().to_vec();
        mdat.extend(b"mdat");
        mdat.extend(20u64.to_be_bytes());
        mdat.extend([7, 7, 7, 7]);
        let file = [ftyp.clone(), mdat, movie(mvhd(0, 30, 60))].concat();
        assert_eq!(length(&file), Some(2.0));

        // Not an MP4; no header; a header cut short; no time scale.
        assert_eq!(length(b"\x1aE\xdf\xa3 matroska"), None);
        assert_eq!(length(&[ftyp.clone(), free].concat()), None);
        let short = boxed(b"moov", &boxed(b"mvhd", &[0, 0, 0, 0, 1, 2]));
        assert_eq!(length(&[ftyp.clone(), short].concat()), None);
        assert_eq!(length(&[ftyp, movie(mvhd(0, 0, 60))].concat()), None);
    }
}
