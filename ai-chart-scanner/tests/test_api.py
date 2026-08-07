import io

import pytest
from fastapi.testclient import TestClient

from app.main import app

PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00"
    b"\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00"
    b"\x00IEND\xaeB`\x82"
)


@pytest.fixture(autouse=True)
def demo_mode(monkeypatch):
    monkeypatch.setenv("VISION_PROVIDER", "demo")


@pytest.fixture()
def client():
    return TestClient(app)


def upload(name: str, media_type: str = "image/png", data: bytes = PNG):
    return ("files", (name, io.BytesIO(data), media_type))


def test_health_reports_demo_mode(client):
    body = client.get("/api/health").json()
    assert body["provider"] == "demo"
    assert body["demo_mode"] is True
    assert body["max_images"] == 3


def test_index_is_served(client):
    response = client.get("/")
    assert response.status_code == 200
    assert "AI Chart Scanner" in response.text


def test_scan_multi_timeframe(client):
    response = client.post(
        "/api/scan",
        files=[upload("gold-4h.png"), upload("gold-1h.png"), upload("gold-15m.png")],
        data={"symbol": "XAUUSD", "entry_timeframe": "M15"},
    )
    assert response.status_code == 200
    result = response.json()
    assert result["timeframes_analyzed"] == ["H4", "H1", "M15"]
    assert result["signal"] in ("long", "short")
    assert result["setup"]["risk_reward"] >= 2.0
    assert result["setup"]["invalidation"] is not None
    assert any("News data is not available" in warning for warning in result["warnings"])


def test_scan_single_timeframe_warns(client):
    response = client.post("/api/scan", files=[upload("chart-15m.png")], data={"timeframes": "M15"})
    assert response.status_code == 200
    assert any("confirmation unavailable" in warning for warning in response.json()["warnings"])


def test_scan_accepts_jpeg_and_webp(client):
    for name, media_type in (("chart.jpg", "image/jpeg"), ("chart.webp", "image/webp")):
        response = client.post("/api/scan", files=[upload(name, media_type)])
        assert response.status_code == 200, response.text


def test_scan_rejects_non_image(client):
    response = client.post("/api/scan", files=[upload("notes.txt", "text/plain", b"hello")])
    assert response.status_code == 400


def test_scan_rejects_empty_file(client):
    response = client.post("/api/scan", files=[upload("empty.png", "image/png", b"")])
    assert response.status_code == 400


def test_scan_rejects_too_many_files(client):
    response = client.post("/api/scan", files=[upload(f"chart-{i}.png") for i in range(4)])
    assert response.status_code == 400
