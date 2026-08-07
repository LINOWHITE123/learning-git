from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass
class ChartImage:
    """A single uploaded chart screenshot."""

    filename: str
    media_type: str
    data: bytes
    timeframe: str = ""


class VisionProvider(ABC):
    """A model backend able to turn chart screenshots into a structured analysis payload."""

    name: str = "base"

    @abstractmethod
    def analyze(self, images: list[ChartImage], system_prompt: str, user_prompt: str) -> dict:
        """Return the raw analysis dict as produced by the model."""
