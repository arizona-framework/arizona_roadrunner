# arizona_roadrunner

Roadrunner HTTP/WebSocket server adapter for the
[Arizona](https://github.com/arizona-framework/arizona) real-time web framework.

It implements Arizona's `arizona_server` and `arizona_req` behaviours on
[Roadrunner](https://github.com/arizona-framework/roadrunner). The contract it meets, and the conformance
suite that verifies it, are described in Arizona's
[adapter guide](https://github.com/arizona-framework/arizona/blob/main/docs/adapters.md).

## Requirements

- Erlang/OTP 29 or newer
- [Arizona](https://github.com/arizona-framework/arizona)

## Installation

Depend on both Arizona and the adapter: the adapter does not pull Arizona in
itself (Arizona's own test suites depend on it, and a dependency back would be
a cycle).

```erlang
{deps, [
    arizona,
    arizona_roadrunner
]}.
```

and list both in your application's `applications`:

```erlang
{applications, [kernel, stdlib, arizona, arizona_roadrunner]}.
```

## Configuration

Name the adapter in the `arizona` server env; Arizona has no default:

```erlang
[{arizona, [
    {server, #{
        adapter => arizona_roadrunner_server,
        transport_opts => [{port, 4040}],
        routes => [
            {live, ~"/", my_page, #{layouts => [{my_layout, render}]}},
            {ws, ~"/ws", #{}},
            {asset, ~"/assets", {priv_dir, my_app, "static/assets"}}
        ]
    }}
]}].
```

Roadrunner speaks HTTP/1.1, HTTP/2 and HTTP/3; set `scheme => https` with a
`tls` list for TLS. Roadrunner's own listener options go in `proto_opts`.

## Modules

| Module | Purpose |
| ------ | ------- |
| `arizona_roadrunner_server` | The `arizona_server` adapter: boots, drains and stops listeners |
| `arizona_roadrunner_router` | Compiles Arizona routes into roadrunner's route table |
| `arizona_roadrunner_http` | Renders a live page (server-side render) |
| `arizona_roadrunner_ws` | Bridges a WebSocket to `arizona_socket` |
| `arizona_roadrunner_controller` | Runs controller, MCP and dev reload routes |
| `arizona_roadrunner_req` | The `arizona_req` adapter |

## Development

```bash
make precommit         # fmt, compile, checks, tests
make test-conformance  # Arizona's conformance suite against this checkout
make ci                # everything CI runs
```

`make test-conformance` clones Arizona (`ARIZONA_REF`, default its `main`)
and runs its conformance suite with this checkout linked in through
`_checkouts`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache-2.0. See [LICENSE.md](LICENSE.md).
