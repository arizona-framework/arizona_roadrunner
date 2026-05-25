# arizona_roadrunner

Roadrunner HTTP/WebSocket adapter for the
[Arizona](https://github.com/arizona-framework/arizona) real-time web framework.

Implements the `arizona_req` behaviour against Roadrunner and ships a listener
boot helper plus the matching router/HTTP/WS/static/reload handlers.

This is the **default and recommended** adapter for Arizona. Use
[`arizona_cowboy`](https://github.com/arizona-framework/arizona_cowboy)
instead only if you need to run on Erlang/OTP 28 or older.

## Requirements

- Erlang/OTP 29 or newer (enforced via `minimum_otp_vsn`)
- [Arizona](https://github.com/arizona-framework/arizona) `~> 0.1`
- [Roadrunner](https://github.com/arizona-framework/roadrunner) (currently
  pinned to a post-#17 commit; will move to a hex version once roadrunner
  publishes 0.2.0)

## Installation

```erlang
{deps, [
    {arizona, "~> 0.1"},
    {arizona_roadrunner, "~> 0.1"}
]}.
```

Add to your `.app.src` `applications` list:

```erlang
{applications, [kernel, stdlib, arizona, arizona_roadrunner]}.
```

## Configuration

Tell Arizona to boot Roadrunner by setting `adapter =>
arizona_roadrunner_server` in the `arizona` server env:

```erlang
[{arizona, [
    {server, #{
        adapter => arizona_roadrunner_server,
        scheme => http,
        transport_opts => [{port, 4040}],
        proto_opts => #{
            max_clients => 200,
            max_content_length => 10485760
        },
        routes => [
            {live, ~"/", my_page, #{layouts => [{my_layout, render}]}},
            {ws, ~"/ws", #{}},
            {asset, ~"/assets", {priv_dir, my_app, "static/assets"}}
        ]
    }}
]}].
```

`arizona_roadrunner_server:start/2` calls
`application:ensure_all_started(roadrunner)` itself, so roadrunner doesn't
need to be listed before `arizona` in your `applications`.

### Enabling HTTP/2

Roadrunner ships with HTTP/2 support. Browsers require TLS + ALPN, so pair
`scheme => https` with a `tls` config and opt in via `proto_opts.protocols`:

```erlang
#{
    adapter => arizona_roadrunner_server,
    scheme => https,
    tls => [{certfile, "priv/cert.pem"}, {keyfile, "priv/key.pem"}],
    proto_opts => #{protocols => [http1, http2]},
    routes => [...]
}
```

## Modules

| Module                        | Purpose                                                          |
| ----------------------------- | ---------------------------------------------------------------- |
| `arizona_roadrunner_server`   | Listener boot — compiles routes, validates TLS, starts listener  |
| `arizona_roadrunner_router`   | Translates Arizona routes into roadrunner's map-shape routes     |
| `arizona_roadrunner_http`     | HTTP handler — delegates to `arizona_http:render/3`              |
| `arizona_roadrunner_ws`       | WebSocket handler — delegates to `arizona_ws:prepare/3`          |
| `arizona_roadrunner_static`   | Static file handler (zero-copy `sendfile`)                       |
| `arizona_roadrunner_req`      | `arizona_req` adapter; populates `request_id`                    |
| `arizona_roadrunner_reload`   | Dev SSE endpoint streaming `arizona_reloader` events             |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache-2.0. See [LICENSE.md](LICENSE.md).
