# Shortcut custom URL launch regression

Given the iPhone Action Button runs the `Start WhisperDict` App Intent, the
intent must use the system-supported `openAppWhenRun` launch path. It must not
return an `OpenURLIntent` for the private `whisperdict` scheme. The intent
stores a one-time foreground recording request in the shared App Group, and
the containing app consumes that request exactly once after it becomes active.
