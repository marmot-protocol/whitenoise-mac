# Remote media transport

Every peer-controlled remote URL the app fetches — avatars through
`RemoteImageLoader.image(for:maxPixelSize:)`, source bytes through `data(for:)` (group image
search, GIPHY) and link-preview pages through `page(for:)` — goes through one pinned HTTPS
client, `RemoteMediaTransport`, in `whitenoise-mac/Core/RemoteMediaTransport/`. There is no
`URLSession` fallback: if the transport ever has to be switched off, stop remote downloads
instead. The design is a port of the iOS app's `PinnedHTTPSFetcher`.

## Threat model

Remote media URLs come from untrusted Nostr metadata. A URL can aim the viewer's client at
their own network (SSRF): `https://192.168.1.1/`, or a public-looking name that resolves to a
private address (DNS rebinding). Checking the URL text is not enough, because `URLSession`
resolves the name again on its own and offers no hook to check the resolved address before it
connects.

## What one fetch does

1. **Admission.** `RemoteImageURLPolicy.isAllowed`: https only, no userinfo, no local names,
   no private, loopback, link-local, CGNAT, multicast, reserved or non-global IANA
   special-purpose address (IPv4 or IPv6, including IPv4 embedded in IPv6).
   `RemoteMediaRequestTarget` then refuses anything it cannot represent exactly: zone ids,
   non-canonical numeric hosts (`134744072`, `8.8.8.010`), non-ASCII or malformed names.
2. **Deadline.** One 60 s deadline starts before DNS and covers every address and every
   redirect hop. A 15 s idle limit applies to each network step and is reset only by real
   progress.
3. **Resolution.** A numeric literal is dialed directly. A name is resolved once with
   `getaddrinfo` on a background worker, with at most 6 resolutions in flight process-wide
   (a slot is freed only when the worker returns) and at most 128 callers queued.
4. **Answer admission.** The *whole* answer set is rejected if it is empty, larger than 64,
   contains non-canonical text, or contains *any* address step 1 would reject. A public
   answer next to a private one is an attack, not a fallback.
5. **Connection.** Network.framework TLS over TCP to an admitted address. `NWEndpoint.Host` is
   built from the address bytes, never from a string. For a name origin,
   `sec_protocol_options_set_tls_server_name` keeps the original hostname for SNI and
   certificate verification; for a literal origin the certificate must carry that IP. System
   trust is never replaced; TLS 1.2 minimum, ALPN `http/1.1`. System proxies are honored, as
   they were under `URLSession`; the proxy receives the admitted numeric endpoint.
6. **Request.** `GET` with the original `Host`, `User-Agent: WhiteNoise`, an `Accept` value
   (`*/*` by default; link previews ask for HTML), `Accept-Encoding: identity` and
   `Connection: close`. No cookies, credentials, referrer or `Accept-Language`.
7. **Response.** `RemoteMediaHTTPResponseParser` checks every bound before buffering: 8 MiB
   body, 64 KiB of heads and of chunk framing, 8 informational responses. Ambiguous framing
   (duplicate or conflicting `Content-Length`/`Transfer-Encoding`, bare CR/LF, obs-fold,
   bytes after the message, early EOF) is rejected.
8. **Status.** `2xx` except `206` succeeds. Redirects are followed at most 5 times, closing
   right after the head; every hop repeats steps 1–4. Everything else fails.
9. **Retry.** The next admitted address is tried only after a failure before any response
   byte (connect, TLS, send, stall). Size, framing, admission, cancellation and deadline
   errors end the fetch.

Cancellation and timeouts go through one once-only gate, so the caller never waits for DNS or
a socket to wind down, and a late DNS answer can never start a connection. A privacy wipe
(`RemoteImageLoader.clearCache()`) cancels every in-flight download and refuses its bytes.

## Deliberate compatibility refusals

These fail closed — the image simply does not load:

- **Close-delimited bodies.** A body must be framed by `Content-Length` or `chunked`;
  Network.framework can report a truncated TLS stream as a clean EOF, so "read until close"
  cannot tell a complete image from a cut one.
- **Content encodings** other than `identity`; we ask for `identity`.
- **`206 Partial Content`**; no range was requested.

## Known limits

- One fresh DNS + TCP + TLS handshake per fetch: no connection reuse, HTTP/2 or Happy
  Eyeballs. Addresses are tried in order, so a black-holed first address can spend the 15 s
  idle budget before the next one is tried.
- VPN or router remapping of public destinations, NAT64 prefixes other than the well-known
  one, tracking by the image host, and image-decoder hardening are out of scope.
- `NIP05Resolver` still uses `URLSession` on peer-controlled domains.

## Testing

Transport behavior is tested deterministically with fakes injected through `#if DEBUG`
seams (`RemoteMediaTransport(testingResolver:connectionFactory:clock:dnsSlots:)`,
`RemoteImageLoader(transport:)`): a virtual clock, a holdable resolver and scripted
connections. No test sleeps or opens a socket. See `RemoteMediaHTTPParserTests`,
`RemoteMediaResolutionTests`, `RemoteMediaTransportTests` and the `remoteImageLoader…` tests in
`MediaTests`.
