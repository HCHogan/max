use image::{Rgba, RgbaImage};

use super::*;

fn encoded(image: RgbaImage, format: ImageFormat) -> Vec<u8> {
    let mut bytes = Cursor::new(Vec::new());
    DynamicImage::ImageRgba8(image)
        .write_to(&mut bytes, format)
        .unwrap();
    bytes.into_inner()
}

fn decoded(bytes: &[u8]) -> (ImageFormat, DynamicImage) {
    (
        image::guess_format(bytes).unwrap(),
        image::load_from_memory(bytes).unwrap(),
    )
}

#[test]
fn a_small_picture_goes_as_it_is() {
    let png = encoded(RgbaImage::new(10, 5), ImageFormat::Png);
    let prepared = prepare(&png).unwrap().unwrap();
    assert_eq!((prepared.width, prepared.height), (10, 5));
    assert!(prepared.copy.is_none());
}

#[test]
fn a_large_one_is_made_smaller_on_white() {
    let clear = RgbaImage::from_pixel(3136, 1000, Rgba([0, 0, 0, 0]));
    let prepared = prepare(&encoded(clear, ImageFormat::Png)).unwrap().unwrap();
    assert_eq!((prepared.width, prepared.height), (3136, 1000));
    let (format, copy) = decoded(&prepared.copy.unwrap());
    assert_eq!(format, ImageFormat::Jpeg);
    assert_eq!((copy.width(), copy.height()), (EDGE, 500));
    let [r, g, b] = copy.to_rgb8().get_pixel(10, 10).0;
    assert!(r > 250 && g > 250 && b > 250, "{r} {g} {b}");
}

#[test]
fn a_gif_is_its_first_frame() {
    let gif = encoded(
        RgbaImage::from_pixel(4, 4, Rgba([255, 0, 0, 255])),
        ImageFormat::Gif,
    );
    let prepared = prepare(&gif).unwrap().unwrap();
    let (format, copy) = decoded(&prepared.copy.unwrap());
    assert_eq!((format, copy.width()), (ImageFormat::Jpeg, 4));
}

#[test]
fn what_isnt_a_picture() {
    assert!(prepare(b"abc").unwrap().is_none());
    let mut png = encoded(RgbaImage::new(10, 5), ImageFormat::Png);
    png.truncate(20);
    assert!(prepare(&png).is_err(), "a PNG that stops early");
}
