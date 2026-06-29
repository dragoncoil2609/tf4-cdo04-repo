"""Route GET /health cung cấp trạng thái dịch vụ và thông tin build."""

from __future__ import annotations

from fastapi import APIRouter, Request
from starlette.responses import JSONResponse

router = APIRouter()


@router.get("/health")
async def health(request: Request) -> JSONResponse:
    """Trả về trạng thái hoạt động và metadata tối giản, an toàn của API.

    Được sử dụng bởi các thiết bị kiểm tra Container, ECS Target Group và ALB.
    Đảm bảo tuyệt đối không rò rỉ bất kỳ thông tin nhạy cảm hay bí mật nào.
    """

    settings = request.app.state.settings

    content = {
        "status": "ok",
        "service": settings.app_name,
        "version": settings.app_version,
        "build_id": settings.build_id,
        "commit_sha": settings.git_commit_sha,
        "environment": settings.env,
        "app_mode": settings.app_mode,
        "storage_backend": settings.telemetry_storage_backend,
    }

    return JSONResponse(status_code=200, content=content)
