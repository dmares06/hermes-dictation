# Session activation failed regression

Device-gated check (`GSTACK_HAS_IOS_DEVICE=1`):

1. Install the signed app on the paired iPhone.
2. Run the **Start Dictation** App Shortcut while WhisperDict is not foregrounded.
3. Assert that WhisperDict opens on the Dictation tab and starts recording.
4. Run the Shortcut again and assert that recording stops and transcription begins.
5. Assert that App Group state no longer contains `Session activation failed`.

The checked-in Swift tests verify the foreground recording deep-link contract. The physical-device step verifies the iOS privacy boundary that a simulator or unit test cannot reproduce.
