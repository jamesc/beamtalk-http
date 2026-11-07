# Changelog

## Unreleased

### HTTPClient runs on Mint; gun is removed

`HTTPClient` now performs requests through
[Mint](https://github.com/jamesc/beamtalk-mint), a pure-Beamtalk
HTTP/1.1 and HTTP/2 client, instead of gun. `native/beamtalk_http.erl`
(and its `beamtalk_http_tests` / `beamtalk_http_response` companions)
is deleted, gun and cowlib leave `beamtalk.toml`/`beamtalk.lock`, and
the client helpers live in `src/httpclient.bt` with BUnit coverage in
`test/httpclient_utils_test.bt`. The public API is unchanged: the same
one-shot verbs, `request:url:options:` (`#headers`/`#body`/`#timeout`/
`#maxBodyBytes`) and the persistent `spawnWith:` style, with the same
`Result` / `type_error` outcomes.

Behaviour notes:

- **`https` negotiates H1 and H2.** Plain `http` uses `MintHTTP1`;
  `https` offers both `h2` and `http/1.1` over ALPN with gun's
  verification (`verify_peer` against the system CA bundle, SNI,
  HTTPS hostname check) and runs the negotiated protocol.
- **Persistent clients reuse one connection.** Instance requests share
  the actor's Mint connection across calls (reconnecting when the
  server closed it); one-shot class methods still connect per request.
- **Timeouts.** The `#timeout` option still bounds a request, but the
  connect phase now shares the request timeout instead of gun's
  dedicated 2s connect / 5s TLS-handshake caps.
- **`maxBodyBytes` is enforced after the body arrives.** Mint delivers
  whole bodies, so an over-large body is still downloaded before it is
  refused, where gun aborted the transfer mid-stream.

## 0.3.0 (unreleased)

### Breaking: the server runs on Buccaneer only; cowboy is removed

`HTTPServer` now always serves through
[Buccaneer](https://github.com/jamesc/beamtalk-buccaneer), a pure-Beamtalk
HTTP/1.1, HTTP/2 and WebSocket engine (a port of Elixir's Bandit). In 0.2
Buccaneer was opt-in behind `#backend => #buccaneer`, and cowboy was the
default. cowboy and ranch are no longer dependencies: the only native
dependency left is gun (with cowlib), for `HTTPClient`.

The same handlers, routers, plugs and tests run unchanged. What changes
for code that used the 0.2 default:

- **`#backend` option and `BEAMTALK_HTTP_BACKEND` are removed.** There
  is one engine, so there is nothing to select. Like any other unknown
  option, a `#backend` key is ignored. To keep cowboy, pin `http = "0.2.0"`.
- **`HTTPServer` is a plain Beamtalk actor.** It owns the Buccaneer server
  directly. The internal `HTTPBuccaneerServer` class is gone, and
  `HTTPServer start:handler:options:` always answers an `HTTPServer`.

### Behaviour differences from the 0.2 cowboy server

- **Response compression is on by default.** A request whose
  `accept-encoding` allows it gets a compressed body (zstd on OTP 28+, then
  gzip, x-gzip, deflate), and every response but a 204 carries
  `vary: accept-encoding`. cowboy sent bodies identity-encoded unless a
  handler compressed them. A handler opts a response out by setting its own
  `content-encoding`, a strong `etag` or `cache-control: no-transform`.
  `HTTPServer` does not expose Buccaneer's `#compress` switch yet. `HTTPClient`
  sends no `accept-encoding` unless you add one, so it still gets plain
  bodies by default.
- **Request bodies are capped at 8 MB.** `req body` answers 413 past it;
  cowboy read bodies of any size. `req readChunk` streams larger bodies in
  parts. Block and router handlers read the body lazily (on first
  `req body`); `HTTPHandler` actors still get the whole body before they
  are called.
- **Repeated request headers stay separate** `#(name, value)` pairs in
  `req headers`; cowboy joined them into one value with `", "`.
- **Bad input answers 400 without running the handler**: malformed
  percent-encoding or invalid UTF-8 in the query, an invalid UTF-8 header
  value, malformed chunk framing. cowboy crashed some of these into a 500.
  The query 400's body is `Bad Request: invalid UTF-8 in query` (cowboy's
  was `... in query_value`).
- **Streaming, files and WebSocket work.** `HTTPResponse streamWith:`,
  `file:`, `file:offset:length:` and `upgradeWebSocket:` were 500s on
  cowboy; they are served now.
- **Start-time failures are catchable.** An invalid handler raises a
  `type_error` before anything starts, and a port already in use raises an
  `Error` that `on:do:`/`Result tryDo:` can catch; on cowboy the native
  listener failure crashed the starting process.
- **Response headers.** The engine adds `date` and `content-length` as
  cowboy did, but no `server` header (cowboy sent `server: Cowboy`).
- **Request limits** follow Bandit's defaults: a 10,000-byte request line
  and header line, at most 50 request headers, and unlimited requests per
  keep-alive connection. cowboy's defaults were an 8,000-byte request
  line, 100 headers and 1,000 requests per connection.

### Other changes

- `HTTPRouter` matching is now written in Beamtalk (it was the native
  `beamtalk_http_router` module). Routes, parameters, wildcards and the
  404/405 answers behave as before. `HTTPRouter>>match:path:` answers
  `{#ok, handler, params}`, `#method_not_allowed` or `#not_found`.
- The client test suite runs against a Buccaneer-backed BUnit fixture
  (`HTTPTestServer`) instead of a cowboy test server. The cowboy server's
  and router's EUnit suites are now BUnit tests.
- Removed native modules: `beamtalk_http_server`,
  `beamtalk_http_server_handler`, `beamtalk_http_router` and the cowboy
  test server. The remaining native modules (`beamtalk_http`,
  `beamtalk_http_text`, `beamtalk_http_response`) belong to the gun client.
- gun's cowlib is now locked at 2.13.0, the version gun 2.1.0 asks for;
  cowboy had pulled it up to 2.21.0.
