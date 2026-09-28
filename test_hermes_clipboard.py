import threading
import unittest

from hermes_clipboard import ClipboardPaster


class FakePasteboard:
    """In-memory stand-in for NSPasteboard with a macOS-style change count."""

    def __init__(self, items):
        self.items = items
        self.count = 0

    def snapshot(self):
        return [dict(item) for item in self.items]

    def write_text(self, text):
        self.items = [{"public.utf8-plain-text": text}]
        self.count += 1
        return self.count

    def change_count(self):
        return self.count

    def restore(self, snapshot):
        self.items = snapshot
        self.count += 1

    def user_copies(self, text):
        self.write_text(text)


class ClipboardPasterTests(unittest.TestCase):
    def make_paster(self, board, during_wait=None, delay=1.5):
        pasted = []

        def send_paste():
            # Capture what the target app would read at the moment of ⌘V.
            pasted.append(board.items[0]["public.utf8-plain-text"])

        def sleep(seconds):
            self.slept = seconds
            if during_wait:
                during_wait()

        paster = ClipboardPaster(board, send_paste, restore_delay=delay, sleep=sleep)
        return paster, pasted

    def test_pastes_transcript_not_previous_clipboard(self):
        board = FakePasteboard([{"public.utf8-plain-text": "old copy"}])
        paster, pasted = self.make_paster(board)

        paster.paste("hello world")

        self.assertEqual(pasted, ["hello world"])

    def test_restores_previous_clipboard_after_delay(self):
        board = FakePasteboard([{"public.utf8-plain-text": "old copy"}])
        paster, _ = self.make_paster(board, delay=1.5)

        paster.paste("hello world")

        self.assertEqual(self.slept, 1.5)
        self.assertEqual(board.items, [{"public.utf8-plain-text": "old copy"}])

    def test_restores_non_text_clipboard_contents(self):
        image = {"public.png": b"\x89PNG..."}
        board = FakePasteboard([image])
        paster, _ = self.make_paster(board)

        paster.paste("hello")

        self.assertEqual(board.items, [image])

    def test_does_not_clobber_something_user_copied_meanwhile(self):
        board = FakePasteboard([{"public.utf8-plain-text": "old copy"}])
        paster, _ = self.make_paster(
            board, during_wait=lambda: board.user_copies("fresh copy")
        )

        paster.paste("hello")

        self.assertEqual(board.items, [{"public.utf8-plain-text": "fresh copy"}])

    def test_empty_text_leaves_clipboard_untouched(self):
        board = FakePasteboard([{"public.utf8-plain-text": "old copy"}])
        paster, pasted = self.make_paster(board)

        paster.paste("")

        self.assertEqual(pasted, [])
        self.assertEqual(board.count, 0)

    def test_back_to_back_pastes_restore_the_original_clipboard(self):
        board = FakePasteboard([{"public.utf8-plain-text": "old copy"}])
        paster, pasted = self.make_paster(board)

        threads = [
            threading.Thread(target=paster.paste, args=(text,))
            for text in ("first", "second")
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        self.assertCountEqual(pasted, ["first", "second"])
        self.assertEqual(board.items, [{"public.utf8-plain-text": "old copy"}])


if __name__ == "__main__":
    unittest.main()
