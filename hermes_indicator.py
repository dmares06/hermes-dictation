"""State coordination for Hermes' floating dictation indicator."""

from dataclasses import dataclass


@dataclass
class IndicatorActivity:
    """Track overlapping recording and transcription activity safely."""

    listening: bool = False
    transcriptions: int = 0

    @property
    def state(self) -> str | None:
        if self.listening:
            return "listening"
        if self.transcriptions:
            return "transcribing"
        return None

    def begin_listening(self) -> None:
        self.listening = True

    def end_listening(self) -> None:
        self.listening = False

    def begin_transcribing(self) -> None:
        # Releasing the hotkey transitions the active recording directly into
        # transcription. Older transcription jobs may still be in flight.
        self.listening = False
        self.transcriptions += 1

    def end_transcribing(self) -> None:
        self.transcriptions = max(0, self.transcriptions - 1)
