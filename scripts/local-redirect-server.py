#!/usr/bin/env python3
"""Minimal read-only OCI control plane and single-blob HTTP origin."""

import argparse
import hashlib
import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")


def file_digest(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def error_body(code, message):
    return json.dumps(
        {"errors": [{"code": code, "message": message}]},
        separators=(",", ":"),
    ).encode() + b"\n"


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler, state):
        super().__init__(address, handler)
        self.state = state


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        return

    def _record(self, status, response_bytes, location=None):
        entry = {
            "timestamp_ns": time.time_ns(),
            "role": self.server.state["role"],
            "method": self.command,
            "path": self.path,
            "status": status,
            "response_bytes": response_bytes,
            "range": self.headers.get("Range"),
            "authorization_received": self.headers.get("Authorization") is not None,
            "cookie_received": self.headers.get("Cookie") is not None,
            "redirect_sentinel": self.headers.get("X-Redirect-Sentinel"),
            "user_agent": self.headers.get("User-Agent"),
            "request_id": self.headers.get("X-Request-Id"),
        }
        if location is not None:
            entry["location"] = location
        with open(self.server.state["log"], "a", encoding="utf-8") as stream:
            stream.write(json.dumps(entry, separators=(",", ":")) + "\n")

    def _send(self, status, body=b"", content_type=None, headers=None):
        self.send_response(status)
        self.send_header("Docker-Distribution-Api-Version", "registry/2.0")
        if content_type:
            self.send_header("Content-Type", content_type)
        for key, value in (headers or {}).items():
            self.send_header(key, str(value))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        sent = 0
        if self.command != "HEAD" and body:
            self.wfile.write(body)
            sent = len(body)
        self._record(status, sent, (headers or {}).get("Location"))

    def _error(self, status, code, message, allow=None):
        headers = {"Allow": allow} if allow else None
        self._send(status, error_body(code, message), "application/json", headers)

    def do_HEAD(self):
        self._read()

    def do_GET(self):
        self._read()

    def do_POST(self):
        self._mutation()

    def do_PUT(self):
        self._mutation()

    def do_PATCH(self):
        self._mutation()

    def do_DELETE(self):
        self._mutation()

    def _mutation(self):
        if self.server.state["role"] == "control":
            self._error(405, "UNSUPPORTED", "the control plane is read-only", "GET, HEAD")
        else:
            self._error(405, "UNSUPPORTED", "the origin is read-only", "GET, HEAD")

    def _read(self):
        if self.server.state["role"] == "control":
            self._control_read()
        else:
            self._origin_read()

    def _control_read(self):
        state = self.server.state
        path = urlsplit(self.path).path
        if path == "/v2/":
            self._send(200)
            return

        prefix = "/v2/" + state["repository"] + "/manifests/"
        if path.startswith(prefix):
            reference = path[len(prefix) :]
            if reference not in (state["tag"], state["manifest_digest"]):
                self._error(404, "MANIFEST_UNKNOWN", "manifest unknown")
                return
            self._send(
                200,
                state["manifest"],
                state["manifest_media_type"],
                {"Docker-Content-Digest": state["manifest_digest"]},
            )
            return

        prefix = "/v2/" + state["repository"] + "/blobs/"
        if path.startswith(prefix):
            digest = path[len(prefix) :]
            if digest == state["config_digest"]:
                self._send(
                    200,
                    state["config"],
                    "application/vnd.oci.image.config.v1+json",
                    {"Docker-Content-Digest": digest},
                )
                return
            location = state["mappings"].get(digest)
            if location is not None:
                self._send(
                    307,
                    headers={"Location": location, "Cache-Control": "no-store"},
                )
                return
            self._error(404, "BLOB_UNKNOWN", "blob unknown")
            return

        self._error(404, "NAME_UNKNOWN", "repository unknown")

    def _origin_read(self):
        state = self.server.state
        if urlsplit(self.path).path != "/blobs/" + state["digest"]:
            self._error(404, "BLOB_UNKNOWN", "blob unknown")
            return

        with open(state["blob"], "rb") as stream:
            body = stream.read()
        if state["corrupt"]:
            body = bytes([body[0] ^ 1]) + body[1:]

        size = len(body)
        status = 200
        headers = {
            "Accept-Ranges": "bytes",
            "ETag": '"' + state["digest"] + '"',
            "Docker-Content-Digest": state["digest"],
        }
        range_header = self.headers.get("Range")
        if range_header:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header)
            start = end = None
            if match and match.group(1):
                start = int(match.group(1))
                end = int(match.group(2)) if match.group(2) else size - 1
            elif match and match.group(2):
                suffix = int(match.group(2))
                start = max(0, size - suffix)
                end = size - 1
            if start is None or start >= size or end < start:
                self._send(
                    416,
                    content_type="application/octet-stream",
                    headers={"Content-Range": "bytes */" + str(size), **headers},
                )
                return
            end = min(end, size - 1)
            body = body[start : end + 1]
            status = 206
            headers["Content-Range"] = f"bytes {start}-{end}/{size}"
        self._send(status, body, "application/octet-stream", headers)


def parse_mapping(value):
    digest, separator, location = value.partition("=")
    if not separator or not DIGEST_RE.fullmatch(digest) or not location:
        raise argparse.ArgumentTypeError("mapping must be sha256:<hex>=<absolute-url>")
    return digest, location


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--log", required=True)
    subparsers = parser.add_subparsers(dest="role", required=True)

    control = subparsers.add_parser("control")
    control.add_argument("--repository", default="poc/synthetic")
    control.add_argument("--tag", required=True)
    control.add_argument("--manifest", required=True)
    control.add_argument("--config", required=True)
    control.add_argument("--mapping", action="append", type=parse_mapping, default=[])

    origin = subparsers.add_parser("origin")
    origin.add_argument("--digest", required=True)
    origin.add_argument("--blob", required=True)
    origin.add_argument("--corrupt", action="store_true")
    args = parser.parse_args()

    os.makedirs(os.path.dirname(os.path.abspath(args.log)), exist_ok=True)
    open(args.log, "a", encoding="utf-8").close()
    state = {"role": args.role, "log": args.log}
    if args.role == "control":
        with open(args.manifest, "rb") as stream:
            manifest = stream.read()
        with open(args.config, "rb") as stream:
            config = stream.read()
        parsed = json.loads(manifest)
        state.update(
            repository=args.repository,
            tag=args.tag,
            manifest=manifest,
            config=config,
            manifest_media_type=parsed["mediaType"],
            manifest_digest="sha256:" + hashlib.sha256(manifest).hexdigest(),
            config_digest="sha256:" + hashlib.sha256(config).hexdigest(),
            mappings=dict(args.mapping),
        )
    else:
        if not DIGEST_RE.fullmatch(args.digest):
            parser.error("origin digest must be sha256:<64 lowercase hex>")
        if file_digest(args.blob) != args.digest:
            parser.error("origin blob bytes do not match --digest")
        state.update(digest=args.digest, blob=args.blob, corrupt=args.corrupt)

    server = Server((args.listen, args.port), Handler, state)
    print(f"{args.role} listening on {args.listen}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
