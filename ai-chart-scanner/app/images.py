"""Sniff and normalise uploaded screenshots so phone photos work like desktop ones.

Browsers report unreliable content types for iPhone camera-roll pictures (HEIC often arrives as
`application/octet-stream`), so the bytes decide the format. HEIC/HEIF is transcoded to PNG because
vision providers only accept PNG, JPEG and WebP.
"""

import io

import pillow_heif
from PIL import Image

VISION_MEDIA_TYPES = ("image/png", "image/jpeg", "image/webp")
CONVERTED_MEDIA_TYPES = ("image/heic", "image/heif")
SUPPORTED_MEDIA_TYPES = VISION_MEDIA_TYPES + CONVERTED_MEDIA_TYPES
SUPPORTED_LABEL = "PNG, JPG, JPEG, WebP or HEIC"

pillow_heif.register_heif_opener()


class UnsupportedImage(Exception):
    """Raised when the uploaded bytes are not an image format we can analyse."""


def sniff_media_type(data: bytes) -> str:
    """Return the media type implied by the file's magic bytes, or "" when unrecognised."""
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data[4:8] == b"ftyp":
        brand = data[8:12]
        if brand in (b"heic", b"heix", b"heim", b"heis", b"hevc", b"hevx"):
            return "image/heic"
        if brand in (b"mif1", b"msf1", b"miaf"):
            return "image/heif"
    return ""


def prepare_image(data: bytes) -> tuple[str, bytes]:
    """Return (media_type, data) ready for a vision provider, transcoding HEIC/HEIF to PNG."""
    media_type = sniff_media_type(data)
    if media_type in VISION_MEDIA_TYPES:
        return media_type, data
    if media_type not in CONVERTED_MEDIA_TYPES:
        raise UnsupportedImage(f"unsupported image format. Use {SUPPORTED_LABEL}.")

    buffer = io.BytesIO()
    try:
        with Image.open(io.BytesIO(data)) as image:
            image.convert("RGB").save(buffer, format="PNG")
    except OSError as error:
        raise UnsupportedImage(f"the HEIC image could not be read ({error}).") from error
    return "image/png", buffer.getvalue()
