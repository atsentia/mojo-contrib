# mojo-contrib

Pure Mojo enterprise libraries collection - 26 libraries, 34,000+ LOC.

## Quick Start

```bash
# Clone with all submodules
git clone --recursive git@github.com:atsentia/mojo-contrib.git

# Or clone then init submodules
git clone git@github.com:atsentia/mojo-contrib.git
cd mojo-contrib
git submodule update --init --recursive

# Update all submodules to latest
git submodule update --remote --merge
```

## Structure

```
mojo-contrib/
├── auth-security/       # Authentication & Security
│   ├── mojo-auth/       #   JWT validation and RBAC
│   ├── mojo-crypto/     #   SHA-256/512, HMAC, PBKDF2
│   ├── mojo-jwt/        #   JWT tokens with HS256
│   ├── mojo-oauth2/     #   OAuth 2.0 with PKCE
│   └── mojo-validation/ #   Schema validation
├── serialization/       # Data Serialization
│   ├── mojo-json/       #   RFC 8259 JSON parser
│   ├── mojo-msgpack/    #   MessagePack serialization
│   └── mojo-base64/     #   URL-safe Base64 encoding
├── networking/          # Networking & HTTP
│   ├── mojo-http/       #   HTTP server/client
│   ├── mojo-server/     #   Pure Mojo HTTP/1.1 server
│   ├── mojo-socket/     #   TCP sockets via C FFI
│   └── mojo-websocket/  #   RFC 6455 WebSocket
├── storage/             # Data Storage & Caching
│   ├── mojo-cache/      #   LRU/TTL cache
│   ├── mojo-redis/      #   RESP protocol Redis client
│   ├── mojo-sql/        #   SQL query builder with pooling
│   └── mojo-session/    #   Session management
├── observability/       # Observability & Monitoring
│   ├── mojo-observability/ # Logging and metrics
│   ├── mojo-trace/      #   OTLP distributed tracing
│   └── mojo-health/     #   Health probes
└── utilities/           # Utilities & Tools
    ├── mojo-config/     #   TOML config and env vars
    ├── mojo-time/       #   DateTime operations
    ├── mojo-uuid/       #   UUID v4/v7 generation
    ├── mojo-scheduler/  #   Task scheduler with cron
    ├── mojo-testing/    #   Testing framework with mocks
    ├── mojo-resilience/ #   Circuit breaker, retry, rate limiting
    └── mojo-result/     #   Generic Result[T,E] error handling
```

## Libraries

### Authentication & Security

| Library | LOC | Tests | Description |
|---------|-----|-------|-------------|
| [mojo-auth](https://github.com/atsentia/mojo-auth) | 578 | 8 | JWT validation and RBAC |
| [mojo-crypto](https://github.com/atsentia/mojo-crypto) | 1,281 | 9 | SHA-256/512, HMAC, PBKDF2 |
| [mojo-jwt](https://github.com/atsentia/mojo-jwt) | 2,215 | 11 | JWT tokens with HS256 |
| [mojo-oauth2](https://github.com/atsentia/mojo-oauth2) | 1,184 | 15 | OAuth 2.0 with PKCE |
| [mojo-validation](https://github.com/atsentia/mojo-validation) | 959 | 17 | Schema validation |

### Data Serialization

| Library | LOC | Tests | Description |
|---------|-----|-------|-------------|
| [mojo-json](https://github.com/atsentia/mojo-json) | 1,839 | 27 | RFC 8259 JSON parser |
| [mojo-msgpack](https://github.com/atsentia/mojo-msgpack) | 1,468 | 32 | MessagePack serialization |
| [mojo-base64](https://github.com/atsentia/mojo-base64) | 369 | 11 | URL-safe Base64 encoding |

### Networking & HTTP

| Library | LOC | Tests | Description |
|---------|-----|-------|-------------|
| [mojo-http](https://github.com/atsentia/mojo-http) | 1,337 | 18 | HTTP server/client |
| [mojo-server](https://github.com/atsentia/mojo-server) | 1,176 | 11 | Pure Mojo HTTP/1.1 server |
| [mojo-socket](https://github.com/atsentia/mojo-socket) | 853 | 12 | TCP sockets via C FFI |
| [mojo-websocket](https://github.com/atsentia/mojo-websocket) | 2,520 | 27 | RFC 6455 WebSocket |

### Data Storage & Caching

| Library | LOC | Tests | Description |
|---------|-----|-------|-------------|
| [mojo-cache](https://github.com/atsentia/mojo-cache) | 389 | 11 | LRU/TTL cache |
| [mojo-redis](https://github.com/atsentia/mojo-redis) | 2,166 | 21 | RESP protocol Redis client |
| [mojo-sql](https://github.com/atsentia/mojo-sql) | 2,232 | 35 | SQL query builder with pooling |
| [mojo-session](https://github.com/atsentia/mojo-session) | 388 | 13 | Session management |

### Observability & Monitoring

| Library | LOC | Tests | Description |
|---------|-----|-------|-------------|
| [mojo-observability](https://github.com/atsentia/mojo-observability) | 1,270 | 5 | Logging and metrics |
| [mojo-trace](https://github.com/atsentia/mojo-trace) | 2,599 | 8 | OTLP distributed tracing |
| [mojo-health](https://github.com/atsentia/mojo-health) | 856 | 9 | Health probes |

### Utilities & Tools

| Library | LOC | Tests | Description |
|---------|-----|-------|-------------|
| [mojo-config](https://github.com/atsentia/mojo-config) | 616 | 7 | TOML config and env vars |
| [mojo-time](https://github.com/atsentia/mojo-time) | 1,868 | 34 | DateTime operations |
| [mojo-uuid](https://github.com/atsentia/mojo-uuid) | 324 | 8 | UUID v4/v7 generation |
| [mojo-scheduler](https://github.com/atsentia/mojo-scheduler) | 1,528 | 31 | Task scheduler with cron |
| [mojo-testing](https://github.com/atsentia/mojo-testing) | 754 | 15 | Testing framework with mocks |
| [mojo-resilience](https://github.com/atsentia/mojo-resilience) | 1,289 | 14 | Circuit breaker, retry, rate limiting |
| [mojo-result](https://github.com/atsentia/mojo-result) | ~200 | 12 | Generic Result[T,E] error handling |

**Total: 34,000+ LOC | 414 tests**

## License

MIT
