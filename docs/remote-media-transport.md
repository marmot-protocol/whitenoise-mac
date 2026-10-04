# Remote media transport

Every peer-controlled remote image or media URL the macOS app fetches — profile/group
avatars through `RemoteImageLoader.image(for: URL, …)`, and source bytes through
`RemoteImageLoader.data(for:)` (group image search, GIPHY) — goes through one pinned HTTPS
client, `RemoteMediaTransport`, in `whitenoise-mac/Core/RemoteMediaTransport/`. There is no
`URLSession` path and no fallback to one. If the transport has to be switched off, the only
safe rollback is to stop remote downloads; going back to the old unpinned `URLSession` is not.

## Threat model

Remote image URLs come from untrusted Nostr metadata. Fetching one tells the sender's chosen
server the viewer's IP address and that they are online. The URL can also aim the request at
the viewer's own network (SSRF): `https://192.168.1.1/`, or a public-looking name that resolves
to a private address (DNS rebinding). The old loader checked the URL text and then let
`URLSession` resolve and connect by itself, so a rebinding name got through.

## What one fetch does

1. **Admission.** `RemoteImageURLPolicy.isAllowed` (https only, no
   userinfo, no local names, no private/loopback/link-local/CGNAT/multicast/reserved IPv4, no
   private IPv6 including documentation, NAT64/local-use translation, 6to4, Teredo and other
   IPv4 embeddings, obfuscated IPv4 spellings). The classifier also rejects non-global
   special-purpose benchmarking, documentation, discard/dummy, protocol-assignment and
   deprecated site-local ranges. Explicit global IANA anycast exceptions remain admitted.
   See [IANA IPv4](https://www.iana.org/assignments/iana-ipv4-special-registry/) and
   [IANA IPv6](https://www.iana.org/assignments/iana-ipv6-special-registry/), reviewed 2026-10-04.
   `RemoteMediaRequestTarget` then refuses
   anything it cannot represent exactly: ports outside `1...65535` (any valid port is
   allowed), zone ids, non-canonical numeric hosts such as `134744072` or `8.8.8.010`, and
   non-ASCII or malformed DNS names.
2. **Deadline.** One 60-second `ContinuousClock` deadline starts *before* DNS and covers
   every address attempt and every redirect hop.
3. **Resolution.** A canonical numeric literal (`8.8.8.8`, `[2606:4700::1111]`) is dialed
   directly with no DNS. A name is resolved once with `getaddrinfo` on a background worker,
   limited to 6 process-wide resolution slots. A slot is freed only when the worker returns,
   even if its caller has already given up, so stuck `getaddrinfo` threads are counted. When
   all 6 are taken, at most 128 callers wait in a FIFO without starting workers. Cancellation
   and the original deadline remove queued callers promptly; only queue overflow fails fast.
4. **Answer admission.** The *complete* answer set is checked (`RemoteMediaResolution`). It is
   rejected if it is empty, has more than 64 answers (never truncated), contains any answer
   that is not canonical numeric IPv4/IPv6 text, or contains *any* address the classifier
   rejects. A public answer next to a private one is treated as an attack, not as a fallback.
5. **Connection.** Network.framework TLS over TCP to an admitted address, with
   `NWEndpoint.Host` built from the address bytes using `IPv4Address`/`IPv6Address`, never
   from a string. For a DNS origin, `sec_protocol_options_set_tls_server_name` sets both the
   SNI and the name the system's default trust check verifies the certificate against,
   overriding the numeric endpoint ([Apple docs][set-tls-server-name]). Certificate checking
   is never turned off or replaced: no verify block, TLS 1.2 minimum, ALPN `http/1.1`. For a
   literal origin no name is set, so the certificate must carry that IP address (an IP SAN),
   as before. `NWParameters.preferNoProxies = true`.
6. **Request.** `GET` in origin-form (percent-encoded path and query, no fragment), with the
   original `Host` (IPv6 in brackets, port shown when it is not 443) and the headers
   `User-Agent: WhiteNoise`, `Accept: */*`, `Accept-Encoding: identity` and
   `Connection: close`. It never sends cookies, credentials, a referrer or
   `Accept-Language`.
7. **Response.** `RemoteMediaHTTPResponseParser` parses the response as it arrives, checking
   every limit before it buffers or appends anything:
   - body of at most 8 MiB
   - at most 64 KiB in total across every informational head, the final head and the trailers
   - at most 64 KiB of chunk framing (size lines, extensions, delimiters)
   - at most 8 informational responses
   - receives of at most 64 KiB

   Header names are matched case-insensitively. These are rejected:
   - bare CR or LF
   - obsolete line folding
   - control bytes
   - whitespace before a colon
   - duplicate `Content-Length` or `Transfer-Encoding`
   - `Content-Length` together with `Transfer-Encoding`
   - any transfer coding other than a single `chunked`
   - any content coding other than `identity`
   - `101` upgrades
   - bad chunk delimiters
   - bytes after the end of the message
   - EOF before the end of the message

   A body ends by `Content-Length`, by `chunked`, or by a clean close.
8. **Status.** `2xx` except `206` succeeds. `301/302/303/307/308` are followed (at most 5
   times) by closing the connection right after the head; redirect bodies are never read. Each
   hop, including a same-host hop, goes through admission, resolution and answer admission
   again. Every other status fails.
9. **Timing.** A 15-second idle limit applies to each network step (connect, send, every
   receive). Only real progress resets it (connected, request sent, non-empty bytes received),
   and it never goes past the 60-second total deadline. A timeout or cancellation finishes the
   waiting caller first, through a locked once-only gate that is resumed outside its lock,
   then cancels the socket. The caller never waits for DNS or the socket to finish shutting
   down. A late DNS answer or a late socket callback is thrown away and can never start a
   connection. A monotonic deadline check after each awaited callback also rejects a late
   result when executor pressure delays timer delivery.
10. **Retry.** The next admitted address is tried only after a transport failure that happened
    before any response byte was read: connect, TLS or send failure, a stall, or the connection
    closing without sending anything. Errors about size, framing, admission, cancellation or the
    total deadline end the fetch.

[set-tls-server-name]: https://developer.apple.com/documentation/security/sec_protocol_options_set_tls_server_name(_:_:)

## Caches

- The **decoded image cache** (`NSCache`, 64 MiB / 512 entries), priming, consent, coalescing
  and the remote/local cache generations work exactly as before.
- The **raw response cache** (`RemoteMediaResponseCache`) replaces the old memory-only
  `URLCache`. It lives in memory only and holds at most 16 MiB / 512 entries, evicting the
  least recently used. It stores only a complete `200` with explicit freshness (`max-age`, or
  `Expires` measured from `Date`), with age worked out per RFC 9111 §4.2.3 from `Date`, `Age`
  and the response delay. It never caches when it sees `no-store`, `no-cache`,
  `Pragma: no-cache`, `Vary`, `Set-Cookie`, an unknown `Cache-Control` directive, a malformed
  or duplicate `max-age`/`Age`/`Date`, or a date it cannot parse (only IMF-fixdate is
  accepted). It never uses heuristic freshness, revalidation or stale bodies. An expired
  entry is dropped and fetched again through the pinned transport. Cache lookups happen per
  hop, after admission.
- Raw requests for the same URL/generation coalesce. The last cancelled waiter cancels its
  transport. `clearCache()` atomically detaches old raw requests, bumps the existing remote
  generation and empties the raw cache, then cancels those requests outside the cache lock.
  A fetch that started before the wipe cannot return bytes or repopulate the cache afterwards.
  Newly registered requests retain the new generation. `clearLocalCache()`
  leaves remote state alone. No new generation counter was added.
- Decoded-image registration and old-task detachment use the same atomic privacy-wipe lock;
  a download cannot register between cancellation and generation invalidation.

## Testing

All transport behavior is tested with Swift Testing doubles injected through `#if DEBUG`
initializers: `RemoteMediaTransport(testingResolver:connectionFactory:clock:dnsSlots:)` and
`RemoteImageLoader(testingTransport:)`. A virtual clock fires timers only when a test moves it
forward, the resolver can be held and released, and connections are fully scripted. No test
sleeps or opens a socket. Scripted transport tests do not use real DNS; the separate
`SystemRemoteMediaResolver.blockingResolve("localhost")` smoke case uses the native resolver
and is host-dependent, not a deterministic transport test. See `RemoteMediaHTTPParserTests`,
`RemoteMediaTransportTests` and the `remoteImageLoader…` tests in `MediaTests`.

## Native qualification still required

Fakes cannot prove these. Each needs a native check on macOS 15.6 / arm64 before release:

- **TLS name override.** Check against a real host that a pinned numeric connection with
  `sec_protocol_options_set_tls_server_name` succeeds for the right name and fails for a
  wrong one (for example the name of another host that resolves to the same CDN address). The
  name cannot be read back from `NWParameters`, so unit tests do not cover it.
- **IP-literal origins.** Check that a literal-IP endpoint with no server name is verified
  against its IP SAN, and fails when the certificate has no matching IP SAN.
- **Proxies.** `preferNoProxies` is documented as ignoring enabled system proxies, but it is a
  preference, not a guarantee. The newer `NWParametersProvider.noProxiesPreferred` is
  documented as falling back. Check with a configured system/PAC proxy that the connection
  still goes to the admitted address and not through the proxy (or else fails).
- **VPN routing, public-server tracking, and native image-codec memory** are outside what DNS
  pinning protects.
- **Clean-close bodies.** A body that ends at connection close relies on Network.framework
  reporting TLS truncation (no `close_notify`) as an error and not as a clean end.
  `Content-Length` and `chunked` bodies are unaffected.
- **IDN hostnames.** Hostnames that Foundation hands over as non-ASCII are refused rather
  than converted.
- **Compatibility.** The adapter uses HTTP/1.1 with identity content encoding and a fresh
  connection per exchange, without HTTP/2, HTTP/3 or connection reuse. Qualify ordinary CDN
  avatars and GIF searches; a transport-only failure must not silently use an unpinned client.
- **Address-family fallback.** Admitted addresses are attempted sequentially rather than
  raced with Happy Eyeballs. A blackholed first address can spend the 15-second idle budget
  before fallback. A burst beyond six active and 128 queued DNS callers is deliberately refused.
- **Network-specific DNS64.** Embedded private IPv4 is checked for the well-known NAT64
  prefix, not arbitrary network-specific translation prefixes. VPN/router routing can also
  map nominally public destinations to internal services; address pinning is not a guarantee
  against local network remapping. Keep this limitation distinct from ordinary DNS rebinding.
