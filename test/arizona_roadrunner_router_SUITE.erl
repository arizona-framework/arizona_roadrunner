-module(arizona_roadrunner_router_SUITE).
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    compile_routes_asset_dir/1,
    compile_routes_asset_priv_dir/1,
    compile_routes_controller/1,
    compile_routes_live/1,
    compile_routes_live_no_layout/1,
    compile_routes_live_multiple_pages/1,
    compile_routes_mixed/1,
    compile_routes_ws/1
]).

all() ->
    [
        compile_routes_live,
        compile_routes_live_no_layout,
        compile_routes_live_multiple_pages,
        compile_routes_ws,
        compile_routes_asset_dir,
        compile_routes_asset_priv_dir,
        compile_routes_controller,
        compile_routes_mixed
    ].

%% --------------------------------------------------------------------
%% Helpers
%% --------------------------------------------------------------------

compile(Routes) ->
    ok = arizona_roadrunner_router:compile_routes(Routes).

%% Resolve a request path to `{Handler, Opts}` via
%% `roadrunner_router:match/2` against the persistent term key
%% arizona_roadrunner_router writes. Arizona's per-route opts live under
%% the `arizona` namespace inside `state` to keep them opaque from
%% roadrunner's pipeline. Unwrap so the assertions can read
%% handler/layouts/etc. directly. asset/controller routes have no
%% arizona wrap and expose their opts at the top level.
route_match(Path) ->
    Compiled = persistent_term:get(arizona_roadrunner_dispatch),
    {ok, Handler, _Bindings, _Pipeline, State} =
        roadrunner_router:match(Path, Compiled),
    case State of
        #{arizona := ArzOpts} -> {Handler, ArzOpts};
        _ -> {Handler, State}
    end.

%% --------------------------------------------------------------------
%% Tests
%% --------------------------------------------------------------------

compile_routes_live(Config) when is_list(Config) ->
    compile([
        {live, <<"/foo">>, my_handler, #{
            bindings => #{page => home},
            layouts => [{my_layout, render}]
        }}
    ]),
    {Handler, Opts} = route_match(<<"/foo">>),
    ?assertEqual(arizona_roadrunner_http, Handler),
    ?assertEqual(my_handler, maps:get(handler, Opts)),
    ?assertEqual([{my_layout, render}], maps:get(layouts, Opts)),
    ?assertEqual(#{page => home}, maps:get(bindings, Opts)).

compile_routes_live_no_layout(Config) when is_list(Config) ->
    compile([
        {live, <<"/bare">>, my_handler, #{bindings => #{x => 1}}}
    ]),
    {Handler, Opts} = route_match(<<"/bare">>),
    ?assertEqual(arizona_roadrunner_http, Handler),
    ?assertEqual(my_handler, maps:get(handler, Opts)),
    ?assertEqual([], maps:get(layouts, Opts)),
    ?assertEqual(#{x => 1}, maps:get(bindings, Opts)).

compile_routes_live_multiple_pages(Config) when is_list(Config) ->
    RouteOpts = fun(Id) ->
        #{bindings => #{id => Id}, layouts => [{layout, render}]}
    end,
    compile([
        {live, <<"/page1">>, handler1, RouteOpts(<<"p1">>)},
        {live, <<"/page2">>, handler2, RouteOpts(<<"p2">>)}
    ]),
    {H1, Opts1} = route_match(<<"/page1">>),
    {H2, Opts2} = route_match(<<"/page2">>),
    ?assertEqual(arizona_roadrunner_http, H1),
    ?assertEqual(arizona_roadrunner_http, H2),
    ?assertEqual(handler1, maps:get(handler, Opts1)),
    ?assertEqual(handler2, maps:get(handler, Opts2)),
    ?assertEqual(#{id => <<"p1">>}, maps:get(bindings, Opts1)),
    ?assertEqual(#{id => <<"p2">>}, maps:get(bindings, Opts2)).

compile_routes_ws(Config) when is_list(Config) ->
    compile([
        {ws, <<"/ws">>, #{idle_timeout => 60000}}
    ]),
    {Handler, Opts} = route_match(<<"/ws">>),
    ?assertEqual(arizona_roadrunner_ws, Handler),
    ?assertEqual(#{idle_timeout => 60000}, Opts).

compile_routes_asset_dir(Config) when is_list(Config) ->
    compile([
        {asset, <<"/static">>, {dir, "/tmp/assets"}}
    ]),
    {Handler, Opts} = route_match(<<"/static/foo.js">>),
    ?assertEqual(arizona_roadrunner_static, Handler),
    ?assertEqual(#{dir => "/tmp/assets"}, Opts).

compile_routes_asset_priv_dir(Config) when is_list(Config) ->
    compile([
        {asset, <<"/priv">>, {priv_dir, arizona, "static/assets/js"}}
    ]),
    {Handler, Opts} = route_match(<<"/priv/arizona.min.js">>),
    ExpectedDir = filename:join(code:priv_dir(arizona), "static/assets/js"),
    ?assertEqual(arizona_roadrunner_static, Handler),
    ?assertEqual(#{dir => ExpectedDir}, Opts).

compile_routes_controller(Config) when is_list(Config) ->
    compile([
        {controller, <<"/api/health">>, my_controller, #{key => val}}
    ]),
    {Handler, Opts} = route_match(<<"/api/health">>),
    ?assertEqual(my_controller, Handler),
    ?assertEqual(#{key => val}, Opts).

compile_routes_mixed(Config) when is_list(Config) ->
    compile([
        {live, <<"/">>, page_h, #{layouts => [{lay, render}]}},
        {ws, <<"/ws">>, #{timeout => 30}},
        {asset, <<"/assets">>, {dir, "/var/www"}},
        {controller, <<"/health">>, health_h, #{status => ok}}
    ]),
    {H1, _} = route_match(<<"/">>),
    ?assertEqual(arizona_roadrunner_http, H1),
    {H2, Opts2} = route_match(<<"/ws">>),
    ?assertEqual(arizona_roadrunner_ws, H2),
    ?assertEqual(#{timeout => 30}, Opts2),
    {H3, Opts3} = route_match(<<"/assets/style.css">>),
    ?assertEqual(arizona_roadrunner_static, H3),
    ?assertEqual(#{dir => "/var/www"}, Opts3),
    {H4, Opts4} = route_match(<<"/health">>),
    ?assertEqual(health_h, H4),
    ?assertEqual(#{status => ok}, Opts4).
