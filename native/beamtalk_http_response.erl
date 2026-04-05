%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

-module(beamtalk_http_response).
-moduledoc """
Type definitions for the HTTPResponse Beamtalk value object (BT-1162).

**DDD Context:** Object System Context

Provides the canonical Dialyzer-visible type `t()` for HTTPResponse value
objects returned by `beamtalk_http`. The runtime map structure is produced
by the Beamtalk compiler from `state:` declarations in `src/HTTPResponse.bt`
and constructed by the generated HTTPResponse keyword constructor
`class_status:headers:body:/5`.

This module is a type-only companion to `beamtalk_http` — it exports no
functions. The generated HTTPResponse module is excluded from the Dialyzer PLT
(generated BEAM abstract code cannot be analysed); this module mirrors its
map structure so that `-spec` annotations in `beamtalk_http` can reference
`beamtalk_http_response:t()` and benefit from Dialyzer validation.
""".

-export_type([t/0]).

-doc """
The map type for a Beamtalk HTTPResponse value object.

Fields mirror the `field:` declarations in `src/HTTPResponse.bt`:
  field: status  :: Integer = 0
  field: headers :: List    = #()
  field: body    :: String  = ""
""".
-type t() :: #{
    '$beamtalk_class' := 'HTTPResponse',
    'status' := integer(),
    'headers' := [[binary()]],
    'body' := binary()
}.
