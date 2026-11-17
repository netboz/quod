%% Copyright (c) 2008-2013 Robert Virding
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% File    : erlog_int.erl
%% Author  : Robert Virding
%% Purpose : Basic interpreter of a Prolog definitions.

%% Some standard type macros.

%% The old is_constant/1 ?
-define(IS_CONSTANT(T), (not (is_tuple(T) orelse is_list(T)))).

%% -define(IS_ATOMIC(T), (is_atom(T) orelse is_number(T) orelse (T == []))).
-define(IS_ATOMIC(T), (not (is_tuple(T) orelse (is_list(T) andalso T /= [])))).
-define(IS_FUNCTOR(T), (is_tuple(T) andalso (tuple_size(T) >= 2) andalso is_atom(element(1, T)))).

%% Failure diagnostics are transient interpreter state. Keep the complete stack
%% comfortably below users such as quod's 1 MiB proof-answer frame.
-define(ERLOG_MAX_FAILURE_REASON_BYTES, 4096).
-define(ERLOG_MAX_FAILURE_REASONS_BYTES, 32768).
-define(ERLOG_MAX_FAILURE_REASONS, 256).
-define(ERLOG_MAX_FAILURE_BOUNDARIES, 256).

%% Define the interpreter state record.
-record(est, {cps,				%Choice points
	      bs,				%Bindings
	      vn,				%Var num
	      db,				%Database
	      fs,				%Flags
	      fail_reasons = [],		%Newest explicit failure reason first
	      fail_reason_count = 0,		%Explicit + automatic entries retained above
	      fail_reasons_truncated = false,	%Whether omissions are represented
	      fail_boundaries = 0,		%Diagnostic boundaries created this proof
	      %% Application-owned admission for the complete reason stack.  The
	      %% default uses Erlog's native portable-term bounds; embedders may
	      %% install a stricter wire-compatible policy without Erlog depending
	      %% on their codec.
	      fail_reason_policy = native,
	      checkpoint_depth = 0,		%Opt-in DB choice-point checkpoints
	      %% The embedding evaluation owns this sink. Observations are not
	      %% logical bindings: failed alternatives and rollback still count.
	      observation_sink = none
	     }).
-record(db, {mod,				%Database module
	     ref,				%Database reference
	     loc,				%Local database
	     assert_hooks = #{} :: map(),	%#{Functor => {Mod, Fun}}
	     retract_hooks = #{} :: map()	%#{Functor => {Mod, Fun}}
	    }).

%% Define the choice point record.
-record(cp, {type,label,data,next,bs,vn,
	     db_checkpoint = none,
	     %% Predicate-owned state follows this exact alternative set and is
	     %% discarded naturally when cut or exhausted.
	     owned = #{}}).
-record(cut, {label,next}).

%% Default prolog flags (sorted), {Flag,DefaultValue,SettableValues}.
-define(PROLOG_FLAGS, [{bounded,false,none},
		       {debug,off,[off,on]},
		       {dialect,erlog,none},
		       {double_quotes,codes,none},
		       {iso,true,none},		%Optimistic
		       {max_arity,250,none},
		       {unknown,error,[error,fail,warning]}]).
