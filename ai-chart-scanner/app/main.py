import json
from pathlib import Path

import httpx
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import ValidationError

from .analyzer import MIN_CONFIDENCE, scan_charts
from .config import MAX_IMAGE_BYTES, MAX_IMAGES, get_provider, min_risk_reward
from .images import SUPPORTED_LABEL, UnsupportedImage, prepare_image
from .models import ScanResult
from .providers import ChartImage

STATIC_DIR = Path(__file__).resolve().parent.parent / "static"
FILES = File(..., description=f"Chart screenshots ({SUPPORTED_LABEL})")


def provider_error(error: httpx.HTTPStatusError) -> str:
    """Surface the provider's own message (quota exhausted, bad key, rate limit) instead of a bare status code."""
    try:
        body = error.response.json()
    except ValueError:
        return error.response.text[:200] or "no details returned"
    detail = body.get("error") if isinstance(body, dict) else None
    if isinstance(detail, dict) and detail.get("message"):
        return str(detail["message"])[:300]
    return str(body)[:300]


app = FastAPI(
    title="AI Chart Scanner",
    version="1.0.0",
    description="Screenshot-only chart analysis. No broker connection, no order placement.",
)


@app.get("/api/health")
def health() -> dict:
    provider = get_provider()
    return {
        "status": "ok",
        "provider": provider.name,
        "demo_mode": provider.name == "demo",
        "min_risk_reward": min_risk_reward(),
        "min_confidence": MIN_CONFIDENCE,
        "max_images": MAX_IMAGES,
    }


@app.post("/api/scan", response_model=ScanResult)
async def scan(
    files: list[UploadFile] = FILES,
    symbol: str = Form(""),
    entry_timeframe: str = Form("M15"),
    timeframes: str = Form("", description="Optional comma separated timeframe hints matching the file order"),
    notes: str = Form(""),
) -> ScanResult:
    if not files:
        raise HTTPException(status_code=400, detail="Upload at least one chart screenshot.")
    if len(files) > MAX_IMAGES:
        raise HTTPException(status_code=400, detail=f"Upload at most {MAX_IMAGES} screenshots.")

    hints = [hint.strip() for hint in timeframes.split(",")] if timeframes else []
    images: list[ChartImage] = []
    for index, upload in enumerate(files):
        name = upload.filename or f"chart-{index + 1}"
        data = await upload.read()
        if not data:
            raise HTTPException(status_code=400, detail=f"{name} is empty.")
        if len(data) > MAX_IMAGE_BYTES:
            raise HTTPException(
                status_code=413,
                detail=f"{name} is larger than {MAX_IMAGE_BYTES // (1024 * 1024)} MB.",
            )
        try:
            media_type, data = prepare_image(data)
        except UnsupportedImage as error:
            raise HTTPException(status_code=400, detail=f"{name}: {error}") from error
        images.append(
            ChartImage(
                filename=name,
                media_type=media_type,
                data=data,
                timeframe=hints[index] if index < len(hints) else "",
            )
        )

    try:
        provider = get_provider()
    except RuntimeError as error:
        raise HTTPException(status_code=500, detail=str(error)) from error

    try:
        return scan_charts(
            provider,
            images,
            symbol=symbol.strip(),
            entry_timeframe=entry_timeframe.strip() or "M15",
            notes=notes.strip(),
        )
    except httpx.HTTPStatusError as error:
        raise HTTPException(
            status_code=502,
            detail=(
                f"The vision model rejected the request ({error.response.status_code}): "
                f"{provider_error(error)}"
            ),
        ) from error
    except httpx.HTTPError as error:
        raise HTTPException(status_code=504, detail=f"The vision model request failed: {error}") from error
    except (json.JSONDecodeError, ValidationError, KeyError, TypeError) as error:
        raise HTTPException(
            status_code=502,
            detail=f"Could not parse an analysis from the model response: {error}",
        ) from error


@app.get("/")
def index() -> FileResponse:
    # No-store keeps phones from pinning an old shell that points at stale asset versions.
    return FileResponse(STATIC_DIR / "index.html", headers={"Cache-Control": "no-store"})


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
