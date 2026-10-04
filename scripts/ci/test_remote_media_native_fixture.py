"""Bounded, platform-independent checks of the owned TLS server fixtures (not the app)."""

import importlib.util
from pathlib import Path
import socket
import ssl
import tempfile
import unittest

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


if __name__ == "__main__":
    unittest.main()
