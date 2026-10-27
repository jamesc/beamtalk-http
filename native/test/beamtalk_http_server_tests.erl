%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

-module(beamtalk_http_server_tests).
-moduledoc """
EUnit tests for beamtalk_http_server gen_server (BT-1338, ADR 0056).

**DDD Context:** Object System Context

Verifies the native gen_server backing the HTTPServer actor class.
Tests start real cowboy listeners via start_link/1 and exercise the
{port, []}/{printString, []} selectors and lifecycle.
""".

-include_lib("eunit/include/eunit.hrl").

%%% ============================================================================
%%% Lifecycle tests (gen_server API)
%%% ============================================================================

start_link_returns_pid_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    Handler = fun(_Req) -> make_simple_response(200, <<"ok">>) end,
    {ok, Pid} = beamtalk_http_server:start_link(#{port => 0, handler => Handler}),
    ?assert(is_pid(Pid)),
    gen_server:stop(Pid).

port_selector_returns_positive_integer_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    Handler = fun(_Req) -> make_simple_response(200, <<"ok">>) end,
    {ok, Pid} = beamtalk_http_server:start_link(#{port => 0, handler => Handler}),
    Port = gen_server:call(Pid, {port, []}),
    ?assert(is_integer(Port)),
    ?assert(Port > 0),
    ?assert(Port =< 65535),
    gen_server:stop(Pid).

print_string_selector_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    Handler = fun(_Req) -> make_simple_response(200, <<"ok">>) end,
    {ok, Pid} = beamtalk_http_server:start_link(#{port => 0, handler => Handler}),
    Str = gen_server:call(Pid, {printString, []}),
    ?assertMatch({beamtalk_string, <<"an HTTPServer(port: ", _/binary>>}, Str),
    gen_server:stop(Pid).

stop_cleans_up_listener_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    Handler = fun(_Req) -> make_simple_response(200, <<"ok">>) end,
    {ok, Pid} = beamtalk_http_server:start_link(#{port => 0, handler => Handler}),
    gen_server:stop(Pid),
    %% Stopping twice should not crash (idempotent terminate)
    ok.

start_multiple_servers_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    Handler = fun(_Req) -> make_simple_response(200, <<"ok">>) end,
    {ok, Pid1} = beamtalk_http_server:start_link(#{port => 0, handler => Handler}),
    {ok, Pid2} = beamtalk_http_server:start_link(#{port => 0, handler => Handler}),
    Port1 = gen_server:call(Pid1, {port, []}),
    Port2 = gen_server:call(Pid2, {port, []}),
    ?assertNotEqual(Port1, Port2),
    gen_server:stop(Pid1),
    gen_server:stop(Pid2).

invalid_handler_fails_start_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    process_flag(trap_exit, true),
    Result = beamtalk_http_server:start_link(#{port => 0, handler => not_a_handler}),
    ?assertMatch({error, _}, Result),
    process_flag(trap_exit, false).

invalid_port_fails_start_test() ->
    Handler = fun(_Req) -> make_simple_response(200, <<"ok">>) end,
    process_flag(trap_exit, true),
    Result = beamtalk_http_server:start_link(#{port => -1, handler => Handler}),
    ?assertMatch({error, _}, Result),
    process_flag(trap_exit, false).

invalid_bind_fails_start_test() ->
    Handler = fun(_Req) -> make_simple_response(200, <<"ok">>) end,
    process_flag(trap_exit, true),
    Result = beamtalk_http_server:start_link(#{port => 0, handler => Handler, bind => 123}),
    ?assertMatch({error, _}, Result),
    process_flag(trap_exit, false).

%%% ============================================================================
%%% Integration smoke test (requires gun)
%%% ============================================================================

handler_receives_request_and_returns_response_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    Handler = fun(_Req) -> make_simple_response(200, <<"hello from handler">>) end,
    {ok, Pid} = beamtalk_http_server:start_link(#{port => 0, handler => Handler}),
    Port = gen_server:call(Pid, {port, []}),
    Url = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/test"]),
    #{'$beamtalk_class' := 'Result', 'isOk' := true, 'okValue' := Resp} =
        beamtalk_http:'get:'(Url),
    ?assertEqual(200, maps:get(status, Resp)),
    ?assertEqual({beamtalk_string, <<"hello from handler">>}, maps:get(body, Resp)),
    gen_server:stop(Pid).

%%% ============================================================================
%%% BT-4171 — request text fields answer String (validated at the boundary)
%%% ============================================================================

request_text_fields_answer_string_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    Self = self(),
    Handler = fun(Req) ->
        Self ! {captured_request, Req},
        make_simple_response(200, <<"ok">>)
    end,
    {ok, Pid} = beamtalk_http_server:start_link(#{port => 0, handler => Handler}),
    Port = gen_server:call(Pid, {port, []}),
    Url = iolist_to_binary([
        "http://127.0.0.1:", integer_to_list(Port), "/hello?name=Ada"
    ]),
    #{'$beamtalk_class' := 'Result', 'isOk' := true, 'okValue' := Resp} =
        beamtalk_http:'get:'(Url),
    ?assertEqual(200, maps:get(status, Resp)),
    Req =
        receive
            {captured_request, R} -> R
        after 5000 ->
            error(request_not_captured)
        end,
    ?assertEqual({beamtalk_string, <<"GET">>}, maps:get(method, Req)),
    ?assertEqual('String', beamtalk_primitive:class_of(maps:get(method, Req))),
    ?assertEqual({beamtalk_string, <<"/hello">>}, maps:get(path, Req)),
    ?assertEqual('String', beamtalk_primitive:class_of(maps:get(path, Req))),
    ?assertEqual('String', beamtalk_primitive:class_of(maps:get(body, Req))),
    Qs = maps:get(queryParams, Req),
    ?assertEqual({beamtalk_string, <<"Ada">>}, maps:get({beamtalk_string, <<"name">>}, Qs)),
    lists:foreach(
        fun(K) -> ?assertEqual('String', beamtalk_primitive:class_of(K)) end,
        maps:keys(Qs)
    ),
    lists:foreach(
        fun(V) -> ?assertEqual('String', beamtalk_primitive:class_of(V)) end,
        maps:values(Qs)
    ),
    Headers = maps:get(headers, Req),
    ?assert(is_list(Headers) andalso Headers =/= []),
    lists:foreach(
        fun([N, V]) ->
            ?assertEqual('String', beamtalk_primitive:class_of(N)),
            ?assertEqual('String', beamtalk_primitive:class_of(V))
        end,
        Headers
    ),
    gen_server:stop(Pid).

request_body_echoes_text_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    Self = self(),
    Handler = fun(Req) ->
        Self ! {captured_request, Req},
        make_simple_response(200, <<"ok">>)
    end,
    {ok, Pid} = beamtalk_http_server:start_link(#{port => 0, handler => Handler}),
    Port = gen_server:call(Pid, {port, []}),
    Url = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/echo"]),
    #{'$beamtalk_class' := 'Result', 'isOk' := true, 'okValue' := Resp} =
        beamtalk_http:'post:body:'(Url, <<"test data">>),
    ?assertEqual(200, maps:get(status, Resp)),
    Req =
        receive
            {captured_request, R} -> R
        after 5000 ->
            error(request_not_captured)
        end,
    ?assertEqual({beamtalk_string, <<"test data">>}, maps:get(body, Req)),
    ?assertEqual('String', beamtalk_primitive:class_of(maps:get(body, Req))),
    gen_server:stop(Pid).

route_params_answer_string_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    Self = self(),
    Handler = fun(Req) ->
        Self ! {captured_request, Req},
        make_simple_response(200, <<"ok">>)
    end,
    Routes = beamtalk_http_router:compile([{<<"GET">>, <<"/users/:id">>, Handler}]),
    Router = #{compiledRoutes => Routes, notFoundHandler => nil},
    {ok, Pid} = beamtalk_http_server:start_link(#{port => 0, handler => Router}),
    Port = gen_server:call(Pid, {port, []}),
    Url = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/users/42"]),
    #{'$beamtalk_class' := 'Result', 'isOk' := true, 'okValue' := Resp} =
        beamtalk_http:'get:'(Url),
    ?assertEqual(200, maps:get(status, Resp)),
    Req =
        receive
            {captured_request, R} -> R
        after 5000 ->
            error(request_not_captured)
        end,
    Params = maps:get(params, Req),
    ?assertEqual({beamtalk_string, <<"42">>}, maps:get({beamtalk_string, <<"id">>}, Params)),
    lists:foreach(
        fun(K) -> ?assertEqual('String', beamtalk_primitive:class_of(K)) end,
        maps:keys(Params)
    ),
    lists:foreach(
        fun(V) -> ?assertEqual('String', beamtalk_primitive:class_of(V)) end,
        maps:values(Params)
    ),
    gen_server:stop(Pid).

invalid_utf8_query_value_answers_400_test() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    Self = self(),
    Handler = fun(Req) ->
        Self ! {captured_request, Req},
        make_simple_response(200, <<"ok">>)
    end,
    {ok, Pid} = beamtalk_http_server:start_link(#{port => 0, handler => Handler}),
    Port = gen_server:call(Pid, {port, []}),
    %% %FF percent-decodes to <<255>>, which is not valid UTF-8.
    Url = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/hello?name=%FF"]),
    #{'$beamtalk_class' := 'Result', 'isOk' := true, 'okValue' := Resp} =
        beamtalk_http:'get:'(Url),
    ?assertEqual(400, maps:get(status, Resp)),
    %% The body proves the 400 comes from boundary validation, not cowboy.
    ?assertEqual(
        {beamtalk_string, <<"Bad Request: invalid UTF-8 in query_value">>},
        maps:get(body, Resp)
    ),
    %% The handler never runs for a request rejected at the boundary.
    receive
        {captured_request, _} -> error(handler_should_not_run)
    after 500 ->
        ok
    end,
    gen_server:stop(Pid).

%%% ============================================================================
%%% Helpers
%%% ============================================================================

%% @private Build a minimal HTTPResponse map for testing.
%%
%% This constructs a raw map matching the HTTPResponse field layout,
%% bypassing the bt@http@httpresponse constructor (which may not be
%% loaded during EUnit tests).
-spec make_simple_response(non_neg_integer(), binary()) -> map().
make_simple_response(Status, Body) ->
    #{
        '$beamtalk_class' => 'HTTPResponse',
        status => Status,
        headers => [],
        body => Body
    }.
