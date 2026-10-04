"""Bounded, platform-independent checks of the owned TLS server fixtures (not the app)."""

import importlib.util
import plistlib
from pathlib import Path
import socket
import ssl
import tempfile
import unittest


class TrustRecordTests(unittest.TestCase):
    def test_transported_manifest_changes_only_fixture_variables(self):
        updates = {"WN_REMOTE_MEDIA_NATIVE_FIXTURE": '{"dns":1234}', "WN_REMOTE_MEDIA_NATIVE_CDN": "1"}
        environment = {"WN_REMOTE_MEDIA_NATIVE_FIXTURE": "old-ports", "WN_REMOTE_MEDIA_NATIVE_CDN": "0",
                       "UNCHANGED": "ordinary-test-setting"}
        document = {"TestConfigurations": [{"TestTargets": [{"EnvironmentVariables": environment,
                      "TestBundlePath": "__TESTHOST__/tests.xctest", "TestHostPath": "__TESTROOT__/Debug/app.app"}]}]}
        with tempfile.TemporaryDirectory(prefix="wn-manifest-test-") as directory:
            path = Path(directory) / "owned.xctestrun"
            path.write_bytes(plistlib.dumps(document))
            fixture.replace_test_environment(path, updates)
            environment.update(updates)
            self.assertEqual(document, plistlib.loads(path.read_bytes()))

    def test_missing_partial_and_symlinked_manifest_fail_without_modification(self):
        updates = {"WN_REMOTE_MEDIA_NATIVE_FIXTURE": "fresh", "WN_REMOTE_MEDIA_NATIVE_CDN": "1"}
        with tempfile.TemporaryDirectory(prefix="wn-manifest-test-") as directory:
            path = Path(directory) / "owned.xctestrun"
            for document in [{}, {"EnvironmentVariables": {"WN_REMOTE_MEDIA_NATIVE_FIXTURE": "old"}}]:
                original = plistlib.dumps(document)
                path.write_bytes(original)
                with self.assertRaises(RuntimeError):
                    fixture.replace_test_environment(path, updates)
                self.assertEqual(original, path.read_bytes())
            link = Path(directory) / "linked.xctestrun"
            link.symlink_to(path)
            with self.assertRaises(RuntimeError):
                fixture.replace_test_environment(link, updates)

    def test_public_cdn_case_is_required_only_when_explicitly_enabled(self):
        tls = fixture.required_native_cases()
        public = fixture.required_native_cases(include_public_cdn=True)
        self.assertEqual(9, len(tls))
        self.assertEqual(tls | {"nativePublicCDNPinnedImageFetchWorks"}, public)

    def test_explicit_deny_is_required_for_every_constraint(self):
        fingerprint = "A" * 40
        accepted = {"trustList": {fingerprint: {"trustSettings": [{"kSecTrustSettingsResult": 3}]}}}
        fixture.require_denied_record(accepted, fingerprint)
        for constraints in [None, [], [{}], [{"kSecTrustSettingsResult": 1}],
                            [{"kSecTrustSettingsResult": 2}], [{"kSecTrustSettingsResult": True}],
                            [{"kSecTrustSettingsResult": 3}, {}]]:
            with self.assertRaises(RuntimeError):
                fixture.require_denied_record({"trustList": {fingerprint: {"trustSettings": constraints}}}, fingerprint)

    def test_missing_or_wrong_root_is_not_denial(self):
        for settings in [{}, {"trustList": {}}, {"trustList": {"B" * 40: {}}}]:
            with self.assertRaises(RuntimeError):
                fixture.require_denied_record(settings, "A" * 40)

spec = importlib.util.spec_from_file_location("fixture", Path(__file__).with_name("remote-media-native-fixture.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class NativeFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="wn-fixture-test-")
        directory = Path(cls.temporary.name)
        cls.root = fixture.certificate(directory, "root")
        cls.servers = [fixture.Server(fixture.certificate(directory, "dns", cls.root)),
                       fixture.Server(fixture.certificate(directory, "ip", cls.root, ip=True))]

    @classmethod
    def tearDownClass(cls):
        for server in cls.servers:
            server.close()
        cls.temporary.cleanup()

    def context(self):
        return ssl.create_default_context(cafile=str(self.root[0]))

    def connect(self, context, name, index=0):
        raw = socket.create_connection(("127.0.0.1", self.servers[index].port), timeout=5)
        try:
            return context.wrap_socket(raw, server_hostname=name, suppress_ragged_eofs=False)
        except Exception:
            raw.close()
            raise

    def test_dns_name_and_sni_positive_control(self):
        with self.connect(self.context(), "remote-media-fixture.invalid") as connection:
            connection.sendall(b"GET /fixed HTTP/1.1\r\nHost: fixture\r\n\r\n")
            data = connection.recv(4096)
            self.assertTrue(data.endswith(b"remote-media-fixture.invalid"))

    def test_wrong_name_rejected_against_same_certificate(self):
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.connect(self.context(), "wrong-origin.invalid")

    def test_missing_ip_san_rejected(self):
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.connect(self.context(), "127.0.0.1")

    def test_matching_ip_san_positive_control(self):
        with self.connect(self.context(), "127.0.0.1", index=1) as connection:
            connection.sendall(b"GET /fixed HTTP/1.1\r\nHost: fixture\r\n\r\n")
            self.assertTrue(connection.recv(4096).endswith(b"no-sni"))

    def test_untrusted_certificate_rejected(self):
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.connect(ssl.create_default_context(), "remote-media-fixture.invalid")

    def test_clean_close_is_clean(self):
        with self.connect(self.context(), "remote-media-fixture.invalid") as connection:
            connection.sendall(b"GET /clean-close HTTP/1.1\r\nHost: fixture\r\n\r\n")
            received = b""
            while True:
                data = connection.recv(4096)
                if not data:
                    break
                received += data
            self.assertTrue(received.endswith(b"remote-media-fixture.invalid"))

    def test_abrupt_close_is_not_clean(self):
        with self.connect(self.context(), "remote-media-fixture.invalid") as connection:
            connection.sendall(b"GET /abrupt-close HTTP/1.1\r\nHost: fixture\r\n\r\n")
            with self.assertRaises(ssl.SSLEOFError):
                while connection.recv(4096):
                    pass

    def test_chunked_fixture_has_explicit_terminator(self):
        with self.connect(self.context(), "remote-media-fixture.invalid") as connection:
            connection.sendall(b"GET /chunked HTTP/1.1\r\nHost: fixture\r\n\r\n")
            received = b""
            while part := connection.recv(4096):
                received += part
            self.assertIn(b"Transfer-Encoding: chunked\r\n", received)
            self.assertTrue(received.endswith(b"\r\n0\r\n\r\n"))

    def test_fixed_fixture_is_one_byte_short_and_abrupt(self):
        with self.connect(self.context(), "remote-media-fixture.invalid") as connection:
            connection.sendall(b"GET /truncated-fixed HTTP/1.1\r\nHost: fixture\r\n\r\n")
            received = b""
            with self.assertRaises(ssl.SSLEOFError):
                while part := connection.recv(4096):
                    received += part
            expected_body = b"remote-media-fixture.invalid"
            expected_length = str(len(expected_body) + 1).encode()
            self.assertIn(b"Content-Length: " + expected_length + b"\r\n", received)
            self.assertTrue(received.endswith(expected_body))


if __name__ == "__main__":
    unittest.main()
