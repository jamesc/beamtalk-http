%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

-module(beamtalk_http_router).
-moduledoc """
HTTP route compilation and matching for HTTPRouter (BT-1344).

**DDD Context:** Object System Context

Compiles path patterns (e.g. `/users/:id`) into segment lists and
matches incoming method+path pairs against compiled routes.

Route compilation parses path patterns into segments:
  - `literal`  — exact string match (e.g. `<<"users">>`)
  - `{param, Name}` — named parameter capture (e.g. `:id`)
  - `{wildcard, Name}` — catch-all suffix (e.g. `*path`)

Matching returns the handler and extracted parameters, or a status
indicating no match or wrong method.
""".

-export([compile/1, match/3]).

-include_lib("beamtalk_runtime/include/beamtalk.hrl").

%%% ============================================================================
%%% Types
%%% ============================================================================

-type segment() :: binary() | {param, binary()} | {wildcard, binary()}.
-type compiled_route() :: {binary(), [segment()], fun()}.
-type compiled_routes() :: [compiled_route()].
-type path_param() :: binary() | beamtalk_string:t().

-export_type([compiled_routes/0]).

%%% ============================================================================
%%% Public API
%%% ============================================================================

-doc """
Compile a list of route specs into a compiled route table.

Each route is `{Method, Path, Handler}` or `[Method, Path, Handler]` where:
  - `Method` — HTTP method as a binary (e.g. `<<"GET">>`)
  - `Path` — path pattern as a binary (e.g. `<<"/users/:id">>`)
  - `Handler` — a fun/1 (block) to call with the enriched request

BT-4173: Method/Path arrive tagged when called from Beamtalk — they are
unwrapped to bytes here; matching stays byte-level.

The list form is used when called from Beamtalk (where `#(a, b, c)` produces
an Erlang list). The tuple form is accepted for Erlang-native callers.

Returns a compiled route list for use with `match/3`.
""".
-spec compile([{path_param(), path_param(), fun()} | [path_param() | fun()]]) ->
    compiled_routes().
compile(Routes) when is_list(Routes) ->
    [compile_route(R) || R <- Routes].

-doc """
Match a method and path against compiled routes.

Returns:
  - `{ok, Handler, Params}` — matched route with extracted parameters
  - `method_not_allowed` — path matched but method did not
  - `not_found` — no path match at all
""".
-spec match(compiled_routes(), path_param(), path_param()) ->
    {ok, fun(), map()} | method_not_allowed | not_found.
match(Routes, Method, Path) ->
    %% BT-4173: method/path arrive tagged from Beamtalk — matching is
    %% byte-level, so unwrap; captured params are re-tagged (see below).
    Segments = split_path(unwrap_string(Path)),
    match_routes(Routes, unwrap_string(Method), Segments, false).

%%% ============================================================================
%%% Internal — compilation
%%% ============================================================================

-spec compile_route({path_param(), path_param(), fun()} | [path_param() | fun()]) ->
    compiled_route().
compile_route({Method, Path, Handler}) when is_function(Handler) ->
    compile_route_unwrapped(unwrap_string(Method), unwrap_string(Path), Handler);
compile_route([Method, Path, Handler]) when is_function(Handler) ->
    compile_route_unwrapped(unwrap_string(Method), unwrap_string(Path), Handler);
compile_route(_) ->
    type_error('compile:', <<"Each route must be [Method, Path, Handler]">>).

%% @private Compile one route from unwrapped method/path bytes.
-spec compile_route_unwrapped(term(), term(), fun()) -> compiled_route().
compile_route_unwrapped(Method, Path, Handler) when
    is_binary(Method), is_binary(Path)
->
    Segments = parse_pattern(Path),
    validate_segments(Segments, Path),
    {Method, Segments, Handler};
compile_route_unwrapped(_, _, _) ->
    type_error('compile:', <<"Each route must be [Method, Path, Handler]">>).

%% @private Parse a path pattern into segments.
-spec parse_pattern(binary()) -> [segment()].
parse_pattern(Path) ->
    Parts = split_path(Path),
    [parse_segment(P) || P <- Parts].

%% @private Parse a single segment of a path pattern.
-spec parse_segment(binary()) -> segment().
parse_segment(<<$:, Name/binary>>) when byte_size(Name) > 0 ->
    {param, Name};
parse_segment(<<$*, Name/binary>>) when byte_size(Name) > 0 ->
    {wildcard, Name};
parse_segment(Literal) ->
    Literal.

%% @private Validate compiled segments for common mistakes.
%%
%% Rejects:
%%   - Wildcard segments that are not the last segment in the pattern
%%   - Duplicate parameter names within a single route
-spec validate_segments([segment()], binary()) -> ok | no_return().
validate_segments(Segments, Path) ->
    validate_wildcard_position(Segments, Path),
    validate_unique_params(Segments, Path).

-spec validate_wildcard_position([segment()], binary()) -> ok | no_return().
validate_wildcard_position([], _Path) ->
    ok;
validate_wildcard_position([{wildcard, _}], _Path) ->
    ok;
validate_wildcard_position([{wildcard, _} | _], Path) ->
    type_error(
        'compile:',
        iolist_to_binary([
            <<"Wildcard must be the last segment in pattern: ">>, Path
        ])
    );
validate_wildcard_position([_ | Rest], Path) ->
    validate_wildcard_position(Rest, Path).

-spec validate_unique_params([segment()], binary()) -> ok | no_return().
validate_unique_params(Segments, Path) ->
    Names = [
        N
     || S <- Segments,
        N <-
            case S of
                {param, Name} -> [Name];
                {wildcard, Name} -> [Name];
                _ -> []
            end
    ],
    case length(Names) =:= length(lists:usort(Names)) of
        true ->
            ok;
        false ->
            type_error(
                'compile:',
                iolist_to_binary([
                    <<"Duplicate parameter names in pattern: ">>, Path
                ])
            )
    end.

%%% ============================================================================
%%% Internal — matching
%%% ============================================================================

%% @private Try matching each compiled route against method + path segments.
%%
%% Tracks whether any path matched (regardless of method) to distinguish
%% 404 Not Found from 405 Method Not Allowed.
-spec match_routes(compiled_routes(), binary(), [binary()], boolean()) ->
    {ok, fun(), map()} | method_not_allowed | not_found.
match_routes([], _Method, _Segments, true) ->
    method_not_allowed;
match_routes([], _Method, _Segments, false) ->
    not_found;
match_routes([{RouteMethod, Pattern, Handler} | Rest], Method, Segments, PathMatched) ->
    case match_segments(Pattern, Segments, #{}) of
        {ok, Params} ->
            case RouteMethod =:= Method of
                true ->
                    {ok, Handler, Params};
                false ->
                    match_routes(Rest, Method, Segments, true)
            end;
        nomatch ->
            match_routes(Rest, Method, Segments, PathMatched)
    end.

%% @private Match path segments against a compiled pattern, accumulating params.
-spec match_segments([segment()], [binary()], map()) -> {ok, map()} | nomatch.
match_segments([], [], Params) ->
    {ok, Params};
match_segments([], _Extra, _Params) ->
    nomatch;
match_segments(_Remaining, [], _Params) ->
    nomatch;
match_segments([{wildcard, Name} | _], Segments, Params) ->
    %% Wildcard captures all remaining segments joined with /
    Value = join_segments(Segments),
    %% BT-4173: params answer Strings (`req param: "id"` looks up a
    %% String key); non-text bytes stay Binary.
    {ok, Params#{maybe_tag(Name) => maybe_tag(Value)}};
match_segments([{param, Name} | PatternRest], [Seg | SegsRest], Params) ->
    match_segments(PatternRest, SegsRest, Params#{maybe_tag(Name) => maybe_tag(Seg)});
match_segments([Literal | PatternRest], [Seg | SegsRest], Params) when is_binary(Literal) ->
    case Literal =:= Seg of
        true -> match_segments(PatternRest, SegsRest, Params);
        false -> nomatch
    end.

%%% ============================================================================
%%% Internal — utilities
%%% ============================================================================

%% @private Split a URL path into segments, discarding empty parts.
-spec split_path(binary()) -> [binary()].
split_path(Path) ->
    [S || S <- binary:split(Path, <<"/">>, [global]), S =/= <<>>].

%% @private Join path segments with `/`.
-spec join_segments([binary(), ...]) -> binary().
join_segments(Segments) ->
    iolist_to_binary(lists:join(<<"/">>, Segments)).

%% @private Raise a type error.
-spec type_error(atom(), binary()) -> no_return().
type_error(Selector, Hint) ->
    Error0 = beamtalk_error:new(type_error, 'HTTPRouter'),
    Error1 = beamtalk_error:with_selector(Error0, Selector),
    Error2 = beamtalk_error:with_hint(Error1, Hint),
    beamtalk_error:raise(Error2).

%% @private Unwrap a tagged String to bytes; anything else passes through.
-spec unwrap_string(term()) -> term().
unwrap_string({beamtalk_string, Bin}) when is_binary(Bin) -> Bin;
unwrap_string(Other) -> Other.

%% @private Tag bytes as a String when valid UTF-8, else leave as Binary.
-spec maybe_tag(term()) -> term().
maybe_tag(Bin) when is_binary(Bin) ->
    case beamtalk_primitive:is_utf8(Bin) of
        true -> beamtalk_primitive:string_from_binary(Bin);
        false -> Bin
    end;
maybe_tag(Other) ->
    Other.
