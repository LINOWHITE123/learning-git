import os

from .providers import AnthropicVisionProvider, DemoProvider, OpenAIVisionProvider, VisionProvider

DEFAULT_MIN_RR = 2.0
MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_IMAGES = 3
ALLOWED_MEDIA_TYPES = {"image/png", "image/jpeg", "image/webp"}


def min_risk_reward() -> float:
    return float(os.getenv("MIN_RISK_REWARD", DEFAULT_MIN_RR))


def get_provider() -> VisionProvider:
    """Pick the vision backend from the environment, falling back to offline demo mode."""
    requested = os.getenv("VISION_PROVIDER", "").strip().lower()
    openai_key = os.getenv("OPENAI_API_KEY", "").strip()
    anthropic_key = os.getenv("ANTHROPIC_API_KEY", "").strip()

    if requested == "demo":
        return DemoProvider()
    if requested == "openai" or (not requested and openai_key):
        if not openai_key:
            raise RuntimeError("VISION_PROVIDER=openai but OPENAI_API_KEY is not set")
        return OpenAIVisionProvider(openai_key, os.getenv("OPENAI_MODEL", "gpt-4o"))
    if requested == "anthropic" or (not requested and anthropic_key):
        if not anthropic_key:
            raise RuntimeError("VISION_PROVIDER=anthropic but ANTHROPIC_API_KEY is not set")
        return AnthropicVisionProvider(anthropic_key, os.getenv("ANTHROPIC_MODEL", "claude-sonnet-4-20250514"))
    if requested:
        raise RuntimeError(f"Unknown VISION_PROVIDER: {requested}")
    return DemoProvider()
