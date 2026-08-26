# Keyboard Action Button no-op regression

Given the WhisperDict keyboard is visible and no dictation is active, the
keyboard control must not look like an in-keyboard recording button that can
open the containing app. It must explicitly tell the user to press the physical
side Action Button and explain that the supported shortcut keeps the current app
open. Idle, ready, failed, and transcribing guidance must not expose a fake
recording tap target.

When the background phase changes to recording, the same control remains an
active Stop button. When the new transcript revision becomes ready, the keyboard
inserts that session's transcript exactly once.
