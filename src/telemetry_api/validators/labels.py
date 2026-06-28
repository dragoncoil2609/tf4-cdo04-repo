"""Quy tắc validation để label telemetry an toàn, không chứa PII và Cardinality cao."""

from __future__ import annotations

import re
from typing import Any

# Danh sách cấm do có chứa PII hoặc định danh cá nhân/tài chính
PII_DENYLIST_KEYS = frozenset(
    {
        "email",
        "phone",
        "name",
        "transaction_id",
        "account_id",
        "card_pan",
        "user_id",
        "request_id",
        "trace_id",
        "prediction_id",
    }
)

# Danh sách cấm do gây bùng nổ số lượng label trong database (High Cardinality)
HIGH_CARDINALITY_LABEL_KEYS = frozenset(
    {
        "request_id",
        "trace_id",
        "session_id",
        "user_id",
        "transaction_id",
        "prediction_id",
        "account_id",
        "card_pan",
        "raw_path",
        "path_with_id",
    }
)

# Các marker phát hiện nhãn nhạy cảm trong value hoặc key
SENSITIVE_VALUE_MARKERS = frozenset(
    {
        "email",
        "phone",
        "password",
        "token",
        "secret",
        "authorization",
        "api_key",
        "credential",
        "card_pan",
        "account_id",
        "transaction_id",
    }
)

# Regex dùng để phát hiện dynamic ID trong path segment
_UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_PREFIX_ID_RE = re.compile(r"^[a-zA-Z]+_[0-9a-zA-Z]+$")
_MIXED_ID_RE = re.compile(r"^(?=.*[0-9])(?=.*[a-zA-Z])[0-9a-zA-Z\-]+$")


def is_dynamic_id_segment(segment: str) -> bool:
    """Kiểm tra xem một segment trong path có chứa dynamic ID hay không."""

    if not segment:
        return False

    # Bỏ qua các segment phiên bản tĩnh như v1, v2, v10
    if re.match(r"^[vV]\d+$", segment):
        return False

    # 1. Số nguyên thuần túy (e.g. 12345)
    if segment.isdigit():
        return True

    # 2. Định dạng UUID
    if _UUID_RE.match(segment):
        return True

    # 3. Định danh có prefix (e.g. acc_123, txn_999) - phải chứa ít nhất 1 chữ số
    if _PREFIX_ID_RE.match(segment):
        if any(c.isdigit() for c in segment):
            return True

    # 4. Kiểu chuỗi hỗn hợp (e.g. abc-123-def, xyz123) - phải dài >= 4 và chứa cả chữ và số
    if len(segment) >= 4 and _MIXED_ID_RE.match(segment):
        return True

    return False


def looks_like_raw_path_with_ids(value: str) -> bool:
    """Phát hiện nếu value của label trông giống như một raw endpoint path chứa dynamic ID."""

    if "/" not in value:
        return False

    # Phân tách path thành các segment để kiểm tra từng phần
    segments = [s.strip() for s in value.split("/")]
    for seg in segments:
        if is_dynamic_id_segment(seg):
            return True

    return False


def validate_labels(labels: Any) -> dict[str, Any]:
    """Kiểm tra tính hợp lệ, an toàn về bảo mật (PII) và hiệu năng (Cardinality) của labels.

    Args:
        labels: Dữ liệu nhãn truyền lên từ client.

    Returns:
        Một dict chứa các labels hợp lệ.
    """

    if labels is None:
        return {}

    if not isinstance(labels, dict):
        raise ValueError("labels must be a JSON object")

    for key, value in labels.items():
        if not isinstance(key, str) or not key.strip():
            raise ValueError("label keys must be non-empty strings")

        # Chuẩn hóa key
        key_normalized = key.strip().lower()

        # 1. Từ chối nếu key thuộc danh sách cấm PII hoặc chứa marker nhạy cảm
        if key_normalized in PII_DENYLIST_KEYS or _contains_sensitive_marker(key_normalized):
            raise ValueError(f"label key is denied by PII policy: {key}")

        # 2. Từ chối nếu key thuộc danh sách cấm High Cardinality
        if key_normalized in HIGH_CARDINALITY_LABEL_KEYS:
            raise ValueError(f"label key is denied by high-cardinality policy: {key}")

        # 3. Từ chối nested object hoặc array
        if isinstance(value, (dict, list)):
            raise ValueError(f"labels cannot contain nested objects or arrays for key '{key}'")

        # 4. Chỉ cho phép kiểu dữ liệu đơn giản: string, number, boolean, null (None)
        if value is not None:
            if isinstance(value, bool):
                pass
            elif isinstance(value, (int, float)):
                pass
            elif isinstance(value, str):
                # Kiểm tra xem value chuỗi có chứa nhãn nhạy cảm (PII) không
                if _contains_sensitive_marker(value):
                    raise ValueError(f"label value is denied by PII policy: contains sensitive data marker")

                # Kiểm tra xem value chuỗi có chứa raw endpoint path kèm dynamic ID không
                if looks_like_raw_path_with_ids(value):
                    raise ValueError("label value is denied because it looks like raw endpoint path with IDs")
            else:
                raise ValueError(f"label '{key}' value must be string, number, boolean or null")

    return labels


def _contains_sensitive_marker(value: str) -> bool:
    """Trả về True khi value của label chứa dấu hiệu dữ liệu nhạy cảm."""

    val_lower = value.lower()
    return any(marker in val_lower for marker in SENSITIVE_VALUE_MARKERS)
