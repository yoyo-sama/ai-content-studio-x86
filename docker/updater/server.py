import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

REPO_DIR = os.environ.get("REPO_DIR", "/repo")


def parse_ls_remote_sha(output):
    """Extract the SHA (first column) from the first line of `git ls-remote` output."""
    return output.strip().split("\n")[0].split("\t")[0]


def run_git(*args):
    return subprocess.run(
        ["git", "-C", REPO_DIR, *args],
        capture_output=True,
        text=True,
    )


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/status":
            self._send_json(404, {"error": "not found"})
            return

        local = run_git("rev-parse", "HEAD")
        if local.returncode != 0:
            self._send_json(500, {"error": local.stderr.strip()})
            return

        remote = run_git("ls-remote", "origin", "main")
        if remote.returncode != 0:
            self._send_json(500, {"error": remote.stderr.strip()})
            return

        local_sha = local.stdout.strip()
        remote_sha = parse_ls_remote_sha(remote.stdout)
        self._send_json(200, {
            "updateAvailable": local_sha != remote_sha,
            "localSha": local_sha,
            "remoteSha": remote_sha,
        })

    def do_POST(self):
        if self.path != "/apply":
            self._send_json(404, {"error": "not found"})
            return

        dirty = run_git("status", "--porcelain")
        if dirty.returncode != 0:
            self._send_json(500, {"error": dirty.stderr.strip()})
            return
        if dirty.stdout.strip():
            self._send_json(200, {"success": False, "error": "working tree not clean"})
            return

        fetch = run_git("fetch", "origin", "main")
        if fetch.returncode != 0:
            self._send_json(200, {"success": False, "error": fetch.stderr.strip()})
            return

        pull = run_git("pull", "--ff-only", "origin", "main")
        if pull.returncode != 0:
            self._send_json(200, {"success": False, "error": pull.stderr.strip()})
            return

        self._send_json(200, {"success": True})

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    if "--check" in sys.argv:
        sample = "abc123def456abc123def456abc123def456abcd\trefs/heads/main\n"
        assert parse_ls_remote_sha(sample) == "abc123def456abc123def456abc123def456abcd"
        print("self-check OK")
        sys.exit(0)

    subprocess.run(["git", "config", "--global", "--add", "safe.directory", REPO_DIR])
    HTTPServer(("127.0.0.1", 8093), Handler).serve_forever()
