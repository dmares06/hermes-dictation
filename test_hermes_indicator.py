import unittest

from hermes_indicator import IndicatorActivity


class IndicatorActivityTests(unittest.TestCase):
    def test_listening_stays_visible_when_older_transcription_finishes(self):
        activity = IndicatorActivity()
        activity.begin_transcribing()
        activity.begin_listening()

        activity.end_transcribing()

        self.assertEqual(activity.state, "listening")

    def test_overlapping_transcriptions_hide_only_after_last_completion(self):
        activity = IndicatorActivity()
        activity.begin_transcribing()
        activity.begin_transcribing()

        activity.end_transcribing()
        self.assertEqual(activity.state, "transcribing")

        activity.end_transcribing()
        self.assertIsNone(activity.state)

    def test_recording_transitions_directly_to_transcribing(self):
        activity = IndicatorActivity()
        activity.begin_listening()

        activity.begin_transcribing()

        self.assertFalse(activity.listening)
        self.assertEqual(activity.state, "transcribing")

    def test_extra_completion_cannot_make_count_negative(self):
        activity = IndicatorActivity()

        activity.end_transcribing()

        self.assertEqual(activity.transcriptions, 0)
        self.assertIsNone(activity.state)


if __name__ == "__main__":
    unittest.main()
