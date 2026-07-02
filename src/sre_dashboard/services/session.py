"""Session management — AWS SSO profile lifecycle for the SRE dashboard.

Provides a simple in-process session store so the frontend can log in/out
via AWS SSO profiles without embedding credentials in the browser.
"""

from __future__ import annotations

import logging
import os
import subprocess
import json
from dataclasses import dataclass, field
from typing import Any
from datetime import datetime, timezone

logger = logging.getLogger("sre_dashboard.session")


@dataclass
class SessionState:
    """In-memory session tracking for the dashboard."""
    profile: str | None = None
    region: str = "us-east-1"
    account_id: str | None = None
    role_arn: str | None = None
    logged_in_at: str | None = None
    expiry: str | None = None


class SessionManager:
    """Manages AWS SSO sessions for the dashboard.

    The session is entirely in-memory and never serialized to disk.
    Credentials are never returned to the caller.
    """

    def __init__(self) -> None:
        self._state = SessionState()

    def get_state(self) -> dict[str, Any]:
        """Return public session info (no credentials)."""
        return {
            "profile": self._state.profile,
            "account_id": self._state.account_id,
            "region": self._state.region,
            "logged_in_at": self._state.logged_in_at,
            "is_logged_in": self._state.profile is not None,
        }

    def login(self, profile: str | None = None, region: str = "us-east-1") -> dict[str, Any]:
        """Log in using an AWS SSO profile.

        Attempts to get a session via the profile. If the profile is not
        already logged in, hints the user to run ``aws sso login``.
        """
        if not profile:
            # Use default profile or AWS_PROFILE env var
            profile = os.environ.get("AWS_PROFILE", "default")

        # Attempt STS call to verify session is valid
        import boto3
        try:
            session = boto3.Session(profile_name=profile, region_name=region)
            sts = session.client("sts")
            identity = sts.get_caller_identity()
            self._state.profile = profile
            self._state.region = region
            self._state.account_id = identity.get("Account")
            self._state.role_arn = identity.get("Arn")
            self._state.logged_in_at = datetime.now(timezone.utc).isoformat()
            self._state.expiry = None

            return {
                "status": "ok",
                "profile": profile,
                "account_id": self._state.account_id,
                "arn": self._state.role_arn,
                "region": region,
            }
        except Exception as exc:
            err_msg = str(exc)
            logger.warning("SSO login failed for profile '%s': %s", profile, err_msg)
            # Ensure state is clean on failure
            self._state.profile = None
            self._state.account_id = None
            self._state.role_arn = None
            return {
                "status": "error",
                "detail": f"SSO login failed for profile '{profile}'. Run 'aws sso login --profile {profile}' first.",
                "error": err_msg,
            }

    def logout(self) -> dict[str, Any]:
        """Log out by clearing session state."""
        self._state = SessionState()
        return {"status": "ok"}

    def refresh(self) -> dict[str, Any]:
        """Refresh the current session by re-running STS.

        Returns error if no session is active.
        """
        if not self._state.profile:
            return {"status": "error", "detail": "No active session to refresh"}

        return self.login(self._state.profile, self._state.region)

    def list_profiles(self) -> list[dict[str, str]]:
        """List available AWS profiles from the shared credentials file.

        Scans ~/.aws/config for [profile ...] sections.
        """
        profiles: list[dict[str, str]] = []
        config_path = os.path.expanduser("~/.aws/config")
        creds_path = os.path.expanduser("~/.aws/credentials")

        seen: set[str] = set()

        for path in [config_path, creds_path]:
            if not os.path.isfile(path):
                continue
            try:
                with open(path) as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith("[") and line.endswith("]"):
                            name = line[1:-1]
                            if name == "default":
                                name = "default"
                            elif name.startswith("profile "):
                                name = name[len("profile "):]
                            if name not in seen:
                                seen.add(name)
                                profiles.append({"name": name, "source": path})
            except OSError:
                continue

        return profiles
