%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

-module(beamtalk_http_text).
-moduledoc """
String/Binary boundary helpers shared by the HTTP client, router and server
(BT-4173).

One authority for the UTF-8 tagging policy so the three call sites cannot
drift.
""".

-export([unwrap_string/1, maybe_tag/1]).

-doc "Unwrap a tagged String to bytes; anything else passes through.".
-spec unwrap_string(term()) -> term().
unwrap_string({beamtalk_string, Bin}) when is_binary(Bin) -> Bin;
unwrap_string(Other) -> Other.

-doc """
Tag wire bytes as a String when they are valid UTF-8.

Non-text bytes (e.g. a binary response body) stay a bare Binary — tagging
them would lie about the value's class. Fields that can carry such bytes are
declared `String | Binary`.
""".
-spec maybe_tag(term()) -> term().
maybe_tag(Bin) when is_binary(Bin) ->
    case beamtalk_primitive:is_utf8(Bin) of
        true -> beamtalk_primitive:string_from_binary(Bin);
        false -> Bin
    end;
maybe_tag(Other) ->
    Other.
