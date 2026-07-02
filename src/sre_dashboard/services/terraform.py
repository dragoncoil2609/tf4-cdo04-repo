"""Terraform output discovery — reads terraform.tfstate or runs `terraform output -json`.

Used to discover CDO infrastructure resource IDs (AMP workspace, SQS queues, etc.)
from the Terraform state directory mounted into the container.
"""

from __future__ import annotations

import json
import logging
import subprocess
from pathlib import Path
from typing import Any

logger = logging.getLogger("sre_dashboard.terraform")


class TerraformDiscovery:
    """Discovers CDO infrastructure outputs from Terraform state.

    Prefers running `terraform output -json` for freshness. Falls back to
    reading a cached `terraform-output.json` file written by the CI/CD pipeline
    if terraform binary is not available.
    """

    def __init__(self, output_dir: str) -> None:
        self._output_dir = Path(output_dir)

    def discover(self) -> dict[str, Any]:
        """Discover Terraform outputs.

        Returns a dict of Terraform output values. Each key maps to the
        ``value`` field from Terraform's JSON output format.

        Returns an empty dict if discovery fails entirely.
        """
        # Strategy 1: run terraform output -json in the output directory
        result = self._run_terraform_output()
        if result is not None:
            return result

        # Strategy 2: read cached terraform-output.json
        result = self._read_cached_output()
        if result is not None:
            return result

        logger.warning("No Terraform output available (neither binary nor cache file)")
        return {}

    def _run_terraform_output(self) -> dict[str, Any] | None:
        """Run ``terraform output -json`` in the terraform directory."""
        tf_dir = self._output_dir
        if not tf_dir.is_dir():
            logger.debug("Terraform directory does not exist: %s", tf_dir)
            return None

        try:
            result = subprocess.run(
                ["terraform", "output", "-json"],
                cwd=str(tf_dir),
                capture_output=True,
                text=True,
                timeout=15,
            )
            if result.returncode != 0:
                logger.warning(
                    "terraform output failed (rc=%d): %s",
                    result.returncode,
                    result.stderr.strip(),
                )
                return None

            parsed: dict[str, Any] = json.loads(result.stdout)
            # Terraform outputs each key as {"value": ..., "type": ..., "sensitive": ...}
            return {k: v.get("value") for k, v in parsed.items()}
        except FileNotFoundError:
            logger.debug("terraform binary not found in PATH")
            return None
        except json.JSONDecodeError as exc:
            logger.warning("Failed to parse terraform output JSON: %s", exc)
            return None
        except subprocess.TimeoutExpired:
            logger.warning("terraform output timed out after 15s")
            return None
        except Exception as exc:
            logger.warning("Unexpected error running terraform output: %s", exc)
            return None

    def _read_cached_output(self) -> dict[str, Any] | None:
        """Read a cached ``terraform-output.json`` from the output directory."""
        cache_file = self._output_dir / "terraform-output.json"
        if not cache_file.is_file():
            return None
        try:
            parsed: dict[str, Any] = json.loads(cache_file.read_text())
            return {k: v.get("value") if isinstance(v, dict) and "value" in v else v
                    for k, v in parsed.items()}
        except (json.JSONDecodeError, OSError) as exc:
            logger.warning("Failed to read cached terraform output: %s", exc)
            return None
