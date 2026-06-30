"""
test_policy.py — CPOA-72 | CDO-W12-030
Kiểm chứng get_service_policy đọc đúng từ DynamoDB (mock).
"""
import fallback_engine as fe


def test_policy_found_returns_dict(mock_boto3_before_import, sample_policy):
    mock_boto3_before_import.get_item.return_value = {"Item": sample_policy}

    policy = fe.get_service_policy("demo-tenant-001", "payment-gateway")

    assert policy is not None
    assert policy["service_name"] == "payment-gateway"
    assert len(policy["fallback_rules"]) == 2
    # Đảm bảo gọi DynamoDB với đúng key
    mock_boto3_before_import.get_item.assert_called_once_with(
        Key={"tenant_id": "demo-tenant-001", "service_name": "payment-gateway"}
    )


def test_policy_not_found_returns_none(mock_boto3_before_import):
    mock_boto3_before_import.get_item.return_value = {}  # không có "Item"

    policy = fe.get_service_policy("demo-tenant-001", "unknown-service")

    assert policy is None


def test_policy_dynamodb_exception_returns_none(mock_boto3_before_import):
    mock_boto3_before_import.get_item.side_effect = Exception("DynamoDB unreachable")

    policy = fe.get_service_policy("demo-tenant-001", "payment-gateway")

    assert policy is None  # không raise ra ngoài, để caller tự xử lý (DLQ)


def test_policy_three_tier1_services(mock_boto3_before_import, sample_policy):
    """TF4 yêu cầu multi-service >= 3 — verify cả 3 service đều đọc được"""
    services = ["payment-gateway", "ledger-service", "kyc-worker"]

    for svc in services:
        policy_copy = {**sample_policy, "service_name": svc}
        mock_boto3_before_import.get_item.return_value = {"Item": policy_copy}

        policy = fe.get_service_policy("demo-tenant-001", svc)
        assert policy is not None
        assert policy["service_name"] == svc