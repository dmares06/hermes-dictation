# Keyboard URL scheme prohibited regression

Given the WhisperDict custom keyboard is visible and no dictation is active,
when the user taps the keyboard's recording control,
then the keyboard must show Action Button guidance and must not ask its extension context to open `whisperdict://record`.

The supported recording entry point is the Start Dictation App Shortcut, normally assigned to the iPhone Action Button.
