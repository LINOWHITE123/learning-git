import io

import pillow_heif
import pytest
from PIL import Image

from app.images import UnsupportedImage, prepare_image, sniff_media_type


def encode(fmt: str) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (8, 8), "white").save(buffer, format=fmt)
    return buffer.getvalue()


def encode_heic() -> bytes:
    buffer = io.BytesIO()
    pillow_heif.from_pillow(Image.new("RGB", (8, 8), "white")).save(buffer, format="HEIF")
    return buffer.getvalue()


@pytest.mark.parametrize(
    ("fmt", "expected"),
    [("PNG", "image/png"), ("JPEG", "image/jpeg"), ("WEBP", "image/webp")],
)
def test_sniff_recognises_web_formats(fmt, expected):
    assert sniff_media_type(encode(fmt)) == expected


def test_sniff_recognises_heic():
    assert sniff_media_type(encode_heic()) in ("image/heic", "image/heif")


def test_sniff_returns_empty_for_other_bytes():
    assert sniff_media_type(b"hello world") == ""


def test_prepare_passes_web_formats_through_untouched():
    data = encode("JPEG")
    assert prepare_image(data) == ("image/jpeg", data)


def test_prepare_transcodes_heic_to_png():
    media_type, data = prepare_image(encode_heic())
    assert media_type == "image/png"
    with Image.open(io.BytesIO(data)) as image:
        assert image.format == "PNG"
        assert image.size == (8, 8)


def test_prepare_rejects_non_image_bytes():
    with pytest.raises(UnsupportedImage):
        prepare_image(b"not an image at all")


def test_prepare_rejects_image_extension_with_wrong_bytes():
    """A .png name over text bytes must fail: the bytes decide, not the filename."""
    with pytest.raises(UnsupportedImage):
        prepare_image(b"%PDF-1.7 fake")
