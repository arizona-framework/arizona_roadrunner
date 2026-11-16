-module(arizona_roadrunner_grpc_body).
-moduledoc """
**TEST FIXTURE.** A controller answering with its route's `prefix` state and
the request body it read.
""".

-export([handle/2]).

-spec handle(Req, Ctx) -> {Reply, Req} when
    Req :: arizona_req:request(),
    Ctx :: arizona_controller:context(),
    Reply :: arizona_controller:reply().
handle(Req0, #{state := #{prefix := Prefix}}) ->
    {ok, Body, Req} = arizona_req:body(Req0),
    {{200, [{~"content-type", ~"text/plain"}], [Prefix, Body]}, Req}.
