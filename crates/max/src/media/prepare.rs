//! What the model is sent of a picture: the original when it is small
//! enough, else a JPEG at most 1568 pixels on its long edge. The Haskell
//! version first sent originals of several MB, base64 and all (0a2addb).

use std::io::Cursor;

use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{DynamicImage, ImageFormat, ImageReader, ImageResult, Limits, Rgb, RgbImage};

/// The long edge the model gets at most.
pub const EDGE: u32 = 1568;
/// The most an original may be and still go as it is.
const SMALL: usize = 1 << 20;
const QUALITY: u8 = 85;

/// A picture's size, and its copy for the model.
#[derive(Debug)]
pub struct Prepared {
    pub width: u32,
    pub height: u32,
    /// None when the original will do.
    pub copy: Option<Vec<u8>>,
}

/// None when the bytes aren't PNG, JPEG, GIF or WebP; an error when they
/// say they are and don't decode. Blocking: a large picture takes a
/// while, bounded by the limits.
pub fn prepare(bytes: &[u8]) -> ImageResult<Option<Prepared>> {
    let Ok(format) = image::guess_format(bytes) else {
        return Ok(None);
    };
    if !matches!(
        format,
        ImageFormat::Png | ImageFormat::Jpeg | ImageFormat::Gif | ImageFormat::WebP
    ) {
        return Ok(None);
    }
    let reader = || {
        let mut reader = ImageReader::with_format(Cursor::new(bytes), format);
        reader.limits(limits());
        reader
    };
    let (width, height) = reader().into_dimensions()?;
    let large = width.max(height) > EDGE;
    // A GIF's first frame: providers take one frame at most.
    if !large && bytes.len() <= SMALL && format != ImageFormat::Gif {
        return Ok(Some(Prepared {
            width,
            height,
            copy: None,
        }));
    }
    let mut image = reader().decode()?;
    if large {
        image = image.resize(EDGE, EDGE, FilterType::Triangle);
    }
    let mut copy = Vec::new();
    JpegEncoder::new_with_quality(&mut copy, QUALITY).encode_image(&on_white(image))?;
    Ok(Some(Prepared {
        width,
        height,
        copy: Some(copy),
    }))
}

/// Downloads are anyone's: a small file may say it is a huge picture.
fn limits() -> Limits {
    let mut limits = Limits::default();
    limits.max_image_width = Some(16_384);
    limits.max_image_height = Some(16_384);
    limits.max_alloc = Some(256 << 20);
    limits
}

/// JPEG has no transparency: a sticker's goes white, not black.
fn on_white(image: DynamicImage) -> RgbImage {
    if !image.color().has_alpha() {
        return image.into_rgb8();
    }
    let rgba = image.into_rgba8();
    RgbImage::from_fn(rgba.width(), rgba.height(), |x, y| {
        let [r, g, b, a] = rgba.get_pixel(x, y).0;
        let over = |c: u8| {
            let (c, a) = (u16::from(c), u16::from(a));
            u8::try_from((c * a + 255 * (255 - a)) / 255).unwrap_or(u8::MAX)
        };
        Rgb([over(r), over(g), over(b)])
    })
}

#[cfg(test)]
mod tests;
