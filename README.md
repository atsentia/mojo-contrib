# mojo-contrib

Enterprise foundation libraries for Mojo—production-ready building blocks for mission-critical systems.

## Why Pure Mojo?

Mojo delivers C and Rust-level performance, but the ecosystem lacks the established toolkit that enterprise systems require. These 26 libraries address that gap with:

- **No interpreter overhead** — Eliminates Python runtime and cross-language marshaling costs
- **Single binary deployment** — Simplifies containers, reduces attack surface
- **Compile-time safety** — Catches errors before production
- **Resource efficiency** — Every CPU cycle saved is energy not consumed, reducing cloud costs and environmental impact

## Getting Started

```bash
# Clone with all submodules
git clone --recursive git@github.com:atsentia/mojo-contrib.git

# Or initialize submodules after cloning
git clone git@github.com:atsentia/mojo-contrib.git
cd mojo-contrib
git submodule update --init --recursive
```

## Libraries

### Identity & Security

| Library | Standards | Description |
|---------|-----------|-------------|
| [mojo-jwt](https://github.com/atsentia/mojo-jwt) | RFC 7519 | JWT creation and validation with timing-attack protections |
| [mojo-oauth2](https://github.com/atsentia/mojo-oauth2) | RFC 6749 | OAuth 2.0 with PKCE, pre-configured providers (Google, GitHub, Microsoft, Okta) |
| [mojo-auth](https://github.com/atsentia/mojo-auth) | — | Role-based access control (RBAC) |
| [mojo-crypto](https://github.com/atsentia/mojo-crypto) | FIPS 180-4 | SHA-256/512, HMAC, PBKDF2 |
| [mojo-validation](https://github.com/atsentia/mojo-validation) | — | Schema validation for untrusted input |

### Resilience Patterns

| Library | Patterns | Description |
|---------|----------|-------------|
| [mojo-resilience](https://github.com/atsentia/mojo-resilience) | Circuit breaker, retry, bulkhead | Fault tolerance for distributed systems |

Circuit breakers prevent cascade failures. Retry with exponential backoff handles transient errors. Rate limiting protects downstream services. Bulkhead isolation contains failures.

### Observability

| Library | Standards | Description |
|---------|-----------|-------------|
| [mojo-trace](https://github.com/atsentia/mojo-trace) | W3C Trace Context, OTLP | Distributed tracing with Jaeger/Tempo integration |
| [mojo-observability](https://github.com/atsentia/mojo-observability) | — | Structured logging and metrics |
| [mojo-health](https://github.com/atsentia/mojo-health) | Kubernetes probes | Liveness, readiness, and startup health checks |

### Data Infrastructure

| Library | Standards | Description |
|---------|-----------|-------------|
| [mojo-redis](https://github.com/atsentia/mojo-redis) | RESP | Redis client for caching, pub/sub, and data structures |
| [mojo-sql](https://github.com/atsentia/mojo-sql) | — | Type-safe SQL query builder with connection pooling |
| [mojo-cache](https://github.com/atsentia/mojo-cache) | — | LRU and TTL-based caching |
| [mojo-session](https://github.com/atsentia/mojo-session) | — | Server-side session management |

### Serialization

| Library | Standards | Description |
|---------|-----------|-------------|
| [mojo-json](https://github.com/atsentia/mojo-json) | RFC 8259 | JSON parsing and generation |
| [mojo-msgpack](https://github.com/atsentia/mojo-msgpack) | MessagePack | Binary serialization for performance-critical paths |
| [mojo-base64](https://github.com/atsentia/mojo-base64) | RFC 4648 | URL-safe Base64 encoding |

### Networking

| Library | Standards | Description |
|---------|-----------|-------------|
| [mojo-http](https://github.com/atsentia/mojo-http) | HTTP/1.1 | HTTP client and server |
| [mojo-server](https://github.com/atsentia/mojo-server) | HTTP/1.1 | Lightweight HTTP server |
| [mojo-websocket](https://github.com/atsentia/mojo-websocket) | RFC 6455 | WebSocket client and server |
| [mojo-socket](https://github.com/atsentia/mojo-socket) | — | TCP sockets via C FFI |

### Utilities

| Library | Description |
|---------|-------------|
| [mojo-config](https://github.com/atsentia/mojo-config) | TOML configuration and environment variables |
| [mojo-time](https://github.com/atsentia/mojo-time) | DateTime parsing, formatting, and arithmetic |
| [mojo-uuid](https://github.com/atsentia/mojo-uuid) | UUID v4 (random) and v7 (time-ordered) generation |
| [mojo-scheduler](https://github.com/atsentia/mojo-scheduler) | Task scheduling with cron expressions |
| [mojo-testing](https://github.com/atsentia/mojo-testing) | Testing framework with mocks and assertions |
| [mojo-result](https://github.com/atsentia/mojo-result) | Generic `Result[T, E]` for explicit error handling |

## Standards Compliance

All implementations follow established specifications—RFC 7519, RFC 8259, RFC 6455, W3C Trace Context—ensuring interoperability with existing enterprise infrastructure rather than creating isolated solutions.

## Project Structure

```
mojo-contrib/
├── auth-security/       # Identity & security libraries
├── serialization/       # JSON, MessagePack, Base64
├── networking/          # HTTP, WebSocket, sockets
├── storage/             # Redis, SQL, caching, sessions
├── observability/       # Tracing, logging, health checks
└── utilities/           # Config, time, UUID, scheduling, testing
```

## License

Apache 2.0 with LLVM Exceptions
