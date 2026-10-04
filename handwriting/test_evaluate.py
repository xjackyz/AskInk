import unittest
from evaluate import distance, evaluate

class EvaluationTests(unittest.TestCase):
    def test_negation_loss_is_not_hidden_by_low_cer(self):
        report = evaluate([{"groundTruth": "为什么不是这样", "recognizedText": "为什么是这样", "engine": "test"}])["engines"]["test"]
        self.assertEqual(report["negationTokenMismatchRate"], 1)
        self.assertGreater(report["characterErrorRate"], 0)

    def test_numeric_mistake_and_candidate_not_corrected_text(self):
        report = evaluate([{"groundTruth": "123", "recognizedText": "128", "selectedText": "123", "engine": "test"}])["engines"]["test"]
        self.assertEqual(report["digitSequenceMismatchRate"], 1)
        self.assertEqual(report["exactSentenceRate"], 0)

    def test_whitespace_metrics_are_separate(self):
        report = evaluate([{"groundTruth": "AI 123", "recognizedText": "AI123", "engine": "test"}])["engines"]["test"]
        self.assertGreater(report["characterErrorRate"], 0)
        self.assertEqual(report["characterErrorRateIgnoringWhitespace"], 0)

    def test_unlabelled_not_counted_as_success(self):
        self.assertEqual(evaluate([{"groundTruth": "", "recognizedText": "字"}])["skippedUnlabelled"], 1)

    def test_insertions_deletions_and_substitutions(self):
        self.assertEqual(distance("abc", "axcd"), 2)

if __name__ == "__main__":
    unittest.main()
