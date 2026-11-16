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
        {_Headers, Messages, Trailers, _C} = arizona_roadrunner_grpc_client:call(
            arizona_roadrunner_grpc_client:open(Port), 1, ~"/test.Echo/Say", [~"hi"]
        ),
        ?assertEqual([~"echo: hi"], Messages),
        ?assertEqual({~"grpc-status", ~"0"}, lists:keyfind(~"grpc-status", 1, Trailers)),
        ?assertMatch({200, ~"hello"}, http1(Port, ~"GET", ~"/hello", <<>>))
    end).

%% `health => true` reaches roadrunner: its health service answers SERVING.
passes_its_options_to_roadrunner(Config) when is_list(Config) ->
    with_listener(#{}, fun(Port) ->
        {_Headers, Messages, _Trailers, _C} = arizona_roadrunner_grpc_client:call(
            arizona_roadrunner_grpc_client:open(Port), 1, ~"/grpc.health.v1.Health/Check", [<<>>]
        ),
        %% HealthCheckResponse{status = SERVING}: field 1, varint 1.
        ?assertEqual([<<8, 1>>], Messages)
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
        {_Headers, Messages, _Trailers, _C} = arizona_roadrunner_grpc_client:call(
            arizona_roadrunner_grpc_client:open(Port), 1, ~"/test.Echo/Say", [~"again"]
        ),
        ?assertEqual([~"echo: again"], Messages)
    end).

%% Under `body_buffering => manual` a bidirectional call answers each request
%% as it arrives, and an Arizona controller on the same listener still reads
%% its whole body.
streams_beside_a_manual_body_read(Config) when is_list(Config) ->
    with_listener(#{body_buffering => manual}, fun(Port) ->
        C0 = arizona_roadrunner_grpc_client:start(
            arizona_roadrunner_grpc_client:open(Port), 1, ~"/test.Echo/Chat", []
        ),
        C1 = arizona_roadrunner_grpc_client:send(
            C0, 1, iolist_to_binary(roadrunner_grpc_frame:encode(false, ~"one"))
        ),
        %% Answered before the client ends its requests: the call streams.
        {Data, C3} = first_data(C1, 1),
        ?assertEqual([~"one"], arizona_roadrunner_grpc_client:messages(Data)),
        C4 = arizona_roadrunner_grpc_client:finish(C3, 1),
        {_Trailers, _C5} = arizona_roadrunner_grpc_client:trailers(C4, 1),
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

%% A dev hot reload runs the service's code again (roadrunner's `init_route`).
%% An edit that breaks it fails that listener's rebuild only: it keeps the
%% table it had and serves on, the failure is logged, and the reload goes on,
%% so the browser is still told. Fixing the edit rebuilds it on the next one.
a_broken_service_edit_keeps_the_listener_reloadable(Config) when is_list(Config) ->
    ok = load_service(Config, [{say, say}]),
    ok = logger:add_handler(grpc_reload_probe, ?MODULE, #{config => #{pid => self()}}),
    Port = pick_port(),
    {ok, _} = arizona_roadrunner_server:start(grpc_reload, #{
        transport_opts => [{port, Port}],
        proto_opts => #{protocols => [http1, http2]},
        routes => [{grpc, [arizona_roadrunner_grpc_reloaded], #{}}]
    }),
    try
        %% Its `rpcs/0` now names a function the module does not export.
        ok = load_service(Config, [{say, gone}]),
        ?assertEqual(ok, arizona_roadrunner_server:recompile_routes()),
        receive
            {logged, error, Message} ->
                ?assertNotEqual(nomatch, binary:match(Message, ~"grpc_reload"))
        after 5000 -> error(no_error_logged)
        end,
        {_Headers, Messages, _Trailers, _C} = arizona_roadrunner_grpc_client:call(
            arizona_roadrunner_grpc_client:open(Port), 1, ~"/test.Reloaded/Say", [~"still"]
        ),
        ?assertEqual([~"still"], Messages),
        ok = load_service(Config, [{say, say}]),
        ?assertEqual(ok, arizona_roadrunner_server:recompile_routes())
    after
        ok = arizona_roadrunner_server:stop(grpc_reload),
        ok = logger:remove_handler(grpc_reload_probe)
    end.

%% A listener middleware's `init/1` runs only as roadrunner rebuilds the
%% listener's own table. When the reload breaks it, the adapter's dispatch
%% (what a live navigate resolves against) is not moved on alone: both keep
%% the routes they had, and move together once the edit is fixed.
a_broken_middleware_edit_keeps_both_tables(Config) when is_list(Config) ->
    ok = load_service(Config, [{say, say}]),
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
        ok = load_service(Config, [{say, say}, {extra, say}]),
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

%% (Re)load `arizona_roadrunner_grpc_reloaded`, a raw-codec service with a
%% method per `{Method, Function}` pair; only `say/2` (an echo) is exported, so
%% naming any other function breaks the service.
load_service(Config, Methods) ->
    Rpcs = lists:join(~", ", [
        io_lib:format(
            "<<\"~ts\">> => #{function => ~s, kind => unary, input => b, output => b}",
            [string:titlecase(atom_to_list(M)), F]
        )
     || {M, F} <- Methods
    ]),
    load(Config, arizona_roadrunner_grpc_reloaded, [
        "-export([name/0, rpcs/0, say/2]).\n",
        "name() -> <<\"test.Reloaded\">>.\n",
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

%% The first DATA frame the server sends on `StreamId`, skipping the frames
%% before it (settings, window updates, the response headers).
first_data(C0, StreamId) ->
    case arizona_roadrunner_grpc_client:next_frame(C0) of
        {{data, StreamId, _Flags, Data, _FlowLen}, C} -> {Data, C};
        {_Other, C} -> first_data(C, StreamId)
    end.

%% The message `erl_error` renders for what `Fun` raises.
format(Fun) ->
    try Fun() of
        Result -> error({no_error, Result})
    catch
        Class:Reason:Stacktrace ->
            unicode:characters_to_binary(erl_error:format_exception(Class, Reason, Stacktrace))
    end.
