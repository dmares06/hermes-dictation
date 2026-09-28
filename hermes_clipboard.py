"""Paste text via the clipboard without losing what the user had copied."""

import threading
import time

DEFAULT_RESTORE_DELAY = 1.5


class ClipboardPaster:
    """Put text on the clipboard, press ⌘V, then put the old clipboard back.

    The target app reads the clipboard asynchronously after ⌘V. Restoring too
    early makes it paste the *previous* clipboard instead of the transcript,
    so we wait generously, and skip the restore entirely if the user copied
    something new in the meantime.
    """

    def __init__(self, pasteboard, send_paste, restore_delay=DEFAULT_RESTORE_DELAY,
                 sleep=time.sleep):
        self._pasteboard = pasteboard
        self._send_paste = send_paste
        self._restore_delay = restore_delay
        self._sleep = sleep
        # Serialize pastes so a second dictation never snapshots the first
        # dictation's transcript as "the user's clipboard".
        self._lock = threading.Lock()

    def paste(self, text: str) -> None:
        if not text:
            return
        with self._lock:
            saved = self._pasteboard.snapshot()
            ours = self._pasteboard.write_text(text)
            self._send_paste()
            self._sleep(self._restore_delay)
            if self._pasteboard.change_count() == ours:
                self._pasteboard.restore(saved)


class MacPasteboard:
    """NSPasteboard adapter that preserves every item and type (text, images, files)."""

    def __init__(self):
        from AppKit import NSPasteboard

        self._pb = NSPasteboard.generalPasteboard()

    def snapshot(self):
        items = []
        for item in self._pb.pasteboardItems() or []:
            data = {}
            for kind in item.types():
                value = item.dataForType_(kind)
                if value is not None:
                    data[kind] = value
            if data:
                items.append(data)
        return items

    def write_text(self, text):
        from AppKit import NSPasteboardTypeString

        self._pb.clearContents()
        self._pb.setString_forType_(text, NSPasteboardTypeString)
        return self._pb.changeCount()

    def change_count(self):
        return self._pb.changeCount()

    def restore(self, snapshot):
        from AppKit import NSPasteboardItem

        self._pb.clearContents()
        if not snapshot:
            return
        items = []
        for data in snapshot:
            item = NSPasteboardItem.alloc().init()
            for kind, value in data.items():
                item.setData_forType_(value, kind)
            items.append(item)
        self._pb.writeObjects_(items)
