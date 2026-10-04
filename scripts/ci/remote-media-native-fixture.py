#!/usr/bin/env python3
"""Run the existing full unit suite with tiny, owned TLS fixtures on ephemeral macOS CI.

No real media, external requests, persistent key, custom app trust callback, or weakened TLS.
The production adapter is unchanged. The unique trust root is denied and deleted;
the remaining deny record is contained by the disposable runner's lifetime.
This helper refuses developer machines and the persistent Hermes host.
"""

import json
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import uuid

# Runs only after main's hosted-macOS guard. A direct root-owned child lets the
# supervisor kill/reap security itself, rather than only sudo's separate session.
ADMIN_SUPERVISOR = """
import os, signal, subprocess, sys
child = subprocess.Popen(['/usr/bin/security'] + sys.argv[1:], stdin=subprocess.DEVNULL,
                         start_new_session=True)
try:
    result = child.wait(timeout=60)
except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGKILL)
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        sys.exit(125)
    sys.exit(124)
sys.exit(result)
"""


class CommandTimeout(RuntimeError):
    """An admin mutation's outcome is unknown; do not perform another mutation."""


def command(*args):
    admin = args[:3] == ("sudo", "-n", "security")
    invocation = ("sudo", "-n", "/usr/bin/python3", "-c", ADMIN_SUPERVISOR, *args[3:]) if admin else args
    # Files avoid waiting forever for pipes held by a descendant in another session.
    with tempfile.TemporaryFile() as output_file, tempfile.TemporaryFile() as error_file:
        process = subprocess.Popen(invocation, stdin=subprocess.DEVNULL, stdout=output_file,
                                   stderr=error_file, start_new_session=True)
        try:
            process.wait(timeout=75 if admin else 60)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError as error:
                raise CommandTimeout("command termination/reap unproven") from error
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired as error:
                raise CommandTimeout("command reap not established") from error
            raise CommandTimeout("command timed out; outcome unknown")
        if admin and process.returncode in (124, 125):
            raise CommandTimeout("admin security command timed out; outcome unknown")
        output_file.seek(0)
        error_file.seek(0)
        output = output_file.read().decode("utf-8")
        errors = error_file.read().decode("utf-8")
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, args, output, errors)
        return output


def require_denied_record(settings, fingerprint):
    """Missing/empty settings default to trustRoot, never evidence of denial."""
    trust_list = settings.get("trustList")
    if not isinstance(trust_list, dict) or fingerprint not in trust_list:
        raise RuntimeError("fixture trust record is missing")
    record = trust_list[fingerprint]
    constraints = record.get("trustSettings") if isinstance(record, dict) else None
    if (not isinstance(constraints, list) or not constraints
            or any(not isinstance(item, dict) or type(item.get("kSecTrustSettingsResult")) is not int
                   or item["kSecTrustSettingsResult"] != 3 for item in constraints)):
        raise RuntimeError("fixture trust record is not explicitly denied")


def contain_root(directory, root, fingerprint, system_keychain):
    # Removal hung on native macOS26. Replace ONLY this root's SSL grant with
    # explicit denial via the setter, then verify before deleting its certificate.
    phase("admin-trust-deny", lambda: command("sudo", "-n", "security", "add-trusted-cert",
                                              "-d", "-r", "deny", "-p", "ssl",
                                              "-k", system_keychain, str(root)))
    admin_export = directory / "admin-after-deny.plist"
    phase("verify-admin-deny-export", lambda: command("security", "trust-settings-export", "-d", str(admin_export)))
    require_denied_record(plistlib.loads(admin_export.read_bytes()), fingerprint)
    user_export = directory / "user-after-deny.plist"
    try:
        phase("verify-user-domain-export", lambda: command("security", "trust-settings-export", str(user_export)))
    except subprocess.CalledProcessError as error:
        # Apple's API has an explicit empty-domain result. Never confuse any other
        # command/read/parse failure with absence; native CI must establish this text.
        if error.returncode != 1 or error.stderr.strip() != (
                "SecTrustSettingsCreateExternalRepresentation: No Trust Settings were found."):
            raise
        user_settings = {"trustList": {}}
    else:
        user_settings = plistlib.loads(user_export.read_bytes())
    user_list = user_settings.get("trustList")
    if not isinstance(user_list, dict) or fingerprint in user_list:
        raise RuntimeError("fixture root user-domain absence unproven")
    phase("certificate-removal", lambda: command("sudo", "-n", "security", "delete-certificate",
                                                 "-Z", fingerprint, system_keychain))
    certificates = phase("verify-certificate-absence", lambda: command(
        "security", "find-certificate", "-a", "-Z", system_keychain))
    if fingerprint in certificates.upper():
        raise RuntimeError("fixture certificate remains in system keychain")
    print("TLS fixture root explicitly denied; exact certificate absence verified; "
          "deny record lifetime relies on disposable VM. Not strict trust-entry cleanup.", flush=True)


def phase(label, operation):
    started = time.monotonic()
    print("TLS fixture phase " + label + " started", flush=True)
    try:
        result = operation()
    except Exception as error:
        print("TLS fixture phase " + label + " failed: " + type(error).__name__
              + " after %.2fs" % (time.monotonic() - started), flush=True)
        raise
    print("TLS fixture phase " + label + " completed in %.2fs" % (time.monotonic() - started), flush=True)
    return result


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
                    truncated = b"/truncated-fixed" in first_line
                    chunked = b"/chunked" in first_line
                    framing = b"" if close_body else b"Content-Length: " + str(len(body) + int(truncated)).encode() + b"\r\n"
                    if chunked:
                        framing = b"Transfer-Encoding: chunked\r\n"
                        body = format(len(body), "x").encode() + b"\r\n" + body + b"\r\n0\r\n\r\n"
                    connection.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\n" + framing + b"\r\n" + body)
                    if b"/abrupt-close" in first_line or truncated:
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


def required_native_cases(include_public_cdn=False):
    cases = {"nativeTLSOriginalNameWorks", "nativeTLSWrongNameRejected", "nativeTLSLiteralIPNeedsSAN",
             "nativeTLSLiteralIPWithSANWorks", "nativeTLSUntrustedCertificateRejected",
             "nativeTLSCleanCloseRequiresExplicitFraming", "nativeTLSAbruptCloseDoesNotCompleteBody",
             "nativeTLSProductionReceiveAcceptsChunks", "nativeTLSProductionReceiveRejectsTruncatedLength"}
    if include_public_cdn:
        cases.add("nativePublicCDNPinnedImageFetchWorks")
    return cases


def main():
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"):
        raise SystemExit("This trust fixture is restricted to ephemeral macOS GitHub Actions runners.")
    if len(sys.argv) < 2:
        raise SystemExit("Supply the existing xcodebuild unit-test command after the script.")
    lifecycle_only = sys.argv[1:] == ["--trust-lifecycle-only"]
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
        admin_outcome_unknown = False
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
            admin_outcome_unknown = True  # Includes signal interruption while the command is live.
            print("TLS fixture root SHA1: " + fingerprint, flush=True)
            phase("admin-trust-install", lambda: command(
                "sudo", "-n", "security", "add-trusted-cert", "-d", "-r", "trustRoot", "-p", "ssl",
                "-k", system_keychain, str(root[0])))
            admin_outcome_unknown = False
            if lifecycle_only:
                print("TLS fixture lifecycle diagnostic: setup completed; teardown follows.", flush=True)
                return
            fixture = json.dumps(dict(zip(("dns", "ip", "untrusted"), (s.port for s in servers))), separators=(",", ":"))
            args = sys.argv[1:] + ["WN_REMOTE_MEDIA_NATIVE_FIXTURE=" + fixture]
            include_public_cdn = os.environ.get("WN_REMOTE_MEDIA_NATIVE_CDN") == "1"
            args.append("WN_REMOTE_MEDIA_NATIVE_CDN=" + ("1" if include_public_cdn else "0"))
            # Capture only this build/test log. Do not write certificate keys to artifacts.
            process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            passed = set()
            for line in process.stdout:
                print(line, end="", flush=True)
                # Xcode emits either Swift Testing or XCTest-style forwarded test events.
                match = re.search(r"(native(?:TLS|PublicCDN)\w+)\(\).*passed (?:after|on)", line)
                if match:
                    passed.add(match.group(1))
            result = process.wait()
            expected = required_native_cases(include_public_cdn)
            if result != 0:
                raise SystemExit(result)
            if passed != expected:
                raise SystemExit("Native TLS fixture tests did not all execute and pass: " + repr(sorted(passed)))
            print("Native transport qualification: all " + str(len(expected)) + " required tests executed and passed.")
        except CommandTimeout:
            admin_outcome_unknown = True
            raise
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
            operations = [("listener", server.close) for server in servers]
            for label, operation in operations:
                try:
                    phase(label, operation)
                except Exception as error:
                    failures.append(label + ":" + type(error).__name__)
            if trust_added:
                try:
                    if admin_outcome_unknown:
                        raise RuntimeError("admin outcome unknown; no further keychain mutation")
                    contain_root(directory, root[0], fingerprint.upper(), system_keychain)
                except Exception as error:
                    failures.append("root-containment:" + type(error).__name__)
            if failures:
                raise RuntimeError("TLS fixture cleanup failed: " + repr(failures))


if __name__ == "__main__":
    main()
