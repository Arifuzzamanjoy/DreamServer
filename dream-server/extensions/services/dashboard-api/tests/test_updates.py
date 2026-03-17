"""Tests for routers/updates.py — version checking and update endpoints."""

import json
import urllib.error
from pathlib import Path
from unittest.mock import MagicMock


# --- GET /api/version ---


class TestGetVersion:

    def test_returns_current_version(self, test_client, monkeypatch):
        """Returns current version from .version file."""
        import routers.updates as updates_mod

        version_dir = Path("/tmp/dream-test-version")
        version_dir.mkdir(parents=True, exist_ok=True)
        version_file = version_dir / ".version"
        version_file.write_text("1.5.0\n")

        monkeypatch.setattr(updates_mod, "INSTALL_DIR", str(version_dir))

        # Mock urllib to simulate GitHub check failure (isolate version reading)
        monkeypatch.setattr(
            "urllib.request.urlopen",
            MagicMock(side_effect=urllib.error.URLError("network unavailable")),
        )

        resp = test_client.get("/api/version", headers=test_client.auth_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["current"] == "1.5.0"
        assert data["update_available"] is False

    def test_detects_update_available(self, test_client, monkeypatch):
        """Detects update when current (1.0.0) < latest (2.0.0)."""
        import routers.updates as updates_mod

        version_dir = Path("/tmp/dream-test-version-upd")
        version_dir.mkdir(parents=True, exist_ok=True)
        (version_dir / ".version").write_text("1.0.0\n")
        monkeypatch.setattr(updates_mod, "INSTALL_DIR", str(version_dir))

        # Mock GitHub API response
        gh_response = json.dumps({
            "tag_name": "v2.0.0",
            "html_url": "https://github.com/test/releases/tag/v2.0.0",
        }).encode()

        mock_resp = MagicMock()
        mock_resp.read = MagicMock(return_value=gh_response)
        mock_resp.__enter__ = MagicMock(return_value=mock_resp)
        mock_resp.__exit__ = MagicMock(return_value=False)

        monkeypatch.setattr("urllib.request.urlopen", MagicMock(return_value=mock_resp))

        resp = test_client.get("/api/version", headers=test_client.auth_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["current"] == "1.0.0"
        assert data["latest"] == "2.0.0"
        assert data["update_available"] is True

    def test_no_update_when_current_ge_latest(self, test_client, monkeypatch):
        """No update when current >= latest."""
        import routers.updates as updates_mod

        version_dir = Path("/tmp/dream-test-version-noupd")
        version_dir.mkdir(parents=True, exist_ok=True)
        (version_dir / ".version").write_text("3.0.0\n")
        monkeypatch.setattr(updates_mod, "INSTALL_DIR", str(version_dir))

        gh_response = json.dumps({
            "tag_name": "v2.0.0",
            "html_url": "https://github.com/test/releases/tag/v2.0.0",
        }).encode()

        mock_resp = MagicMock()
        mock_resp.read = MagicMock(return_value=gh_response)
        mock_resp.__enter__ = MagicMock(return_value=mock_resp)
        mock_resp.__exit__ = MagicMock(return_value=False)

        monkeypatch.setattr("urllib.request.urlopen", MagicMock(return_value=mock_resp))

        resp = test_client.get("/api/version", headers=test_client.auth_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["update_available"] is False

    def test_handles_github_api_failure(self, test_client, monkeypatch):
        """Returns version info even if GitHub API is unreachable."""
        import routers.updates as updates_mod

        version_dir = Path("/tmp/dream-test-version-ghfail")
        version_dir.mkdir(parents=True, exist_ok=True)
        (version_dir / ".version").write_text("1.0.0\n")
        monkeypatch.setattr(updates_mod, "INSTALL_DIR", str(version_dir))

        monkeypatch.setattr(
            "urllib.request.urlopen",
            MagicMock(side_effect=urllib.error.URLError("timeout")),
        )

        resp = test_client.get("/api/version", headers=test_client.auth_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["current"] == "1.0.0"
        assert data["latest"] is None

    def test_handles_missing_version_file(self, test_client, monkeypatch):
        """Returns 0.0.0 when .version file doesn't exist."""
        import routers.updates as updates_mod
        monkeypatch.setattr(updates_mod, "INSTALL_DIR", "/tmp/nonexistent-dir-12345")

        monkeypatch.setattr(
            "urllib.request.urlopen",
            MagicMock(side_effect=urllib.error.URLError("timeout")),
        )

        resp = test_client.get("/api/version", headers=test_client.auth_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["current"] == "0.0.0"


# --- GET /api/releases/manifest ---


class TestGetReleaseManifest:

    def test_returns_releases_on_success(self, test_client, monkeypatch):
        from conftest import load_golden_fixture
        releases = load_golden_fixture("github_releases.json")
        gh_response = json.dumps(releases).encode()

        mock_resp = MagicMock()
        mock_resp.read = MagicMock(return_value=gh_response)
        mock_resp.__enter__ = MagicMock(return_value=mock_resp)
        mock_resp.__exit__ = MagicMock(return_value=False)

        monkeypatch.setattr("urllib.request.urlopen", MagicMock(return_value=mock_resp))

        resp = test_client.get("/api/releases/manifest", headers=test_client.auth_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert "releases" in data
        assert len(data["releases"]) == 3
        assert data["releases"][0]["version"] == "2.1.0"

    def test_fallback_on_api_failure(self, test_client, monkeypatch):
        import routers.updates as updates_mod

        version_dir = Path("/tmp/dream-test-version-fallback")
        version_dir.mkdir(parents=True, exist_ok=True)
        (version_dir / ".version").write_text("1.0.0\n")
        monkeypatch.setattr(updates_mod, "INSTALL_DIR", str(version_dir))

        monkeypatch.setattr(
            "urllib.request.urlopen",
            MagicMock(side_effect=urllib.error.URLError("network error")),
        )

        resp = test_client.get("/api/releases/manifest", headers=test_client.auth_headers)
        assert resp.status_code == 200
        data = resp.json()
        assert "releases" in data
        assert len(data["releases"]) >= 1
        assert "error" in data


# --- POST /api/update ---


class TestTriggerUpdate:

    def test_check_action_runs_script(self, test_client, tmp_path, monkeypatch):
        import routers.updates as updates_mod

        install_dir = tmp_path / "dream-server"
        install_dir.mkdir()
        scripts_dir = tmp_path / "scripts"
        scripts_dir.mkdir()
        script = scripts_dir / "dream-update.sh"
        script.write_text("#!/bin/bash\necho check ok")
        script.chmod(0o755)

        monkeypatch.setattr(updates_mod, "INSTALL_DIR", str(install_dir))

        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "check passed"
        mock_result.stderr = ""

        monkeypatch.setattr("routers.updates.subprocess.run", lambda *a, **kw: mock_result)

        resp = test_client.post(
            "/api/update",
            json={"action": "check"},
            headers=test_client.auth_headers,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["success"] is True

    def test_unknown_action_returns_400(self, test_client, tmp_path, monkeypatch):
        import routers.updates as updates_mod

        install_dir = tmp_path / "dream-server"
        install_dir.mkdir()
        scripts_dir = tmp_path / "scripts"
        scripts_dir.mkdir()
        script = scripts_dir / "dream-update.sh"
        script.write_text("#!/bin/bash")
        script.chmod(0o755)

        monkeypatch.setattr(updates_mod, "INSTALL_DIR", str(install_dir))

        resp = test_client.post(
            "/api/update",
            json={"action": "invalid-action"},
            headers=test_client.auth_headers,
        )
        assert resp.status_code == 400

    def test_script_not_found_returns_501(self, test_client, monkeypatch):
        import routers.updates as updates_mod
        monkeypatch.setattr(updates_mod, "INSTALL_DIR", "/tmp/nonexistent-install-dir-12345")

        resp = test_client.post(
            "/api/update",
            json={"action": "check"},
            headers=test_client.auth_headers,
        )
        assert resp.status_code == 501
