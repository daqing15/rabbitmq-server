%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2013 GoPivotal, Inc.  All rights reserved.
%%

-module(delegate).

-behaviour(gen_server2).

-export([start_link/1, invoke_no_result/2, invoke/2, call/2, cast/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(fun_or_mfa(A) :: fun ((pid()) -> A) | {atom(), atom(), [any()]}).
-spec(start_link/1 ::
        (non_neg_integer()) -> {'ok', pid()} | ignore | {'error', any()}).
-spec(invoke/2 :: ( pid(),  fun_or_mfa(A)) -> A;
                  ([pid()], fun_or_mfa(A)) -> {[{pid(), A}],
                                               [{pid(), term()}]}).
-spec(invoke_no_result/2 :: (pid() | [pid()], fun_or_mfa(any())) -> 'ok').
-spec(call/2 ::
        ( pid(),  any()) -> any();
        ([pid()], any()) -> {[{pid(), any()}], [{pid(), term()}]}).
-spec(cast/2 :: (pid() | [pid()], any()) -> 'ok').

-endif.

%%----------------------------------------------------------------------------

-define(HIBERNATE_AFTER_MIN, 1000).
-define(DESIRED_HIBERNATE,   10000).

%%----------------------------------------------------------------------------

start_link(Num) ->
    gen_server2:start_link({local, delegate_name(Num)}, ?MODULE, [], []).

invoke(Pid, FunOrMFA) when is_pid(Pid) andalso node(Pid) =:= node() ->
    apply1(FunOrMFA, Pid);
invoke(Pid, FunOrMFA) when is_pid(Pid) ->
    case invoke([Pid], FunOrMFA) of
        {[{Pid, Result}], []} ->
            Result;
        {[], [{Pid, {Class, Reason, StackTrace}}]} ->
            erlang:raise(Class, Reason, StackTrace)
    end;

invoke([], _FunOrMFA) -> %% optimisation
    {[], []};
invoke([Pid], FunOrMFA) when node(Pid) =:= node() -> %% optimisation
    case safe_invoke(Pid, FunOrMFA) of
        {ok,    _, Result} -> {[{Pid, Result}], []};
        {error, _, Error}  -> {[], [{Pid, Error}]}
    end;
invoke(Pids, FunOrMFA) when is_list(Pids) ->
    {LocalPids, Grouped} = group_pids_by_node(Pids),
    %% The use of multi_call is only safe because the timeout is
    %% infinity, and thus there is no process spawned in order to do
    %% the sending. Thus calls can't overtake preceding calls/casts.
    {Replies, BadNodes} =
        case orddict:fetch_keys(Grouped) of
            []          -> {[], []};
            RemoteNodes -> gen_server2:multi_call(
                             RemoteNodes, delegate(RemoteNodes),
                             {invoke, FunOrMFA, Grouped}, infinity)
        end,
    BadPids = [{Pid, {exit, {nodedown, BadNode}, []}} ||
                  BadNode <- BadNodes,
                  Pid     <- orddict:fetch(BadNode, Grouped)],
    ResultsNoNode = lists:append([safe_invoke(LocalPids, FunOrMFA) |
                                  [Results || {_Node, Results} <- Replies]]),
    lists:foldl(
      fun ({ok,    Pid, Result}, {Good, Bad}) -> {[{Pid, Result} | Good], Bad};
          ({error, Pid, Error},  {Good, Bad}) -> {Good, [{Pid, Error} | Bad]}
      end, {[], BadPids}, ResultsNoNode).

invoke_no_result(Pid, FunOrMFA) when is_pid(Pid) andalso node(Pid) =:= node() ->
    safe_invoke(Pid, FunOrMFA), %% we don't care about any error
    ok;
invoke_no_result(Pid, FunOrMFA) when is_pid(Pid) ->
    invoke_no_result([Pid], FunOrMFA);

invoke_no_result([], _FunOrMFA) -> %% optimisation
    ok;
invoke_no_result([Pid], FunOrMFA) when node(Pid) =:= node() -> %% optimisation
    safe_invoke(Pid, FunOrMFA), %% must not die
    ok;
invoke_no_result(Pids, FunOrMFA) when is_list(Pids) ->
    {LocalPids, Grouped} = group_pids_by_node(Pids),
    case orddict:fetch_keys(Grouped) of
        []          -> ok;
        RemoteNodes -> gen_server2:abcast(RemoteNodes, delegate(RemoteNodes),
                                          {invoke, FunOrMFA, Grouped})
    end,
    safe_invoke(LocalPids, FunOrMFA), %% must not die
    ok.

call(PidOrPids, Msg) ->
    invoke(PidOrPids, {gen_server2, call, [Msg, infinity]}).

cast(PidOrPids, Msg) ->
    invoke_no_result(PidOrPids, {gen_server2, cast, [Msg]}).

%%----------------------------------------------------------------------------

group_pids_by_node(Pids) ->
    LocalNode = node(),
    lists:foldl(
      fun (Pid, {Local, Remote}) when node(Pid) =:= LocalNode ->
              {[Pid | Local], Remote};
          (Pid, {Local, Remote}) ->
              {Local,
               orddict:update(
                 node(Pid), fun (List) -> [Pid | List] end, [Pid], Remote)}
      end, {[], orddict:new()}, Pids).

delegate_name(Hash) ->
    list_to_atom("delegate_" ++ integer_to_list(Hash)).

delegate(RemoteNodes) ->
    case get(delegate) of
        undefined -> Name = delegate_name(
                              erlang:phash2(self(),
                                            delegate_sup:count(RemoteNodes))),
                     put(delegate, Name),
                     Name;
        Name      -> Name
    end.

safe_invoke(Pids, FunOrMFA) when is_list(Pids) ->
    [safe_invoke(Pid, FunOrMFA) || Pid <- Pids];
safe_invoke(Pid, FunOrMFA) when is_pid(Pid) ->
    try
        {ok, Pid, apply1(FunOrMFA, Pid)}
    catch Class:Reason ->
            {error, Pid, {Class, Reason, erlang:get_stacktrace()}}
    end.

apply1({M, F, A}, Arg) -> apply(M, F, [Arg | A]);
apply1(Fun,       Arg) -> Fun(Arg).

%%----------------------------------------------------------------------------

init([]) ->
    {ok, node(), hibernate,
     {backoff, ?HIBERNATE_AFTER_MIN, ?HIBERNATE_AFTER_MIN, ?DESIRED_HIBERNATE}}.

handle_call({invoke, FunOrMFA, Grouped}, _From, Node) ->
    {reply, safe_invoke(orddict:fetch(Node, Grouped), FunOrMFA), Node,
     hibernate}.

handle_cast({invoke, FunOrMFA, Grouped}, Node) ->
    safe_invoke(orddict:fetch(Node, Grouped), FunOrMFA),
    {noreply, Node, hibernate}.

handle_info(_Info, Node) ->
    {noreply, Node, hibernate}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, Node, _Extra) ->
    {ok, Node}.
