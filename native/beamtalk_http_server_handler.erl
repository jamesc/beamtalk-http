%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

-module(beamtalk_http_server_handler).
-moduledoc """
Cowboy handler that bridges HTTP requests to Beamtalk handlers (BT-1338).

**DDD Context:** Object System Context

Each incoming HTTP request is converted to an `HTTPRequest` value object
and passed to the user-supplied handler. The handler may be:

- A block (Erlang `fun/1`) receiving an `HTTPRequest`
- An actor pid responding to `handle:` with an `HTTPRequest`

The handler must return an `HTTPResponse` value object. The response's
`status`, `headers`, and `body` fields are extracted and sent back to
the client via cowboy.
""".

-behaviour(cowboy_handler).

-export([init/2]).

-include_lib("kernel/include/logger.hrl").
-include("beamtalk_classes.hrl").

-doc """
Handle a cowboy HTTP request by delegating to the Beamtalk handler.

State is `#{handler := Handler}` where Handler is a fun/1, actor pid,
or an HTTPRouter Value object (map with `compiledRoutes` key, BT-1344).
""".
-spec init(cowboy_req:req(), map()) -> {ok, cowboy_req:req(), map()}.
init(Req0, #{handler := Handler} = State) ->
    case build_request(Req0) of
        {ok, HttpRequest, Req1} ->
            dispatch_and_reply(Handler, HttpRequest, Req1, State);
        {error, Field, Req1} ->
            %% BT-4171: non-UTF-8 bytes at a text boundary — the handler
            %% never runs; answer 400 (the field name leaks no values).
            Req = cowboy_req:reply(
                400,
                #{<<"content-type">> => <<"text/plain">>},
                iolist_to_binary([
                    <<"Bad Request: invalid UTF-8 in ">>, atom_to_binary(Field, utf8)
                ]),
                Req1
            ),
            {ok, Req, State}
    end.

%% @private Dispatch a validated request to the handler and reply.
-spec dispatch_and_reply(term(), map(), cowboy_req:req(), map()) ->
    {ok, cowboy_req:req(), map()}.
dispatch_and_reply(Handler, HttpRequest, Req1, State) ->
    try dispatch_handler(Handler, HttpRequest) of
        Response when is_map(Response) ->
            Status = get_response_field(Response, status, 200),
            Headers = get_response_headers(Response),
            %% BT-4173: the handler's String body arrives tagged —
            %% cowboy needs bytes (a Binary body passes through).
            Body = beamtalk_http_text:unwrap_string(get_response_field(Response, body, <<>>)),
            Req = cowboy_req:reply(Status, Headers, Body, Req1),
            {ok, Req, State};
        Other ->
            ?LOG_ERROR("HTTP handler returned non-HTTPResponse", #{
                value => Other,
                domain => [beamtalk, stdlib]
            }),
            Req = cowboy_req:reply(
                500,
                #{<<"content-type">> => <<"text/plain">>},
                <<"Internal Server Error">>,
                Req1
            ),
            {ok, Req, State}
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR("HTTP handler crashed", #{
                class => Class,
                reason => Reason,
                stacktrace => Stack,
                domain => [beamtalk, stdlib]
            }),
            Req = cowboy_req:reply(
                500,
                #{<<"content-type">> => <<"text/plain">>},
                <<"Internal Server Error">>,
                Req1
            ),
            {ok, Req, State}
    end.

%%% ============================================================================
%%% Internal
%%% ============================================================================

%% @private Build an HTTPRequest value object from a cowboy request.
%%
%% Returns `{ok, HTTPRequest, UpdatedReq}` — the updated Req must be used
%% for the reply, since `read_body` consumes the body stream from the
%% socket. Answers `{error, Field, UpdatedReq}` when a text field holds
%% non-UTF-8 bytes (see `validate_text_fields/4`).
-dialyzer({nowarn_function, build_request/1}).
-spec build_request(cowboy_req:req()) ->
    {ok, map(), cowboy_req:req()} | {error, atom(), cowboy_req:req()}.
build_request(Req0) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path(Req0),
    HeadersList = maps:to_list(cowboy_req:headers(Req0)),
    Headers = [[Name, Value] || {Name, Value} <- HeadersList],
    {Body, Req1} = read_body(Req0),
    QsMap = parse_query_params(Req1),
    case validate_text_fields(Method, Path, Headers, QsMap) of
        ok ->
            %% BT-4173: validated text answers Strings; the body is
            %% only text when its bytes are valid UTF-8 (uploads stay
            %% Binary). Route params are tagged by the router on match.
            HttpRequest = ?BT_CLASS_MODULE_HTTPRequest:'class_method:path:headers:body:queryParams:params:'(
                undefined,
                tag_validated(Method),
                tag_validated(Path),
                [[tag_validated(N), tag_validated(V)] || [N, V] <- Headers],
                beamtalk_http_text:maybe_tag(Body),
                maps:from_list([
                    {tag_validated(K), tag_validated(V)}
                 || {K, V} <- maps:to_list(QsMap)
                ]),
                #{}
            ),
            {ok, HttpRequest, Req1};
        {error, Field} ->
            {error, Field, Req1}
    end.

%% @private Tag validated-UTF-8 bytes as a String (BT-4173).
%%
%% Call ONLY with bytes that passed `validate_text_fields/4` — tagging
%% is trusted and does not re-check.
-spec tag_validated(binary()) -> beamtalk_string:t().
tag_validated(Bin) when is_binary(Bin) ->
    beamtalk_primitive:string_from_binary(Bin).

%% @private Validate the request's text fields as UTF-8 (BT-4171).
%%
%% This is HTTP's native text boundary: method, path, header names/values,
%% and query keys/values are declared `String` on `HTTPRequest`, so they
%% are validated with `beamtalk_primitive:is_utf8/1` (the same check as
%% `beamtalk_binary:check_utf8/1`, already released — reused here rather
%% than duplicating validation logic). A request with non-text there is
%% rejected with 400 instead of flowing through as Binary.
%%
%% The body is intentionally NOT validated: unlike the other fields it
%% legitimately carries bytes (file uploads and other non-text payloads).
%% `build_request/1` tags it as `String` only when its bytes are valid
%% UTF-8 — otherwise it stays `Binary`. Route params need no check
%% either: they are `/`-separated substrings of the validated path, so
%% they are valid UTF-8 iff the path is.
-spec validate_text_fields(binary(), binary(), [[binary()]], map()) ->
    ok | {error, atom()}.
validate_text_fields(Method, Path, Headers, QsMap) ->
    Checks =
        [{method, Method}, {path, Path}] ++
            header_checks(Headers) ++
            qs_checks(QsMap),
    first_invalid(Checks).

%% @private One check per header name and value.
-spec header_checks([[binary()]]) -> [{atom(), binary()}].
header_checks(Headers) ->
    lists:flatmap(
        fun([Name, Value]) -> [{header_name, Name}, {header_value, Value}] end,
        Headers
    ).

%% @private One check per query key and value.
-spec qs_checks(map()) -> [{atom(), term()}].
qs_checks(QsMap) ->
    lists:flatmap(
        fun({K, V}) -> [{query_key, K} | qs_value_check(V)] end,
        maps:to_list(QsMap)
    ).

%% @private Query values are binaries (`value_or_true/1` maps valueless
%% flags to `<<"true">>`); anything else skips validation.
-spec qs_value_check(term()) -> [{atom(), term()}].
qs_value_check(V) when is_binary(V) -> [{query_value, V}];
qs_value_check(_) -> [].

%% @private First check whose binary is not valid UTF-8, or `ok`.
-spec first_invalid([{atom(), term()}]) -> ok | {error, atom()}.
first_invalid([]) ->
    ok;
first_invalid([{Field, Bin} | Rest]) when is_binary(Bin) ->
    case beamtalk_primitive:is_utf8(Bin) of
        true -> first_invalid(Rest);
        false -> {error, Field}
    end;
first_invalid([_ | Rest]) ->
    first_invalid(Rest).

%% @private Read the full request body (may be chunked).
%%
%% Returns `{Body, UpdatedReq}` so the caller can use the updated Req
%% for subsequent cowboy operations (e.g. reply).
-spec read_body(cowboy_req:req()) -> {binary(), cowboy_req:req()}.
read_body(Req) ->
    read_body(Req, <<>>).

-spec read_body(cowboy_req:req(), binary()) -> {binary(), cowboy_req:req()}.
read_body(Req0, Acc) ->
    case cowboy_req:read_body(Req0) of
        {ok, Data, Req} ->
            {<<Acc/binary, Data/binary>>, Req};
        {more, Data, Req} ->
            read_body(Req, <<Acc/binary, Data/binary>>)
    end.

%% @private Parse query string into a Beamtalk Dictionary (Erlang map).
-spec parse_query_params(cowboy_req:req()) -> map().
parse_query_params(Req) ->
    QsList = cowboy_req:parse_qs(Req),
    maps:from_list([{Key, value_or_true(Val)} || {Key, Val} <- QsList]).

%% @private Query params without a value (e.g. "?flag") get `true`.
-spec value_or_true(binary() | true) -> binary() | true.
value_or_true(true) -> <<"true">>;
value_or_true(Val) -> Val.

%% @private Dispatch the request to the appropriate handler.
%%
%% Supports three handler types:
%%   - HTTPRouter Value object (map with `compiledRoutes` key) — compiled router (BT-1344)
%%   - `fun/1` — block handler
%%   - `pid()` — actor responding to `handle:`
-spec dispatch_handler(term(), map()) -> beamtalk_http_response:t().
dispatch_handler(#{compiledRoutes := Routes, notFoundHandler := NotFoundHandler}, Request) ->
    dispatch_router(Routes, NotFoundHandler, Request);
dispatch_handler(Handler, Request) ->
    call_handler(Handler, Request).

%% @private Route dispatch: match method+path, inject params, call handler.
%%
%% BT-4171: params need no validation — Method/Path were validated in
%% build_request/1 and route params are substrings of Path.
-spec dispatch_router(list(), term(), map()) -> beamtalk_http_response:t().
dispatch_router(Routes, NotFoundHandler, Request) ->
    Method = maps:get(method, Request),
    Path = maps:get(path, Request),
    case beamtalk_http_router:match(Routes, Method, Path) of
        {ok, Handler, Params} ->
            EnrichedRequest = Request#{params => Params},
            call_handler(Handler, EnrichedRequest);
        method_not_allowed ->
            make_error_response(405, <<"Method Not Allowed">>);
        not_found when NotFoundHandler =:= nil; NotFoundHandler =:= undefined ->
            make_error_response(404, <<"Not Found">>);
        not_found ->
            call_handler(NotFoundHandler, Request)
    end.

%% @private Call the handler with the request.
%%
%% Supports blocks (funs) and actor pids responding to `handle:`.
-spec call_handler(fun((map()) -> beamtalk_http_response:t()) | pid(), map()) ->
    beamtalk_http_response:t().
call_handler(Handler, Request) when is_function(Handler, 1) ->
    Handler(Request);
call_handler(Handler, Request) when is_pid(Handler) ->
    beamtalk_actor:sync_send(Handler, 'handle:', [Request]).

%% @private Build an HTTPResponse value for error responses.
-dialyzer({nowarn_function, make_error_response/2}).
-spec make_error_response(integer(), binary()) -> beamtalk_http_response:t().
make_error_response(Status, Body) ->
    ?BT_CLASS_MODULE_HTTPResponse:'class_status:headers:body:'(
        undefined, Status, [[<<"content-type">>, <<"text/plain">>]], Body
    ).

%% @private Extract a field from an HTTPResponse value object.
%%
%% HTTPResponse objects store fields in their map under the field name atom.
%% The generated accessor methods use these keys.
-spec get_response_field(beamtalk_http_response:t(), atom(), term()) -> term().
get_response_field(Response, Field, Default) ->
    maps:get(Field, Response, Default).

%% @private Convert HTTPResponse headers to cowboy headers map.
%%
%% HTTPResponse headers are `[[Name, Value], ...]`.
%% Cowboy expects `#{Name => Value, ...}`.
-spec get_response_headers(beamtalk_http_response:t()) -> map().
get_response_headers(Response) ->
    case maps:get(headers, Response, []) of
        Headers when is_list(Headers) ->
            %% BT-4173: names/values arrive tagged — cowboy needs bytes.
            maps:from_list([
                {beamtalk_http_text:unwrap_string(Name), beamtalk_http_text:unwrap_string(Value)}
             || [Name, Value] <- Headers
            ]);
        _ ->
            #{}
    end.
