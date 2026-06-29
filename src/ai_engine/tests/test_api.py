from datetime import datetime, timedelta

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)

# Tests use an UNREGISTERED service so the engine exercises its in-window fallback
# (deterministic, no baseline coupling).
TEST_SVC = "test-svc"
TENANT = "tnt-1"
HEADERS = {"X-Tenant-Id": TENANT, "Authorization": "SigV4"}


def generate_baseline(metric_type, start_val, count=120, service_id=TEST_SVC, tenant_id=TENANT):
    base_ts = datetime(2026, 6, 25, 9, 0, 0)
    return [{"ts": (base_ts + timedelta(minutes=i)).isoformat() + "Z",
             "tenant_id": tenant_id, "service_id": service_id, "metric_type": metric_type,
             "value": start_val + (i % 3 - 1)} for i in range(count)]


def _payload(window):
    return {"signal_window": window,
            "context": {"deployment_version": "v1",
                        "time_range": {"start_ts": "2026-06-25T09:00:00Z",
                                       "end_ts": "2026-06-25T11:00:00Z"}}}


def test_health_check():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "healthy"


def test_detect_happy_path():
    r = client.post("/v1/predict", json=_payload(generate_baseline("cpu_usage_percent", 50)), headers=HEADERS)
    assert r.status_code == 200
    data = r.json()
    assert data["anomaly"] is False
    assert data["recommendation"] is None


def test_detect_sudden_spike():
    window = generate_baseline("cpu_usage_percent", 50, 119)
    window.append({"ts": "2026-06-25T10:59:00Z", "tenant_id": TENANT, "service_id": TEST_SVC,
                   "metric_type": "cpu_usage_percent", "value": 98})
    r = client.post("/v1/predict", json=_payload(window), headers=HEADERS)
    assert r.status_code == 200
    data = r.json()
    assert data["anomaly"] is True
    assert data["recommendation"]["action_verb"] == "SCALE_UP"
    assert "audit_id" in data


def test_detect_slow_leak():
    window = generate_baseline("memory_usage_percent", 40, 119)
    window.append({"ts": "2026-06-25T10:59:00Z", "tenant_id": TENANT, "service_id": TEST_SVC,
                   "metric_type": "memory_usage_percent", "value": 92})
    r = client.post("/v1/predict", json=_payload(window), headers=HEADERS)
    assert r.status_code == 200
    assert r.json()["anomaly"] is True
    assert r.json()["recommendation"]["action_verb"] == "ROLLBACK"


def test_detect_sudden_drop():
    window = generate_baseline("throughput_rps", 1000, 119)
    window.append({"ts": "2026-06-25T10:59:00Z", "tenant_id": TENANT, "service_id": TEST_SVC,
                   "metric_type": "throughput_rps", "value": 50})
    r = client.post("/v1/predict", json=_payload(window), headers=HEADERS)
    assert r.status_code == 200
    assert r.json()["recommendation"]["action_verb"] == "INVESTIGATE"


def test_missing_tenant_id_is_401():
    r = client.post("/v1/predict", json=_payload(generate_baseline("cpu_usage_percent", 50)),
                    headers={"Authorization": "SigV4"})
    assert r.status_code == 401  # contract: missing tenant header -> 401


def test_less_than_120_points_is_422():
    r = client.post("/v1/predict", json=_payload(generate_baseline("cpu_usage_percent", 50, 119)),
                    headers=HEADERS)
    assert r.status_code == 422  # contract: schema validation failure -> 422


def test_missing_field_is_422():
    bad = generate_baseline("cpu_usage_percent", 50)
    for dp in bad:
        dp.pop("metric_type")  # mandatory field removed
    r = client.post("/v1/predict", json=_payload(bad), headers=HEADERS)
    assert r.status_code == 422


def test_tenant_id_mismatch_is_400():
    window = generate_baseline("cpu_usage_percent", 50, tenant_id="tnt-OTHER")  # != header tnt-1
    r = client.post("/v1/predict", json=_payload(window), headers=HEADERS)
    assert r.status_code == 400  # well-formed but cross-tenant input -> 400
