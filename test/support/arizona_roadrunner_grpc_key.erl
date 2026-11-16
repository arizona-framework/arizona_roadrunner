-module(arizona_roadrunner_grpc_key).
-moduledoc """
**TEST FIXTURE.** A roadrunner middleware letting a gRPC call through only
with the `x-api-key` its config names, else rejecting it `UNAUTHENTICATED`.
""".
-behaviour(roadrunner_middleware).

-export([call/3]).

call(Req, Next, Key) ->
    case roadrunner_req:header(~"x-api-key", Req) of
        Key -> Next(Req);
        _ -> roadrunner_grpc:reject(unauthenticated, ~"bad api key", Req)
    end.
