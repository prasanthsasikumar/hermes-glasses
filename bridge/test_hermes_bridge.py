import unittest

from hermes_bridge import is_visual_query


class TestIsVisualQuery(unittest.TestCase):
    def test_visual_phrases_match(self):
        for phrase in [
            "What am I looking at?",
            "can you see this",
            "READ THIS for me",
            "what is this thing in front of me",
            "take a picture",
            "describe this photo",
            "use the camera",
        ]:
            self.assertTrue(is_visual_query(phrase), phrase)

    def test_non_visual_phrases_do_not_match(self):
        for phrase in [
            "what's the weather tomorrow",
            "tell me a joke",
            "who wrote hamlet",
        ]:
            self.assertFalse(is_visual_query(phrase), phrase)


if __name__ == "__main__":
    unittest.main()
