# beamtalk-http

HTTP client and server library for [Beamtalk](https://beamtalk.dev).

Built on [gun](https://github.com/ninenines/gun) (client) and
[Buccaneer](https://github.com/jamesc/beamtalk-buccaneer) (server), a
pure-Beamtalk HTTP/1.1, HTTP/2 and WebSocket engine. Since 0.3.0 the
server no longer uses cowboy; see the [CHANGELOG](CHANGELOG.md) for
what changed.

## Installation

Add the dependency to your `beamtalk.toml`:

```toml
[dependencies]
http = "0.3.0"
```

Then run:

```bash
beamtalk build
```

## Usage

### HTTP Client (one-shot)

```beamtalk
resp := (HTTPClient get: "https://httpbin.org/get") unwrap
resp status   // => 200
resp body     // => "..."

resp := (HTTPClient post: "https://httpbin.org/post" body: "{}") unwrap
```

### HTTP Client (persistent actor)

```beamtalk
client := HTTPClient spawnWith: #{
  #baseUrl => "https://api.example.com",
  #headers => #(#("Authorization", "Bearer token")),
  #timeout => 10000
}
resp := (client get: "/users") unwrap
client stop
```

### HTTP Server

```beamtalk
srv := HTTPServer start: 8080 handler: [:req |
  req method == "GET" ifTrue: [
    HTTPResponse new: #{ #status => 200, #body => "hello" }
  ] ifFalse: [
    HTTPResponse new: #{ #status => 405, #body => "method not allowed" }
  ]
]
srv port   // => 8080
srv stop
```

### Server engine

`HTTPServer` runs on Buccaneer, the only server engine since 0.3.0.
Request handling to know about:

- `req body` is capped at 8 MB (larger bodies answer 413), while
  `req readChunk` streams past that in parts (below).
- Responses are compressed when the client asks for it: a request with
  `accept-encoding: gzip` (or `deflate`, or `zstd` on OTP 28+) gets an
  encoded body, and responses carry `vary: accept-encoding` (except
  204s). A handler opts one response out by setting its own
  `content-encoding`, a strong `etag` or `cache-control: no-transform`.
- Repeated request headers arrive as separate `#(name, value)` pairs.
- Malformed percent-encoding or invalid UTF-8 in the query, an invalid
  UTF-8 header value and malformed chunk framing answer 400 without
  running the handler.
- The handler is validated at start: a block, an `HTTPRouter`, or an
  actor responding to `handle:` (anything else raises a `type_error`).
  A port already in use raises a catchable `Error`.
- `#bind` takes IPv4 dotted quads and IPv6 (with `::` compression and
  embedded v4 tails).

cowboy was removed in 0.3.0, along with the `#backend` option. Pin
`http = "0.2.0"` to stay on cowboy.

### Streaming

Handlers answer one `HTTPResponse` value in three shapes. Plain values
go out with `status`/`headers`/`body` as before. The other two stream,
in bounded memory:

```beamtalk
// Chunked: the adapter runs the block in the connection process.
HTTPResponse streamWith: [:resp |
  resp startChunked: 200 headers: #(#("content-type", "text/plain"))
  resp sendChunk: "part 1"
  resp sendChunk: "part 2"
  resp finish]

// Sendfile (a read-and-send loop over TLS): plain values.
(HTTPResponse file: "test/fixtures/stream_file") withStatus: 200
(HTTPResponse file: "test/fixtures/stream_file" offset: 4 length: 6)
  withStatus: 200
```

`startChunked:` answers `Result ok: nil`, or `Result error: #closed`
when the client has gone (as does `sendChunk:`); a second start raises
`AlreadySent`. If the block returns without `finish`, the adapter
finishes the response; if it never calls `startChunked:headers:`, the
request is a 500. A raise after the headers went out cannot become a
500: the connection is closed and the error is logged.

Request bodies stream the same way, for block and router handlers
(which run in the connection process):

```beamtalk
total := 0
done := false
[done] whileFalse: [
  chunk := (req readChunk) unwrap   // Result(Binary, Error); empty means end
  chunk isEmpty ifTrue: [done := true] ifFalse: [total := total + chunk size]
]
```

`req body` stays and reads the rest (bounded by 8 MB, 413 past it).
`req inform: 103 headers: h` sends an interim response (`Result error:
#not_supported` on HTTP/1.0); `100 Continue` goes out automatically on
the first body read. `HTTPHandler` actors get the whole body read
before they are called.

Every handle here is owner-bound: `readChunk`, `inform:headers:` and
the writer's methods (`startChunked:headers:`, `sendChunk:`, `finish`)
work only in the connection process and raise a clear `#not_owner`
error anywhere else. (`req body` answers the buffered body off-owner,
so actors keep working; without an exchange, as in a hand-built
request, `readChunk` and `inform:headers:` answer `Result error:
#not_supported`.)

### WebSocket

Any handler — block, router or `HTTPHandler` actor — upgrades a
connection by answering `HTTPResponse upgradeWebSocket: HandlerClass`:

```beamtalk
HTTPServer start: 8080 handler: [:req |
  HTTPResponse upgradeWebSocket: EchoHandler]
```

`HandlerClass` makes a `WebSocketHandler` Value that runs in the
connection process — no actor per connection, no extra hop per frame.
The handler is its own state: `onOpen:request:` (sent to the class)
answers the first state, and each data callback answers the next:

```beamtalk
sealed Value subclass: EchoHandler
  class onOpen: ws :: WebSocketHandle request: req :: HTTPRequest -> EchoHandler =>
    self new

  onText: text :: String ws: ws :: WebSocketHandle -> EchoHandler =>
    ws sendText: text
    self

  onClose: reason :: Object -> Object => nil
```

`onBinary:` takes the binary frames, `onInfo:` (optional) takes any
other message to the connection process, and `onClose:` (optional)
ends it — `#normal`, `#remote`, `#shutdown`, `#timeout` or
`{#error, reason}`, as the engine reports it. Pings are answered by
the engine itself, so the handler never sees control frames. Frames
go out through `ws` (`sendText:`, `sendBinary:`, `close:`,
`close:`), a handle owned by the connection process that the handler
may keep in a field. Like the streaming handles, it is owner-bound:
anything but the connection process raises `#not_owner`.

A handler that wants an actor forwards to one itself: create or look
up the actor in `onOpen:`, keep it in a field, and cast each message
to it. The actor pushes back by sending a message to the connection
process (`ws pid`), which arrives in the handler's `onInfo:`. The
actor never touches `ws`:

```beamtalk
class onOpen: ws :: WebSocketHandle request: req :: HTTPRequest -> RoomHandler =>
  room := WsRoomActor spawn
  room join: ws pid!
  (self new withRoom: room) withWsPid: ws pid

onText: text :: String ws: _ws :: WebSocketHandle -> RoomHandler =>
  self room post: text!
  self

onInfo: message :: Object ws: ws :: WebSocketHandle -> RoomHandler =>
  message match: [
    {#roomCast, text} -> ws sendText: (text asStringUnchecked);
    _ -> nil
  ]
  self
```

### HTTP Router

```beamtalk
router := HTTPRouter build: [:r |
  r get: "/hello" handler: [:req |
    HTTPResponse new: #{ #status => 200, #body => "hello world" }
  ]
  r post: "/echo" handler: [:req |
    HTTPResponse new: #{ #status => 200, #body => req body }
  ]
]

srv := HTTPServer start: 8080 handler: router
```

### Plug middleware

`Plug`/`PlugChain` compose reusable request/response middleware (JSON body
parsing, auth checks, logging) around a handler, the same "onion" style as
Rack or Express middleware:

```beamtalk
Value subclass: RequestLogger
  call: request :: HTTPRequest next: next :: Block(HTTPRequest, HTTPResponse) -> HTTPResponse =>
    response := next value: request
    Logger info: request method ++ " " ++ request path ++ " -> " ++ response status printString
    response

handler := PlugChain
  chain: #(RequestLogger new)
  handler: [:req | HTTPResponse new: #{ #status => 200, #body => "ok" }]
srv := HTTPServer start: 8080 handler: handler
```

A `PlugChain`'s composed handler is a plain block, so it runs outside the
owning actor's process — see "Handler styles" below before reaching for a
Plug that needs live, mutable actor state.

### Handler styles: block vs. actor

`HTTPServer`/`HTTPRouter` accept two kinds of handler with different state
visibility:

- **Block or `HTTPRouter`-compiled route** — invoked directly as a plain
  function call in the connection process that received the request.
  Any `self.field`
  the block closes over is whatever was captured when the block/route
  table was built; it is never re-read, even if the underlying actor's
  state changes later (including `attachX:`-style dependency injection
  performed after `startServer:` has already run). `PlugChain` inherits
  this — plugs are just blocks under the hood.
- **Actor implementing `HTTPHandler>>handle:`** — invoked via a real actor
  message send, so `handle:` runs inside the actor's own process. `self.field`
  reads are always current, and further actor calls behave normally.

Use a block/router/`PlugChain` for stateless request handling; back a route
with an `HTTPHandler` actor when it needs live or post-startup-configurable
state.

An actor streams the same way every handler does, with `streamWith:`:
the block is created in the actor but runs in the
connection process. It sees the actor's fields as captured when the block
was made, assigning one raises `actor_state_unreachable`, and a send to
`self` is an ordinary sync message to the actor — so the block can pull
each chunk from the live actor:

```beamtalk
Actor subclass: ReportHandler
  handle: req :: HTTPRequest -> HTTPResponse =>
    HTTPResponse streamWith: [:resp |
      resp startChunked: 200 headers: #(#("content-type", "text/csv"))
      [self hasMoreRows] whileTrue: [resp sendChunk: self nextRows]
      resp finish]
```

## Classes

| Class | Description |
|-------|-------------|
| `HTTPClient` | Actor-based HTTP client for one-shot and persistent requests |
| `HTTPServer` | HTTP server actor, served by Buccaneer |
| `HTTPRequest` | Incoming HTTP request representation |
| `HTTPResponse` | HTTP response builder |
| `HTTPRouter` | URL routing with method-based dispatch |
| `HTTPRoute` | Individual route definition |
| `HTTPRouteBuilder` | Fluent route builder |
| `Plug` | Protocol for composable request/response middleware |
| `PlugChain` | Composes a list of `Plug`s and a handler into one handler block |

## Development

```bash
just build    # Build the package
just test     # Run tests
just fmt      # Check formatting
just ci       # Full CI check (fmt + build + test)
```

## License

Apache-2.0 -- Copyright 2026 James Casey
