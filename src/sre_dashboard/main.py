"""Entry point for running the SRE Dashboard directly.

Usage:
    python -m sre_dashboard.main
"""

from __future__ import annotations

import uvicorn

from sre_dashboard.app import app
from sre_dashboard.settings import load_settings


def main():
    settings = load_settings()
    uvicorn.run(
        "sre_dashboard.app:app",
        host=settings.host,
        port=settings.port,
        reload=False,
    )


if __name__ == "__main__":
    main()
