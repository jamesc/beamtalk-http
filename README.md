# beamtalk-http

HTTP client and server library for [Beamtalk](https://beamtalk.dev).

Built on [gun](https://github.com/ninenines/gun) (client) and [cowboy](https://github.com/ninenines/cowboy) (server).

## Installation

Add the dependency to your `beamtalk.toml`:

```toml
[dependencies]
http = "0.1.0"
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
  function call in cowboy's own request-handling process. Any `self.field`
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

## Classes

| Class | Description |
|-------|-------------|
| `HTTPClient` | Actor-based HTTP client for one-shot and persistent requests |
| `HTTPServer` | Cowboy-backed HTTP server actor |
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
