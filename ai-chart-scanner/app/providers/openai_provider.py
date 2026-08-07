import base64
import json

import httpx

from .base import ChartImage, VisionProvider

API_URL = "https://api.openai.com/v1/chat/completions"


class OpenAIVisionProvider(VisionProvider):
    name = "openai"

    def __init__(self, api_key: str, model: str = "gpt-4o", timeout: float = 120.0):
        self.api_key = api_key
        self.model = model
        self.timeout = timeout

    def analyze(self, images: list[ChartImage], system_prompt: str, user_prompt: str) -> dict:
        content: list[dict] = [{"type": "text", "text": user_prompt}]
        for image in images:
            encoded = base64.b64encode(image.data).decode()
            label = image.timeframe or image.filename
            content.append({"type": "text", "text": f"Chart: {label}"})
            content.append(
                {
                    "type": "image_url",
                    "image_url": {"url": f"data:{image.media_type};base64,{encoded}", "detail": "high"},
                }
            )

        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": content},
            ],
            "response_format": {"type": "json_object"},
            "temperature": 0.1,
            "max_tokens": 4000,
        }
        response = httpx.post(
            API_URL,
            json=payload,
            headers={"Authorization": f"Bearer {self.api_key}"},
            timeout=self.timeout,
        )
        response.raise_for_status()
        text = response.json()["choices"][0]["message"]["content"]
        return json.loads(text)
