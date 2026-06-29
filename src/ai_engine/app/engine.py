"""Foresight Lens detection engine: STL seasonal baseline + EWMA control chart.

Design (matches docs/ADRs + 03_ai_engine_spec.md):
  - STL decomposition is done OFFLINE in scripts/train_baseline.py and stored as a
    per-service seasonal profile + residual sigma (cannot be learned in a 120-min window).
  - At inference, for each (service, metric) we:
      1. subtract the seasonal-expected level for each point's minute-of-day,
      2. run an EWMA control chart over the residual stream,
      3. raise an anomaly when the EWMA statistic breaches the K-sigma control limit.
  - EWMA smooths single spikes (controls false positives) while accumulating sustained
    drift early (gives lead time before the hard breach) -> fits capacity exhaustion.

If a service/metric has no trained baseline, we fall back to an in-window z-score so the
engine never hard-fails on an unregistered service (graceful degradation).
"""
from typing import List, Optional, Tuple

import numpy as np

from .baseline import load_baseline
from .models import SignalDatapoint

EWMA_ALPHA = 0.3        # responsiveness of the EWMA (tuned: see ADR-006)
SIGMA_K = 4.0           # control-limit width (K-sigma); tuned for FP 7.1% on holdout
MIN_POINTS = 3          # need a few points before judging

# Up-direction (capacity-exhaustion) recommendation templates keyed by metric_type.
# Verbs are drawn from the contract enum {SCALE_UP, SCALE_DOWN, RETIRE, ROLLBACK, INVESTIGATE}.
_RECS = {
    "cpu_usage_percent": ("SCALE_UP", "ECS Service", "Current -> +2 Tasks", "cpu",
                          "CPU drift detected. Scale out ECS service."),
    "queue_depth": ("SCALE_UP", "SQS Workers", "Current -> +5 Workers", "queue",
                    "Queue backlog building. Increase worker concurrency."),
    "memory_usage_percent": ("ROLLBACK", "Deployment", "v_latest -> v_previous", "mem",
                             "Memory drift toward OOM (suspected leak). Roll back recent deploy."),
}
_DEFAULT_REC = ("INVESTIGATE", "Resource", "N/A", "metric", "Anomalous drift detected.")


class AnomalyDetector:
    def _ewma_breach(self, residuals: np.ndarray, sigma: float) -> Tuple[bool, float, int]:
        """EWMA control chart. Returns (breached, last_statistic_ratio, direction)."""
        if sigma <= 0:
            sigma = 1.0
        z = 0.0  # residual baseline mean is ~0 after de-seasonalising
        for r in residuals:
            z = EWMA_ALPHA * r + (1 - EWMA_ALPHA) * z
        # asymptotic EWMA control limit
        limit = SIGMA_K * sigma * np.sqrt(EWMA_ALPHA / (2 - EWMA_ALPHA))
        if z > limit:
            return True, z / limit, 1
        if z < -limit:
            return True, abs(z) / limit, -1
        return False, abs(z) / limit if limit else 0.0, 0

    def _recommend(self, metric: str, service_id: str, direction: int, ratio: float,
                   below_frac: float = 0.0):
        if direction < 0:
            # Sustained under-utilisation vs the trained baseline -> right-size down, or
            # retire an idle resource (TF4 brief line 33: "retire queue Z không còn dùng").
            # A short, sharp drop (low below_frac) is a possible outage -> INVESTIGATE.
            if below_frac >= 0.5:
                if metric in ("queue_depth", "active_connections", "db_connection_pool_pct"):
                    verb, suffix, from_to, slug, reason = (
                        "RETIRE", "idle queue/pool", "active -> retired", metric,
                        "Sustained near-idle resource; retire to reclaim capacity.")
                else:
                    verb, suffix, from_to, slug, reason = (
                        "SCALE_DOWN", "ECS Service", "Current -> -1 Task", metric,
                        "Sustained under-utilisation; scale down to right-size cost.")
                conf = 0.75
                rec = {"action_verb": verb, "target": f"{service_id} {suffix}", "from_to": from_to,
                       "evidence_link": f"https://dashboard.internal/metrics/{service_id}/{slug}",
                       "confidence": conf}
                return rec, f"{reason} (service={service_id}, EWMA={ratio:.2f}x control limit)", conf
            return ({"action_verb": "INVESTIGATE", "target": f"{service_id}",
                     "from_to": "N/A",
                     "evidence_link": f"https://dashboard.internal/metrics/{service_id}/{metric}",
                     "confidence": 0.8},
                    f"Sudden drop in {metric} for {service_id}. Possible degradation/outage.", 0.8)
        confidence = round(float(min(0.99, 0.6 + 0.15 * (ratio - 1.0))), 2) if ratio >= 1 else 0.6
        verb, suffix, from_to, slug, reason = _RECS.get(metric, _DEFAULT_REC)
        rec = {"action_verb": verb, "target": f"{service_id} {suffix}", "from_to": from_to,
               "evidence_link": f"https://dashboard.internal/metrics/{service_id}/{slug}",
               "confidence": confidence}
        return rec, f"{reason} (service={service_id}, EWMA={ratio:.2f}x control limit)", confidence

    def detect_drift(self, tenant_id: str, signals: List[SignalDatapoint]
                     ) -> Tuple[bool, float, Optional[dict], str, float]:
        """Run STL-baseline + EWMA detection over the supplied window."""
        if not signals:
            return False, 0.0, None, "No signals provided", 1.0

        # Group by (service_id, metric_type)
        groups: dict = {}
        for s in signals:
            groups.setdefault((s.service_id, s.metric_type), []).append(s)

        for (service_id, metric), pts in groups.items():
            pts = sorted(pts, key=lambda p: p.ts)
            values = np.array([p.value for p in pts], dtype=float)
            if len(values) < MIN_POINTS:
                continue

            baseline = load_baseline(service_id)
            bm = baseline["metrics"].get(metric) if baseline else None
            if bm:
                # STL seasonal subtraction by minute-of-day
                profile = np.array(bm["seasonal_profile"], dtype=float)
                mod = np.array([p.ts.hour * 60 + p.ts.minute for p in pts]) % len(profile)
                residuals = values - profile[mod]
                sigma = float(bm["resid_std"])
            else:
                # Fallback: in-window z-score (no trained baseline for this service)
                residuals = values - float(np.mean(values))
                sigma = float(np.std(values)) or 1.0

            breached, ratio, direction = self._ewma_breach(residuals, sigma)
            if breached:
                severity = round(float(min(ratio / 3.0, 1.0)), 2)
                below_frac = float(np.mean(residuals < -sigma)) if direction < 0 else 0.0
                rec, reasoning, confidence = self._recommend(metric, service_id, direction, ratio, below_frac)
                return True, severity, rec, reasoning, confidence

        return False, 0.0, None, "No anomaly detected (EWMA within control limits).", 0.95
