%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Christopher S. Meiklejohn.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(prop_partisan_hbbft).

-author("Christopher S. Meiklejohn <christopher.meiklejohn@gmail.com>").

-include("partisan.hrl").

-include_lib("proper/include/proper.hrl").

-compile([export_all]).

-define(TIMEOUT, 10000).

%%%===================================================================
%%% Generators
%%%===================================================================

node_name() ->
    oneof(names()).

names() ->
    NameFun = fun(N) -> 
        list_to_atom("node_" ++ integer_to_list(N)) 
    end,
    lists:map(NameFun, lists:seq(1, node_num_nodes())).

%%%===================================================================
%%% Node Functions
%%%===================================================================

-record(node_state, {}).

%% What node-specific operations should be called.
node_commands() ->
    [
        {call, ?MODULE, submit_transaction, [node_name()]},
        {call, ?MODULE, wait, [node_name()]}
    ].

%% Assertion commands.
node_assertion_functions() ->
    [].

%% Global functions.
node_global_functions() ->
    [sleep].

%% What should the initial node state be.
node_initial_state() ->
    node_debug("initializing", []),
    #node_state{}.

%% Names of the node functions so we kow when we can dispatch to the node
%% pre- and postconditions.
node_functions() ->
    lists:map(fun({call, _Mod, Fun, _Args}) -> Fun end, node_commands()).

%% Precondition.
node_precondition(_NodeState, {call, ?MODULE, submit_transaction, [_Node]}) ->
    true;
node_precondition(_NodeState, {call, ?MODULE, wait, [_Node]}) ->
    true;
node_precondition(_NodeState, {call, ?MODULE, sleep, []}) ->
    true;
node_precondition(_NodeState, _Command) ->
    false.

%% Next state.
node_next_state(_State, NodeState, _Response, _Command) ->
    NodeState.

%% Postconditions for node commands.
node_postcondition(_NodeState, {call, ?MODULE, submit_transaction, [_Node]}, _Result) ->
    true;
node_postcondition(_NodeState, {call, ?MODULE, wait, [_Node]}, _Result) ->
    true;
node_postcondition(_NodeState, {call, ?MODULE, sleep, []}, _Result) ->
    true;
node_postcondition(_NodeState, Command, Response) ->
    node_debug("generic postcondition fired (this probably shouldn't be hit) for command: ~p with response: ~p", 
               [Command, Response]),
    false.

%%%===================================================================
%%% Commands
%%%===================================================================

-define(PROPERTY_MODULE, prop_partisan).

-define(TABLE, table).
-define(RECEIVER, receiver).

-define(ETS, prop_partisan).
-define(NAME, fun(Name) -> [{_, NodeName}] = ets:lookup(?ETS, Name), NodeName end).

%% @private
submit_transaction(Node) ->
    ?PROPERTY_MODULE:command_preamble(Node, [submit_transaction, Node]),

    %% Get number of nodes.
    [{nodes, Nodes}] = ets:lookup(prop_partisan, nodes),
    N = length(Nodes),

    %% Get workers.
    [{workers, Workers}] = ets:lookup(prop_partisan, workers),

    %% Generate a message.
    Msg = crypto:strong_rand_bytes(128),
    node_debug("Msg: ~p", [Msg]),

    %% Determine destinations.
    Destinations = random_n(rand:uniform(N), Workers),
    node_debug("Destinations: ~p", [Destinations]),

    %% Submit transaction.
    [rpc:call(?NAME(Node), partisan_hbbft_worker, submit_transaction, [Msg, Destination]) || {_Node, {ok, Destination}} <- Destinations],

    ?PROPERTY_MODULE:command_conclusion(Node, [submit_transaction, Node]),

    ok.

%% @private
wait(Node) ->
    ?PROPERTY_MODULE:command_preamble(Node, [wait]),

    node_debug("waiting...", []),
    timer:sleep(1000),

    ?PROPERTY_MODULE:command_conclusion(Node, [wait]),

    ok.

%% @private
sleep() ->
    RunnerNode = node(),

    ?PROPERTY_MODULE:command_preamble(RunnerNode, [sleep]),

    node_debug("sleeping...", []),
    timer:sleep(1000),

    ?PROPERTY_MODULE:command_conclusion(RunnerNode, [sleep]),

    ok.

%%%===================================================================
%%% Helper Functions
%%%===================================================================

-define(NODE_DEBUG, true).

%% How many nodes?
node_num_nodes() ->
    5.

%% Should we do node debugging?
node_debug(Line, Args) ->
    case ?NODE_DEBUG of
        true ->
            lager:info("~p: " ++ Line, [?MODULE] ++ Args);
        false ->
            ok
    end.

%% @private
node_begin_property() ->
    partisan_trace_orchestrator:start_link().

%% @private
node_begin_case() ->
    %% Get nodes.
    [{nodes, Nodes}] = ets:lookup(prop_partisan, nodes),

    %% Enable pid encoding.
    lists:foreach(fun({ShortName, _}) ->
        % node_debug("enabling pid_encoding at node ~p", [ShortName]),
        ok = rpc:call(?NAME(ShortName), partisan_config, set, [pid_encoding, true])
    end, Nodes),

    %% Enable register_pid_for_encoding.
    lists:foreach(fun({ShortName, _}) ->
        % node_debug("enabling register_pid_for_encoding at node ~p", [ShortName]),
        ok = rpc:call(?NAME(ShortName), partisan_config, set, [register_pid_for_encoding, true])
    end, Nodes),

    %% Load, configure, and start hbbft.
    lists:foreach(fun({ShortName, _}) ->
        node_debug("loading hbbft at node ~p", [ShortName]),
        case rpc:call(?NAME(ShortName), application, load, [hbbft]) of 
            ok ->
                ok;
            {error, {already_loaded, hbbft}} ->
                ok;
            Other ->
                exit({error, {load_failed, Other}})
        end,

        node_debug("starting hbbft at node ~p", [ShortName]),
        {ok, _} = rpc:call(?NAME(ShortName), application, ensure_all_started, [hbbft])
    end, Nodes),

    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% Start hbbft test
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 

    %% Master starts the dealer.
    N = length(Nodes),
    F = (N div 3),
    BatchSize = 20,
    {ok, Dealer} = dealer:new(N, F+1, 'SS512'),
    {ok, {PubKey, PrivateKeys}} = dealer:deal(Dealer),

    %% each node gets a secret key
    NodesSKs = lists:zip(Nodes, PrivateKeys),

    %% load partisan_hbbft_worker on each node
    {Mod, Bin, _} = code:get_object_code(partisan_hbbft_worker),
    _ = lists:map(fun(Node) -> rpc:call(Node, erlang, load_module, [Mod, Bin]) end, Nodes),

    %% start a hbbft_worker on each node
    Workers = lists:map(fun({I, {{Name1, _} = FullName, SK}}) ->
        {ok, Worker} = rpc:call(?NAME(Name1), partisan_hbbft_worker, start_link, [N, F, I, tpke_privkey:serialize(SK), BatchSize, false]),
        {FullName, {ok, Worker}}
    end, enumerate(NodesSKs)),
    ok = global:sync(),

    %% store workers in the ets table
    true = ets:insert(prop_partisan, {workers, Workers}),

    %% generate a bunch of msgs
    Msgs = [crypto:strong_rand_bytes(128) || _ <- lists:seq(1, N*20)],

    %% feed the nodes some msgs
    lists:foreach(fun(Msg) ->
                          Destinations = random_n(rand:uniform(N), Workers),
                          ct:pal("destinations ~p~n", [Destinations]),
                          [partisan_hbbft_worker:submit_transaction(Msg, Destination) || {_Node, {ok, Destination}} <- Destinations]
                  end, Msgs),

    %% wait for all the worker's mailboxes to settle and.
    %% wait for the chains to converge
    ok = wait_until(fun() ->
                            Chains = sets:from_list(lists:map(fun({_Node, {ok, W}}) ->
                                                                      {ok, Blocks} = partisan_hbbft_worker:get_blocks(W),
                                                                      Blocks
                                                              end, Workers)),

                            0 == lists:sum([element(2, rpc:call(?NAME(Name1), erlang, process_info, [W, message_queue_len])) || {{Name1, _}, {ok, W}} <- Workers]) andalso
                            1 == sets:size(Chains) andalso
                            0 /= length(hd(sets:to_list(Chains)))
                    end, 60*2, 500),

    Chains = sets:from_list(lists:map(fun({_Node, {ok, Worker}}) ->
                                              {ok, Blocks} = partisan_hbbft_worker:get_blocks(Worker),
                                              Blocks
                                      end, Workers)),
    ct:pal("~p distinct chains~n", [sets:size(Chains)]),

    lists:foreach(fun(Chain) ->
                          %ct:pal("Chain: ~p~n", [Chain]),
                          ct:pal("chain is of height ~p~n", [length(Chain)]),

                          %% verify they are cryptographically linked,
                          true = partisan_hbbft_worker:verify_chain(Chain, PubKey),

                          %% check all transactions are unique
                          BlockTxns = lists:flatten([ partisan_hbbft_worker:block_transactions(B) || B <- Chain ]),
                          true = length(BlockTxns) == sets:size(sets:from_list(BlockTxns)),

                          %% check they're all members of the original message list
                          true = sets:is_subset(sets:from_list(BlockTxns), sets:from_list(Msgs)),
                          ct:pal("chain contains ~p distinct transactions~n", [length(BlockTxns)])
                  end, sets:to_list(Chains)),

    %% check we actually converged and made a chain

    true = (1 == sets:size(Chains)),
    true = (0 < length(hd(sets:to_list(Chains)))),

    %% Sleep.
    node_debug("sleeping for convergence", []),
    timer:sleep(1000),
    node_debug("done.", []),

    ok.

%% @private
node_crash(Node) ->
    %% Get workers and terminate them.
    [{workers, Workers}] = ets:lookup(prop_partisan, workers),
    lists:foreach(fun({_, {ok, W}}) -> ok = partisan_hbbft_worker:stop(W) end, Workers),
    ok = global:sync(),

    %% Stop hbbft.
    % node_debug("stopping hbbft on node ~p", [Node]),
    ok = rpc:call(?NAME(Node), application, stop, [hbbft]),

    ok.

%% @private
node_end_case() ->
    node_debug("ending case", []),

    %% Get workers and terminate them.
    [{workers, Workers}] = ets:lookup(prop_partisan, workers),
    lists:foreach(fun({_, {ok, W}}) -> ok = partisan_hbbft_worker:stop(W) end, Workers),
    ok = global:sync(),

    %% Get nodes.
    [{nodes, Nodes}] = ets:lookup(prop_partisan, nodes),

    %% Stop hbbft.
    lists:foreach(fun({ShortName, _}) ->
        % node_debug("stopping hbbft on node ~p", [ShortName]),
        case rpc:call(?NAME(ShortName), application, stop, [hbbft]) of 
            ok ->
                ok;
            {badrpc, nodedown} ->
                ok;
            {error, {not_started, hbbft}} ->
                ok;
            Error ->
                node_debug("cannot terminate hbbft: ~p", [Error]),
                exit({error, shutdown_failed})
        end
    end, Nodes),

    ok.

%% @private
enumerate(List) ->
    lists:zip(lists:seq(0, length(List) - 1), List).

%% @private
random_n(N, List) ->
    lists:sublist(shuffle(List), N).

%% @private
shuffle(List) ->
    [X || {_,X} <- lists:sort([{rand:uniform(), N} || N <- List])].

%% @private
wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry-1, Delay)
    end.