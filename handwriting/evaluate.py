"""Evaluate exported personal ink samples. Standard library only; no uploads."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re
import statistics
import unicodedata

def normalize(text):
    return unicodedata.normalize("NFC", text.replace("\r\n", "\n"))

def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (x != y)))
        previous = current
    return previous[-1]

def critical(text):
    # Report token mismatches, not a semantic equivalence claim.
    return Counter(re.findall(r"[不没无非未]|\b(?:not|no|never)\b", text, re.I)), re.findall(r"[0-9]+(?:\.[0-9]+)?", text)

def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)

def evaluate(samples):
    groups = defaultdict(list)
    skipped = 0
    for sample in samples:
        if not isinstance(sample.get("groundTruth"), str) or not sample["groundTruth"]:
            skipped += 1
            continue
        if not isinstance(sample.get("recognizedText"), str):
            raise ValueError("Sample lacks recognizedText")
        groups[sample.get("engine", "unknown")].append(sample)
    report = {"skippedUnlabelled": skipped, "engines": {}}
    for engine, rows in groups.items():
        errors = characters = compact_errors = compact_characters = exact = neg_errors = digit_errors = 0
        times = []
        for row in rows:
            truth, predicted = normalize(row["groundTruth"]), normalize(row["recognizedText"])
            errors += distance(truth, predicted); characters += len(truth)
            compact_truth, compact_predicted = re.sub(r"\s", "", truth), re.sub(r"\s", "", predicted)
            compact_errors += distance(compact_truth, compact_predicted); compact_characters += len(compact_truth)
            exact += truth == predicted
            expected_critical, actual_critical = critical(truth), critical(predicted)
            neg_errors += expected_critical[0] != actual_critical[0]
            digit_errors += expected_critical[1] != actual_critical[1]
            if isinstance(row.get("engineMilliseconds"), (int, float)):
                times.append(row["engineMilliseconds"])
        report["engines"][engine] = {
            "samples": len(rows), "characterErrorRate": errors / max(1, characters),
            "characterErrorRateIgnoringWhitespace": compact_errors / max(1, compact_characters),
            "exactSentenceRate": exact / len(rows), "negationTokenMismatchRate": neg_errors / len(rows),
            "digitSequenceMismatchRate": digit_errors / len(rows),
            "reportedLatencyP50Ms": statistics.median(times) if times else None,
            "reportedLatencyP95Ms": percentile(times, .95),
        }
    return report

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("samples", nargs="+", type=Path, help="Exported JSON files or folders")
    args = parser.parse_args()
    paths = sorted({file for path in args.samples for file in (path.glob("*.json") if path.is_dir() else [path])})
    samples = [json.loads(path.read_text(encoding="utf-8")) for path in paths]
    print(json.dumps(evaluate(samples), ensure_ascii=False, indent=2))
