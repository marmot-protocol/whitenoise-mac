#!/usr/bin/env python3
"""Run the existing full unit suite with tiny, owned TLS fixtures on ephemeral macOS CI.

No real media, external requests, persistent key, custom app trust callback, or weakened TLS.
The production adapter is unchanged. All trust/search-list changes are scoped and restored.
This helper refuses developer machines and the persistent Hermes host.
"""

import json
import os
from pathlib import Path
import re
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import uuid


def command(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=60).stdout


def certificate(directory, label, root=None, ip=False):
    key = directory / (label + ".key")
    cert = directory / (label + ".crt")
    csr = directory / (label + ".csr")
    san = "DNS:remote-media-fixture.invalid" + (",IP:127.0.0.1" if ip else "")
    if root is None:
        configuration = directory / (label + ".config")
        configuration.write_text("[req]\ndistinguished_name=dn\n[dn]\n[ca]\n"
                                 "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n"
                                 "nameConstraints=critical,permitted;DNS:remote-media-fixture.invalid,"
                                 "permitted;IP:127.0.0.1/255.255.255.255\n")
        command("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
                "-days", "2", "-keyout", str(key), "-out", str(cert), "-subj",
                "/CN=WN-CI-" + str(uuid.uuid4()), "-config", str(configuration), "-extensions", "ca")
    else:
        command("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256",
                "-keyout", str(key), "-out", str(csr), "-subj", "/CN=remote-media-fixture.invalid")
        extensions = directory / (label + ".extensions")
        extensions.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                              "extendedKeyUsage=serverAuth\nsubjectAltName=" + san + "\n")
        command("openssl", "x509", "-req", "-in", str(csr), "-CA", str(root[0]),
                "-CAkey", str(root[1]), "-set_serial", str(uuid.uuid4().int >> 64),
                "-days", "2", "-sha256", "-extfile", str(extensions), "-out", str(cert))
    return cert, key


class Server:
    def __init__(self, identity):
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context.load_cert_chain(*map(str, identity))
        self.context.set_alpn_protocols(["http/1.1"])
        self.context.set_servername_callback(self.sni)
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(16)
        self.listener.settimeout(0.5)
        self.port = self.listener.getsockname()[1]
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    @staticmethod
    def sni(connection, name, _context):
        # Never switch certificates based on SNI. Wrong-name failure must be certificate
        # validation, not a server rejecting an unknown SNI before returning its certificate.
        connection.fixture_sni = name or "no-sni"

    def run(self):
        while not self.stop.is_set():
            try:
                raw, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            raw.settimeout(12)
            try:
                with self.context.wrap_socket(raw, server_side=True) as connection:
                    request = b""
                    while b"\r\n\r\n" not in request and len(request) < 4096:
                        part = connection.recv(512)
                        if not part:
                            break
                        request += part
                    if not request:
                        continue
                    body = connection.fixture_sni.encode("ascii")
                    first_line = request.split(b"\r\n", 1)[0]
                    close_body = b"/clean-close" in first_line or b"/abrupt-close" in first_line
                    framing = b"" if close_body else b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                    connection.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\n" + framing + b"\r\n" + body)
                    if b"/abrupt-close" in first_line:
                        os.close(connection.detach())  # Deliberately no TLS close_notify.
                    else:
                        connection.settimeout(1)
                        try:
                            connection.unwrap().close()  # Sends close_notify before waiting for the client.
                        except (OSError, ssl.SSLError):
                            pass
            except (OSError, ssl.SSLError):
                # Expected for rejected certificates; positive controls detect broken servers.
                raw.close()

    def close(self):
        self.stop.set()
        self.listener.close()
        self.thread.join(timeout=15)
        if self.thread.is_alive():
            raise RuntimeError("fixture listener did not stop")


def main():
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"):
        raise SystemExit("This trust fixture is restricted to ephemeral macOS GitHub Actions runners.")
    if len(sys.argv) < 2:
        raise SystemExit("Supply the existing xcodebuild unit-test command after the script.")
    servers = []
    process = None

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    with tempfile.TemporaryDirectory(prefix="wn-native-tls-") as temporary:
        directory = Path(temporary)
        root = certificate(directory, "root")
        other_root = certificate(directory, "untrusted-root")
        trust_added = False
        system_keychain = "/Library/Keychains/System.keychain"
        fingerprint = command("openssl", "x509", "-in", str(root[0]), "-noout", "-fingerprint", "-sha1")
        fingerprint = fingerprint.strip().split("=", 1)[1].replace(":", "")
        if not re.fullmatch(r"[0-9A-Fa-f]{40}", fingerprint):
            raise RuntimeError("invalid fixture certificate fingerprint")
        try:
            for label, issuer, ip in [("dns", root, False), ("ip", root, True), ("untrusted", other_root, False)]:
                servers.append(Server(certificate(directory, label, issuer, ip)))
            # The server contexts already loaded their leaf keys. Delete every ephemeral
            # signing key BEFORE trusting the root; no root signing capability remains on disk.
            for key in directory.glob("*.key"):
                key.unlink()
            # User-domain trust changes can require interactive authorization. Only this
            # explicitly GitHub-hosted ephemeral runner may use noninteractive admin trust.
            # No authorization policy is weakened, no persistent/package host runs this path.
            trust_added = True  # Cleanup also covers an interrupted/partially successful add.
            command("sudo", "-n", "security", "add-trusted-cert", "-d", "-r", "trustRoot", "-p", "ssl",
                    "-k", system_keychain, str(root[0]))
            fixture = json.dumps(dict(zip(("dns", "ip", "untrusted"), (s.port for s in servers))), separators=(",", ":"))
            args = sys.argv[1:] + ["WN_REMOTE_MEDIA_NATIVE_FIXTURE=" + fixture]
            # Capture only this build/test log. Do not write certificate keys to artifacts.
            process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            passed = set()
            for line in process.stdout:
                print(line, end="", flush=True)
                # Xcode emits either Swift Testing or XCTest-style forwarded test events.
                match = re.search(r"(nativeTLS\w+)\(\).*passed (?:after|on)", line)
                if match:
                    passed.add(match.group(1))
            result = process.wait()
            expected = {"nativeTLSOriginalNameWorks", "nativeTLSWrongNameRejected", "nativeTLSLiteralIPNeedsSAN",
                        "nativeTLSLiteralIPWithSANWorks", "nativeTLSUntrustedCertificateRejected",
                        "nativeTLSCleanCloseCompletesBody", "nativeTLSAbruptCloseDoesNotCompleteBody"}
            if result != 0:
                raise SystemExit(result)
            if passed != expected:
                raise SystemExit("Native TLS fixture tests did not all execute and pass: " + repr(sorted(passed)))
            print("Native TLS qualification: all seven real-socket tests executed and passed.")
        finally:
            # Every cleanup is attempted, even if an earlier operation fails. Failure is loud.
            failures = []
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            for operation in ([server.close for server in servers]
                              + ([lambda: command("sudo", "-n", "security", "remove-trusted-cert", "-d", str(root[0])),
                                  lambda: command("sudo", "-n", "security", "delete-certificate", "-Z", fingerprint,
                                                  system_keychain)] if trust_added else [])):
                try:
                    operation()
                except Exception as error:
                    failures.append(type(error).__name__)
            if failures:
                raise RuntimeError("TLS fixture cleanup failed: " + repr(failures))


if __name__ == "__main__":
    main()
