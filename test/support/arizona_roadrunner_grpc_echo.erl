-module(arizona_roadrunner_grpc_echo).
-moduledoc """
**TEST FIXTURE.** A raw-codec gRPC service: `Say` answers its request with
`echo: ` before it, and `Chat` answers each request as it arrives.
""".
-behaviour(roadrunner_grpc_service).

-export([name/0]).
-export([rpcs/0]).
-export([say/2]).
-export([chat/1]).

name() ->
    ~"test.Echo".

rpcs() ->
    #{
        ~"Say" => #{function => say, kind => unary, input => bytes, output => bytes},
        ~"Chat" => #{function => chat, kind => bidi_stream, input => bytes, output => bytes}
    }.

say(Message, Stream) ->
    {reply, [~"echo: ", Message], Stream}.

chat(Stream0) ->
    case roadrunner_grpc:recv(Stream0) of
        {ok, Message, Stream} -> chat(roadrunner_grpc:send(Message, Stream));
        {eof, Stream} -> {ok, Stream}
    end.
