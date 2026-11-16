-module(arizona_roadrunner_grpc_SUITE).
-moduledoc """
The `{grpc, Services, Opts}` route: gRPC services served by `roadrunner_grpc`
on the same listener and port as the Arizona routes.
""".
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).

-export([expands_to_roadrunner_grpc_routes/1]).
-export([serves_a_call_beside_an_arizona_route/1]).
-export([passes_its_options_to_roadrunner/1]).
-export([answers_http1_with_505/1]).
-export([survives_a_route_recompile/1]).
-export([streams_beside_a_manual_body_read/1]).
-export([refuses_a_listener_without_http2/1]).
-export([refuses_a_bad_shape/1]).
-export([accepts_http2_with_options/1]).
-export([counts_http3_as_carrying_grpc/1]).
-export([refuses_an_earlier_post_catch_all/1]).
-export([answers_a_get_with_405/1]).
-export([a_broken_service_edit_keeps_the_listener_reloadable/1]).
-export([a_broken_middleware_edit_keeps_both_tables/1]).
-export([log/2]).

all() ->
    [
        expands_to_roadrunner_grpc_routes,
        serves_a_call_beside_an_arizona_route,
        passes_its_options_to_roadrunner,
        answers_http1_with_505,
        survives_a_route_recompile,
        streams_beside_a_manual_body_read,
        refuses_a_listener_without_http2,
        refuses_a_bad_shape,
        accepts_http2_with_options,
        counts_http3_as_carrying_grpc,
        refuses_an_earlier_post_catch_all,
        answers_a_get_with_405,
        a_broken_service_edit_keeps_the_listener_reloadable,
        a_broken_middleware_edit_keeps_both_tables
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(arizona),
    Config.

end_per_suite(Config) when is_list(Config) ->
    ok = application:stop(arizona).

%% --------------------------------------------------------------------
%% Cases
%% --------------------------------------------------------------------

%% One route per service, plus the health service when asked for, each served
%% by `roadrunner_grpc` rather than an Arizona handler.
expands_to_roadrunner_grpc_routes(Config) when is_list(Config) ->
    Routes = arizona_roadrunner_router:routes(
        [{grpc, [arizona_roadrunner_grpc_echo], #{health => true}}], #{}
    ),
    ?assertEqual(
        [~"/grpc.health.v1.Health/:method", ~"/test.Echo/:method"],
        lists:sort([Path || #{path := Path, handler := roadrunner_grpc} <- Routes])
    ),
    ?assertEqual(2, length(Routes)).

%% A gRPC call and a plain HTTP/1.1 request reach the same plain-TCP port.
serves_a_call_beside_an_arizona_route(Config) when is_list(Config) ->
    with_listener(#{}, fun(Port) ->
        ?assertMatch({ok, ~"echo: hi", _}, unary(Port, ~"/test.Echo/Say", ~"hi")),
        ?assertMatch({200, ~"hello"}, http1(Port, ~"GET", ~"/hello", <<>>))
    end).

%% `health => true` reaches roadrunner: its health service answers SERVING.
passes_its_options_to_roadrunner(Config) when is_list(Config) ->
    with_listener(#{}, fun(Port) ->
        %% HealthCheckResponse{status = SERVING}: field 1, varint 1.
        ?assertMatch({ok, <<8, 1>>, _}, unary(Port, ~"/grpc.health.v1.Health/Check", <<>>))
    end).

%% The gRPC path is `roadrunner_grpc`'s, not an Arizona route's: over
%% HTTP/1.1 it answers 505, as gRPC needs HTTP/2.
answers_http1_with_505(Config) when is_list(Config) ->
    with_listener(#{}, fun(Port) ->
        ?assertMatch({505, _}, http1(Port, ~"POST", ~"/test.Echo/Say", <<>>))
    end).

%% A dev hot reload rebuilds the listener's table from the stashed routes, the
%% gRPC route included.
survives_a_route_recompile(Config) when is_list(Config) ->
    with_listener(#{}, fun(Port) ->
        ok = arizona_roadrunner_server:recompile_routes(),
        ?assertMatch({ok, ~"echo: again", _}, unary(Port, ~"/test.Echo/Say", ~"again"))
    end).

%% Under `body_buffering => manual` a bidirectional call answers each request
%% as it arrives, and an Arizona controller on the same listener still reads
%% its whole body.
streams_beside_a_manual_body_read(Config) when is_list(Config) ->
    with_listener(#{body_buffering => manual}, fun(Port) ->
        {ok, Conn} = roadrunner_grpc_client:connect(~"localhost", Port, #{}),
        try
            {ok, Stream} = roadrunner_grpc_client:stream(Conn, ~"/test.Echo/Chat"),
            ok = roadrunner_grpc_client:send(Stream, ~"one"),
            %% Answered before the client ends its requests: the call streams.
            ?assertEqual({ok, ~"one"}, roadrunner_grpc_client:recv(Stream, 5000)),
            ok = roadrunner_grpc_client:close_send(Stream),
            ?assertMatch({eof, _}, roadrunner_grpc_client:recv(Stream, 5000))
        after
            ok = roadrunner_grpc_client:close(Conn)
        end,
        ?assertMatch({200, ~"got: a body"}, http1(Port, ~"POST", ~"/body", ~"a body"))
    end).

%% Over HTTP/1.1 alone every call would be answered 505, so the start fails
%% naming the fix, and leaves no routes behind.
refuses_a_listener_without_http2(Config) when is_list(Config) ->
    Opts = #{
        transport_opts => [{port, pick_port()}],
        routes => [{grpc, [arizona_roadrunner_grpc_echo], #{}}]
    },
    ?assertError({grpc_requires_http2, [http1]}, arizona_roadrunner_server:start(grpc_h1, Opts)),
    ?assertError(
        {grpc_requires_http2, [http1]},
        arizona_roadrunner_server:start(grpc_h1, Opts#{proto_opts => #{protocols => [http1]}})
    ),
    ?assertEqual(undefined, persistent_term:get({arizona_roadrunner_routes, grpc_h1}, undefined)),
    Message = format(fun() -> arizona_roadrunner_server:start(grpc_h1, Opts) end),
    ?assertNotEqual(nomatch, binary:match(Message, ~"add http2 to proto_opts.protocols")).

%% A gRPC route takes a list of services and a map of the other options;
%% anything else is refused naming the shape, before the listener exists.
refuses_a_bad_shape(Config) when is_list(Config) ->
    Start = fun(Route) ->
        arizona_roadrunner_server:start(grpc_bad, #{
            transport_opts => [{port, pick_port()}],
            proto_opts => #{protocols => [http1, http2]},
            routes => [Route]
        })
    end,
    [
        ?assertError({invalid_grpc_route, Route}, Start(Route))
     || Route <- [
            {grpc, arizona_roadrunner_grpc_echo, #{}},
            {grpc, [arizona_roadrunner_grpc_echo], []},
            {grpc, [arizona_roadrunner_grpc_echo], #{services => [arizona_roadrunner_grpc_echo]}}
        ]
    ],
    ?assertEqual(undefined, persistent_term:get({arizona_roadrunner_routes, grpc_bad}, undefined)),
    Message = format(fun() -> Start({grpc, arizona_roadrunner_grpc_echo, #{}}) end),
    ?assertNotEqual(nomatch, binary:match(Message, ~"is not a gRPC route")).

%% A protocol given with its options (`{http2, Opts}`) carries gRPC too.
accepts_http2_with_options(Config) when is_list(Config) ->
    {ok, _} = arizona_roadrunner_server:start(grpc_h2_opts, #{
        transport_opts => [{port, pick_port()}],
        proto_opts => #{protocols => [http1, {http2, #{}}]},
        routes => [{grpc, [arizona_roadrunner_grpc_echo], #{}}]
    }),
    ok = arizona_roadrunner_server:stop(grpc_h2_opts).

%% HTTP/3 carries gRPC, so a listener offering it passes the gRPC check and
%% fails only on roadrunner's own rule that HTTP/3 needs TLS.
counts_http3_as_carrying_grpc(Config) when is_list(Config) ->
    ?assertMatch(
        {error, {{{listener_opt_conflict, protocols, _, http3_requires_tls}, _}, _}},
        arizona_roadrunner_server:start(grpc_h3, #{
            transport_opts => [{port, pick_port()}],
            proto_opts => #{protocols => [http1, http3]},
            routes => [{grpc, [arizona_roadrunner_grpc_echo], #{}}]
        })
    ).

%% An earlier route answering POST on every two-segment path would take every
%% gRPC call; the listener refuses to start instead.
refuses_an_earlier_post_catch_all(Config) when is_list(Config) ->
    [
        ?assertError(
            {unreachable_route, _, _, _},
            arizona_roadrunner_server:start(grpc_shadowed, #{
                transport_opts => [{port, pick_port()}],
                proto_opts => #{protocols => [http1, http2]},
                routes => [
                    {post, Path, arizona_roadrunner_grpc_body, #{state => #{prefix => <<>>}}},
                    {grpc, [arizona_roadrunner_grpc_echo], #{}}
                ]
            })
        )
     || Path <- [~"/:a/:b", ~"/*rest"]
    ],
    ok.

%% A gRPC path answers POST only: the router turns a GET away with 405.
answers_a_get_with_405(Config) when is_list(Config) ->
    with_listener(#{}, fun(Port) ->
        ?assertMatch({405, _}, http1(Port, ~"GET", ~"/test.Echo/Say", <<>>))
    end).

%% A dev hot reload runs the services' code again (roadrunner's `init_route`).
%% An edit that breaks one fails the rebuild of each listener serving it, and
%% of that listener only: it keeps its tables and serves on, each failure is
%% logged, and every other listener still reloads (so does the page). Fixing the
%% edit rebuilds it on the next reload.
a_broken_service_edit_keeps_the_listener_reloadable(Config) when is_list(Config) ->
    ok = load_service(Config, arizona_roadrunner_grpc_reloaded, [{say, say}]),
    ok = load_service(Config, arizona_roadrunner_grpc_reloaded_b, [{say, say}]),
    Start = fun(Name, Service) ->
        Port = pick_port(),
        {ok, _} = arizona_roadrunner_server:start(Name, #{
            transport_opts => [{port, Port}],
            proto_opts => #{protocols => [http1, http2]},
            routes => [{grpc, [Service], #{}}]
        }),
        Port
    end,
    PortA = Start(grpc_reload_a, arizona_roadrunner_grpc_reloaded),
    _PortB = Start(grpc_reload_b, arizona_roadrunner_grpc_reloaded_b),
    _PortC = Start(grpc_reload_c, arizona_roadrunner_grpc_reloaded),
    ok = logger:add_handler(grpc_reload_probe, ?MODULE, #{config => #{pid => self()}}),
    try
        Before = #{Name => tables(Name) || Name <- [grpc_reload_a, grpc_reload_b, grpc_reload_c]},
        %% A and C's service now names a function it does not export; B's gains
        %% a method.
        ok = load_service(Config, arizona_roadrunner_grpc_reloaded, [{say, gone}]),
        ok = load_service(Config, arizona_roadrunner_grpc_reloaded_b, [{say, say}, {extra, say}]),
        ?assertEqual(ok, arizona_roadrunner_server:recompile_routes()),
        ?assertEqual([grpc_reload_a, grpc_reload_c], lists:sort(logged_listeners([]))),
        ?assertEqual(maps:get(grpc_reload_a, Before), tables(grpc_reload_a)),
        ?assertEqual(maps:get(grpc_reload_c, Before), tables(grpc_reload_c)),
        {DispatchB, ListenerB} = maps:get(grpc_reload_b, Before),
        {DispatchB1, ListenerB1} = tables(grpc_reload_b),
        ?assertNotEqual(DispatchB, DispatchB1),
        ?assertNotEqual(ListenerB, ListenerB1),
        ?assertMatch({ok, ~"still", _}, unary(PortA, ~"/test.Reloaded/Say", ~"still")),
        ok = load_service(Config, arizona_roadrunner_grpc_reloaded, [{say, say}, {extra, say}]),
        ?assertEqual(ok, arizona_roadrunner_server:recompile_routes()),
        ?assertNotEqual(maps:get(grpc_reload_a, Before), tables(grpc_reload_a))
    after
        ok = logger:remove_handler(grpc_reload_probe),
        [
            ok = arizona_roadrunner_server:stop(N)
         || N <- [grpc_reload_a, grpc_reload_b, grpc_reload_c]
        ]
    end.

%% The listeners named in the errors logged so far.
logged_listeners(Acc) ->
    receive
        {logged, error, Message} ->
            {match, [Name]} = re:run(Message, ~"^listener (\\S+) keeps its routes", [
                {capture, all_but_first, binary}
            ]),
            logged_listeners([binary_to_atom(Name) | Acc])
    after 1000 -> Acc
    end.

%% A listener middleware's `init/1` runs only as roadrunner rebuilds the
%% listener's own table. When the reload breaks it, the adapter's dispatch
%% (what a live navigate resolves against) is not moved on alone: both keep
%% the routes they had, and move together once the edit is fixed.
a_broken_middleware_edit_keeps_both_tables(Config) when is_list(Config) ->
    ok = load_service(Config, arizona_roadrunner_grpc_reloaded, [{say, say}]),
    ok = load_middleware(Config, ~"ok"),
    {ok, _} = arizona_roadrunner_server:start(grpc_mw_reload, #{
        transport_opts => [{port, pick_port()}],
        proto_opts => #{
            protocols => [http1, http2], middlewares => [arizona_roadrunner_grpc_reloaded_mw]
        },
        routes => [{grpc, [arizona_roadrunner_grpc_reloaded], #{}}]
    }),
    try
        Before = tables(grpc_mw_reload),
        %% The service gains a method, and the middleware's `init/1` now raises.
        ok = load_service(Config, arizona_roadrunner_grpc_reloaded, [{say, say}, {extra, say}]),
        ok = load_middleware(Config, ~"error(broken)"),
        ?assertEqual(ok, arizona_roadrunner_server:recompile_routes()),
        ?assertEqual(Before, tables(grpc_mw_reload)),
        ok = load_middleware(Config, ~"ok"),
        ?assertEqual(ok, arizona_roadrunner_server:recompile_routes()),
        {DispatchBefore, ListenerBefore} = Before,
        {DispatchAfter, ListenerAfter} = tables(grpc_mw_reload),
        ?assertNotEqual(DispatchBefore, DispatchAfter),
        ?assertNotEqual(ListenerBefore, ListenerAfter)
    after
        ok = arizona_roadrunner_server:stop(grpc_mw_reload)
    end.

%% The adapter's dispatch (what a live navigate resolves against) and
%% roadrunner's own table of the listener `Name` (what a request hits).
tables(Name) ->
    {
        persistent_term:get({arizona_roadrunner_dispatch, Name}),
        persistent_term:get({roadrunner_routes, Name})
    }.

%% A logger handler forwarding each event's level and rendered message.
log(#{level := Level, msg := Msg}, #{config := #{pid := Pid}}) ->
    Text =
        case Msg of
            {string, String} -> String;
            {report, Report} -> io_lib:format("~0tp", [Report]);
            {Format, Args} -> io_lib:format(Format, Args)
        end,
    Pid ! {logged, Level, unicode:characters_to_binary(Text)},
    ok.

%% --------------------------------------------------------------------
%% Helpers
%% --------------------------------------------------------------------

%% (Re)load `Module`, a raw-codec service named after it with a method per
%% `{Method, Function}` pair; only `say/2` (an echo) is exported, so naming any
%% other function breaks the service.
load_service(Config, Module, Methods) ->
    Rpcs = lists:join(~", ", [
        io_lib:format(
            "<<\"~ts\">> => #{function => ~s, kind => unary, input => b, output => b}",
            [string:titlecase(atom_to_list(M)), F]
        )
     || {M, F} <- Methods
    ]),
    Name =
        case Module of
            arizona_roadrunner_grpc_reloaded -> "test.Reloaded";
            arizona_roadrunner_grpc_reloaded_b -> "test.ReloadedB"
        end,
    load(Config, Module, [
        "-export([name/0, rpcs/0, say/2]).\n",
        ["name() -> <<\"", Name, "\">>.\n"],
        ["rpcs() -> #{", Rpcs, "}.\n"],
        "say(Message, Stream) -> {reply, Message, Stream}.\n"
    ]).

%% (Re)load `arizona_roadrunner_grpc_reloaded_mw`, a pass-through listener
%% middleware whose `init/1` body is `InitBody`.
load_middleware(Config, InitBody) ->
    load(Config, arizona_roadrunner_grpc_reloaded_mw, [
        "-export([init/1, call/3]).\n",
        ["init(_Config) -> ", InitBody, ".\n"],
        "call(Req, Next, _State) -> Next(Req).\n"
    ]).

load(Config, Module, Body) ->
    File = filename:join(proplists:get_value(priv_dir, Config), atom_to_list(Module) ++ ".erl"),
    ok = file:write_file(File, [io_lib:format("-module(~s).~n", [Module]) | Body]),
    {ok, Module, Beam} = compile:file(File, [binary]),
    case code:purge(Module) of
        true -> ok;
        false -> ok
    end,
    {module, Module} = code:load_binary(Module, File, Beam),
    ok.

%% A plain-TCP listener serving HTTP/1.1 and prior-knowledge HTTP/2, with the
%% echo service before an Arizona controller.
with_listener(ProtoOpts, Fun) ->
    Port = pick_port(),
    {ok, _} = arizona_roadrunner_server:start(grpc_test, #{
        transport_opts => [{port, Port}],
        proto_opts => ProtoOpts#{protocols => [http1, http2]},
        routes => [
            {grpc, [arizona_roadrunner_grpc_echo], #{health => true}},
            {get, ~"/hello", arizona_roadrunner_smoke_controller, #{state => #{body => ~"hello"}}},
            {post, ~"/body", arizona_roadrunner_grpc_body, #{state => #{prefix => ~"got: "}}}
        ]
    }),
    try
        Fun(Port)
    after
        ok = arizona_roadrunner_server:stop(grpc_test)
    end.

%% A port the OS just handed out, so parallel runs do not collide.
pick_port() ->
    {ok, Listen} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    ok = gen_tcp:close(Listen),
    Port.

%% One HTTP/1.1 request on its own connection: the status and the body.
http1(Port, Method, Path, Body) ->
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Sock, [
        Method,
        ~" ",
        Path,
        ~" HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n",
        ~"content-length: ",
        integer_to_binary(byte_size(Body)),
        ~"\r\n\r\n",
        Body
    ]),
    Response = recv_all(Sock, <<>>),
    ok = gen_tcp:close(Sock),
    [Head, ResponseBody] = binary:split(Response, ~"\r\n\r\n"),
    <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Head,
    {binary_to_integer(Code), ResponseBody}.

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

%% A unary call on a connection of its own.
unary(Port, Path, Request) ->
    {ok, Conn} = roadrunner_grpc_client:connect(~"localhost", Port, #{}),
    try
        roadrunner_grpc_client:unary(Conn, Path, Request, #{timeout => 5000})
    after
        ok = roadrunner_grpc_client:close(Conn)
    end.

%% The message `erl_error` renders for what `Fun` raises.
format(Fun) ->
    try Fun() of
        Result -> error({no_error, Result})
    catch
        Class:Reason:Stacktrace ->
            unicode:characters_to_binary(erl_error:format_exception(Class, Reason, Stacktrace))
    end.
