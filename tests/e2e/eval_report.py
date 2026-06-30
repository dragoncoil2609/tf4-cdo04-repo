#!/usr/bin/env python3
"""Build mentor-facing eval metrics from generated evidence/logs artifacts."""

import argparse
import json
import math
from pathlib import Path

EVIDENCE = Path("evidence")
RECOMMENDATION_FIELDS = {"action_verb", "target", "from_to", "confidence", "evidence_link"}


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def ddb_value(value):
    if not isinstance(value, dict):
        return value
    if "S" in value:
        return value["S"]
    if "N" in value:
        number = value["N"]
        try:
            return int(number) if number.isdigit() else float(number)
        except ValueError:
            return number
    if "BOOL" in value:
        return value["BOOL"]
    if "NULL" in value:
        return None
    return value


def normalize_item(item):
    return {key: ddb_value(value) for key, value in item.items()}


def load_audit_items(path):
    data = load_json(path, {})
    raw_items = data.get("Items", data if isinstance(data, list) else [])
    return [normalize_item(item) for item in raw_items]


def key_for(item):
    return item.get("prediction_id") or item.get("scenario_id") or f"{item.get('tenant_id')}:{item.get('service_id')}"


def confusion_matrix(ground_truth, audit_items):
    by_id = {key_for(item): item for item in audit_items}
    counts = {"tp": 0, "fp": 0, "tn": 0, "fn": 0}
    rows = []
    for scenario in ground_truth.get("scenarios", []):
        scenario_id = scenario["scenario_id"]
        expected = bool(scenario["expected_anomaly"])
        item = by_id.get(scenario_id)
        predicted = bool(item and item.get("anomaly"))
        if expected and predicted:
            bucket = "tp"
        elif not expected and predicted:
            bucket = "fp"
        elif not expected and not predicted:
            bucket = "tn"
        else:
            bucket = "fn"
        counts[bucket] += 1
        rows.append({"scenario_id": scenario_id, "expected": expected, "predicted": predicted, "bucket": bucket})
    return counts, rows


def safe_div(a, b):
    return a / b if b else 0.0


def metrics_from_counts(counts):
    tp, fp, tn, fn = counts["tp"], counts["fp"], counts["tn"], counts["fn"]
    precision = safe_div(tp, tp + fp)
    recall = safe_div(tp, tp + fn)
    f1 = safe_div(2 * precision * recall, precision + recall)
    fp_rate = safe_div(fp, fp + tn)
    return {"precision": precision, "recall": recall, "f1": f1, "fp_rate": fp_rate}


def confidence(item):
    for key in ("recommendation_confidence", "score", "severity"):
        if key in item and item[key] not in (None, ""):
            try:
                return max(0.0, min(1.0, float(item[key])))
            except (TypeError, ValueError):
                pass
    return 0.0


def brier_and_bins(ground_truth, audit_items):
    by_id = {key_for(item): item for item in audit_items}
    pairs = []
    for scenario in ground_truth.get("scenarios", []):
        item = by_id.get(scenario["scenario_id"], {})
        pairs.append((confidence(item), 1.0 if scenario["expected_anomaly"] else 0.0))
    if not pairs:
        return None, []
    brier = sum((p - y) ** 2 for p, y in pairs) / len(pairs)
    bins = []
    for idx in range(10):
        low, high = idx / 10, (idx + 1) / 10
        bucket = [(p, y) for p, y in pairs if low <= p < high or (idx == 9 and p == 1.0)]
        if not bucket:
            bins.append({"bin": f"{low:.1f}-{high:.1f}", "count": 0, "avg_confidence": None, "observed_rate": None})
            continue
        bins.append({
            "bin": f"{low:.1f}-{high:.1f}",
            "count": len(bucket),
            "avg_confidence": sum(p for p, _ in bucket) / len(bucket),
            "observed_rate": sum(y for _, y in bucket) / len(bucket),
        })
    return brier, bins


def recommendation_contract(item):
    if not item.get("anomaly"):
        return True
    present = {
        "action_verb": item.get("recommendation_action") or item.get("action_verb"),
        "target": item.get("recommendation_target") or item.get("target"),
        "from_to": item.get("recommendation_from_to") or item.get("from_to"),
        "confidence": item.get("recommendation_confidence") or item.get("confidence"),
        "evidence_link": item.get("recommendation_evidence") or item.get("evidence_link"),
    }
    return all(present.values())


def load_k6(path):
    data = load_json(path, {})
    metrics = data.get("metrics", {})
    return {
        "http_req_failed_rate": metrics.get("http_req_failed", {}).get("rate"),
        "http_req_duration_p95": metrics.get("http_req_duration", {}).get("percentiles", {}).get("p(95)"),
        "dropped_iterations": metrics.get("dropped_iterations", {}).get("count", 0),
        "thresholds": data.get("root_group", {}).get("checks", []),
    }


def write_markdown(report, path):
    lines = [
        "# TF4 Final Eval Evidence",
        "",
        f"- Status: **{report['status'].upper()}**",
        f"- Precision: {report['metrics']['precision']:.3f}",
        f"- Recall / catch rate: {report['metrics']['recall']:.3f}",
        f"- F1: {report['metrics']['f1']:.3f}",
        f"- FP rate: {report['metrics']['fp_rate']:.3f}",
        f"- Brier score: {report['brier_score'] if report['brier_score'] is not None else 'N/A'}",
        "",
        "## Confusion matrix",
        "",
        "| TP | FP | TN | FN |",
        "|---:|---:|---:|---:|",
        f"| {report['confusion_matrix']['tp']} | {report['confusion_matrix']['fp']} | {report['confusion_matrix']['tn']} | {report['confusion_matrix']['fn']} |",
        "",
        "## Gate checks",
        "",
        "| Gate | Pass |",
        "|---|---|",
    ]
    for name, passed in report["gates"].items():
        lines.append(f"| {name} | {'yes' if passed else 'no'} |")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Generate TF4 evaluation metrics from evidence artifacts.")
    parser.add_argument("--evidence-dir", default="evidence/logs")
    parser.add_argument("--dry-run", action="store_true", help="Use synthetic fixture if evidence is missing.")
    args = parser.parse_args()

    evidence = Path(args.evidence_dir)
    ground_truth = load_json(evidence / "tf4-scenario-ground-truth.json", {})
    audit_items = load_audit_items(evidence / "tf4-scenario-audit-scan.json")

    if args.dry_run and not ground_truth:
        ground_truth = {"scenarios": [
            {"scenario_id": "gradual-drift-ledger", "expected_anomaly": True},
            {"scenario_id": "sudden-spike-payment-gw", "expected_anomaly": True},
            {"scenario_id": "slow-leak-fraud-detector", "expected_anomaly": True},
            {"scenario_id": "noisy-baseline-fraud-detector", "expected_anomaly": False},
        ]}
        audit_items = [
            {"prediction_id": "gradual-drift-ledger", "service_id": "ledger", "anomaly": True, "prediction_source": "AI_ENGINE", "evidence_status": "complete_window", "ai_status_code": 200, "recommendation_action": "SCALE_UP", "recommendation_target": "ledger ECS Service", "recommendation_from_to": "2 -> 3 tasks", "recommendation_confidence": 0.9, "recommendation_evidence": "https://dashboard.internal/metrics/ledger"},
            {"prediction_id": "sudden-spike-payment-gw", "service_id": "payment-gw", "anomaly": True, "prediction_source": "AI_ENGINE", "evidence_status": "complete_window", "ai_status_code": 200, "recommendation_action": "INVESTIGATE", "recommendation_target": "payment-gw ALB", "recommendation_from_to": "baseline -> spike", "recommendation_confidence": 0.8, "recommendation_evidence": "https://dashboard.internal/metrics/payment-gw"},
            {"prediction_id": "slow-leak-fraud-detector", "service_id": "fraud-detector", "anomaly": True, "prediction_source": "AI_ENGINE", "evidence_status": "complete_window", "ai_status_code": 200, "recommendation_action": "ROLLBACK", "recommendation_target": "fraud-detector deployment", "recommendation_from_to": "current -> previous", "recommendation_confidence": 0.85, "recommendation_evidence": "https://dashboard.internal/metrics/fraud-detector"},
            {"prediction_id": "noisy-baseline-fraud-detector", "service_id": "fraud-detector", "anomaly": False, "prediction_source": "AI_ENGINE", "evidence_status": "complete_window", "ai_status_code": 200, "severity": 0.2},
        ]

    counts, rows = confusion_matrix(ground_truth, audit_items)
    metrics = metrics_from_counts(counts)
    brier, bins = brier_and_bins(ground_truth, audit_items)
    services = sorted({item.get("service_id") for item in audit_items if item.get("service_id")})
    ai_complete = all(
        item.get("prediction_source") == "AI_ENGINE" and item.get("evidence_status") == "complete_window" and int(item.get("ai_status_code", 0)) == 200
        for item in audit_items
    ) if audit_items else False
    recommendations_ok = all(recommendation_contract(item) for item in audit_items)

    gates = {
        "scenario_count_ge_4": len(ground_truth.get("scenarios", [])) >= 4,
        "service_count_ge_3": len(services) >= 3,
        "ai_complete_window": ai_complete,
        "recall_ge_80_pct": metrics["recall"] >= 0.80,
        "fp_rate_le_12_pct": metrics["fp_rate"] <= 0.12,
        "recommendations_complete": recommendations_ok,
        "brier_score_reported": brier is not None and not math.isnan(brier),
    }
    report = {
        "status": "pass" if all(gates.values()) else "fail",
        "confusion_matrix": counts,
        "metrics": metrics,
        "brier_score": brier,
        "reliability_bins": bins,
        "scenario_rows": rows,
        "services": services,
        "k6": {
            "50rps": load_k6(evidence / "acceptance-50rps-summary.json"),
            "100rps": load_k6(evidence / "acceptance-100rps-summary.json"),
        },
        "gates": gates,
    }

    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / "eval-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    write_markdown(report, evidence / "eval-report.md")
    print(json.dumps({"status": report["status"], "gates": gates}, indent=2))
    raise SystemExit(0 if report["status"] == "pass" else 1)


if __name__ == "__main__":
    main()
