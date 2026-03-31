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
router := HTTPRouter new
router get: "/hello" handler: [:req |
  HTTPResponse new: #{ #status => 200, #body => "hello world" }
]
router post: "/echo" handler: [:req |
  HTTPResponse new: #{ #status => 200, #body => req body }
]

srv := HTTPServer start: 8080 handler: router
```

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

## Development

```bash
just build    # Build the package
just test     # Run tests
just fmt      # Check formatting
just ci       # Full CI check (fmt + build + test)
```

## License

Apache-2.0 -- Copyright 2026 James Casey
