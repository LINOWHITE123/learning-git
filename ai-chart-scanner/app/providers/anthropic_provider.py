import base64
import json

import httpx

from .base import ChartImage, VisionProvider

API_URL = "https://api.anthropic.com/v1/messages"


class AnthropicVisionProvider(VisionProvider):
    name = "anthropic"

    def __init__(self, api_key: str, model: str = "claude-sonnet-4-20250514", timeout: float = 120.0):
        self.api_key = api_key
        self.model = model
        self.timeout = timeout

    def analyze(self, images: list[ChartImage], system_prompt: str, user_prompt: str) -> dict:
        content: list[dict] = []
        for image in images:
            encoded = base64.b64encode(image.data).decode()
            label = image.timeframe or image.filename
            content.append({"type": "text", "text": f"Chart: {label}"})
            content.append(
                {
                    "type": "image",
                    "source": {"type": "base64", "media_type": image.media_type, "data": encoded},
                }
            )
        content.append({"type": "text", "text": user_prompt})

        payload = {
            "model": self.model,
            "max_tokens": 4000,
            "temperature": 0.1,
            "system": system_prompt,
            "messages": [{"role": "user", "content": content}],
        }
        response = httpx.post(
            API_URL,
            json=payload,
            headers={"x-api-key": self.api_key, "anthropic-version": "2023-06-01"},
            timeout=self.timeout,
        )
        response.raise_for_status()
        text = "".join(block["text"] for block in response.json()["content"] if block["type"] == "text")
        return json.loads(_strip_fences(text))


def _strip_fences(text: str) -> str:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.split("\n", 1)[1] if "\n" in stripped else stripped
        stripped = stripped.rsplit("```", 1)[0]
    start = stripped.find("{")
    end = stripped.rfind("}")
    if start != -1 and end != -1:
        stripped = stripped[start : end + 1]
    return stripped.strip()
