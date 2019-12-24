-module('asg_manager').

-behaviour(locks_leader).

%% external exports
-export([
    start_link/0,
    start_link/1,
    stop/0,
    is_leader/0,
    info/0, info/1
]).
-ignore_xref([start_link/0]).

%%% locks_leader callbacks
-export([
    init/1, handle_call/4, handle_cast/3, handle_info/3,
    handle_leader_call/4, handle_leader_cast/3, handle_DOWN/3,
    elected/3, surrendered/3, from_leader/3,
    code_change/4, terminate/2
]).

%%%------------------------------------------------------------------------
%%% API
%%%------------------------------------------------------------------------

start_link() ->
    start_link(nodes()).

start_link(Nodes) when is_list(Nodes) ->
    %io:format("~p: started with: ~p~n", [node(), Nodes]),
    L = lists:usort(Nodes -- [node()]),
    locks_leader:start_link(?MODULE, ?MODULE, L, []).

stop() ->
    locks_leader:call(?MODULE, stop).

is_leader() ->
    locks_leader:call(?MODULE, is_leader).

info() ->
    locks_leader:info(?MODULE).

info(Item) ->
    locks_leader:info(?MODULE, Item).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

-record(state, {
    is_leader = false
}).

%%-------------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%-------------------------------------------------------------------------
init(Nodes) ->
    % process_flag(trap_exit, true),
    case Nodes of
    [] ->
        restart_refresh_nodes_timer();
    _ ->
        nop
    end,
    {ok, #state{}}.

%%-------------------------------------------------------------------------
%% @private
%% @doc
%% Called only in the leader process when it is elected. The Synch
%% term will be broadcasted to all (?) the nodes in the cluster.
%%
%% @spec elected(State, Election, undefined) ->
%%                              {reply, Synch, State} | {ok, Synch, State}
%% @end
%%-------------------------------------------------------------------------
elected(State = #state{is_leader = true}, Election, undefined) ->
    io:format("~p: elected already, cands: ~p~n", [node(), cands(Election)]),
    {ok, {elected, node()}, State};
elected(State, Election, undefined) ->
    io:format("~p: elected, cands: ~p~n", [node(), cands(Election)]),
    {ok, {elected, node()}, State#state{is_leader = true}};

%%-------------------------------------------------------------------------
%% @private
%% @doc
%% Called only in the leader process when a new candidate joins the
%% cluster. The Synch term will be sent to Node.
%%
%% @spec elected(State, Election, undefined) ->
%%                              {reply, Synch, State} | {ok, Synch, State}
%% @end
%%-------------------------------------------------------------------------
elected(State, Election, Pid) ->
    Node = node(Pid),
    io:format("~p: joined ~p, cands: ~p~n", [node(), Node, cands(Election)]),
    % Another node recognized us as the leader.
    % Don't broadcast all data to everyone else.
    {reply, {joined, Node}, State}.

%%-------------------------------------------------------------------------
%% @private
%% @doc
%% Called in all members of the cluster except the leader. Synch is a
%% term returned by the leader in the elected/3 callback.
%%
%% @spec surrendered(State, Synch, Election) -> {ok, State}
%% @end
%%-------------------------------------------------------------------------
surrendered(State = #state{is_leader = true}, Synch, Election) ->
    % I was leader; a netsplit has occurred
    io:format("~p: netsplit surrender: ~p, cands: ~p~n", [node(), Synch, cands(Election)]),
    {ok, State#state{is_leader = false}};
surrendered(State, Synch, Election) ->
    % Normal surrender
    io:format("~p: normal surrender: ~p, cands: ~p~n", [node(), Synch, cands(Election)]),
    {ok, State}.

%%-------------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages. Called in the leader.
%%
%% @spec handle_leader_call(Request, From, State, Election) ->
%%                                            {reply, Reply, Broadcast, State} |
%%                                            {reply, Reply, State} |
%%                                            {noreply, State} |
%%                                            {stop, Reason, State}
%% @end
%%-------------------------------------------------------------------------
handle_leader_call(_Request, _From, State, _Election) ->
    {reply, ok, State}.

%%-------------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages. Called in the leader.
%%
%% @spec handle_leader_cast(Request, State, Election) ->
%%                                            {ok, State} |
%%                                            {ok, Msg, State} |
%%                                            {stop, Reason, State}
%% @end
%%-------------------------------------------------------------------------
handle_leader_cast(stop, State, Election) ->
    io:format("~p: stop leader normal, cands: ~p~n", [node(), cands(Election)]),
    {stop, normal, State};

handle_leader_cast(_Msg, State, _Election) ->
    {ok, State}.

%%-------------------------------------------------------------------------
%% @private
%% @doc
%% Handling messages from leader.
%%
%% @spec from_leader(Request, State, Election) ->
%%                                    {ok, State} |
%%                                    {ok, Msg, State} |
%%                                    {stop, Reason, State}
%% @end
%%-------------------------------------------------------------------------
from_leader(_Ops, State, _Election) ->
    {ok, State}.

%%-------------------------------------------------------------------------
%% @private
%% @doc
%% Handling nodes going down. Called in the leader only.
%%
%% @spec handle_DOWN(Node, State, Election) ->
%%                                  {ok, State} |
%%                                  {ok, Msg, State} |
%%                                  {stop, Reason, State}
%% @end
%%-------------------------------------------------------------------------
handle_DOWN(Pid, State, Election) ->
    io:format("~p: down ~p, cands: ~p~n", [node(), node(Pid), cands(Election)]),
    {ok, State}.

%%-------------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State, Election) ->
%%                                   {reply, Reply, State} |
%%                                   {noreply, State} |
%%                                   {stop, Reason, State}
%% @end
%%-------------------------------------------------------------------------
handle_call(stop, _From, State = #state{is_leader = Flag}, Election) ->
    io:format("~p: is_leader=~p stopping, cands: ~p~n", [node(), Flag, cands(Election)]),
    {stop, normal, ok, State};

handle_call(is_leader, _From, State = #state{is_leader = Flag}, _Election) ->
    {reply, Flag, State};

handle_call(Req, _From, State, Election) ->
    io:format("~p: unknown call: ~p, cands: ~p~n", [node(), Req, cands(Election)]),
    {reply, {error, unknown_request}, State}.

%%-------------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State, Election) ->
%%                                  {ok, State} |
%%                                  {stop, Reason, State}
%% @end
%%-------------------------------------------------------------------------
handle_cast(Msg, State, Election) ->
    io:format("~p: unknown cast: ~p, cands: ~p~n", [node(), Msg, cands(Election)]),
    {ok, State}.

%%-------------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State, Election) ->
%%                                   {ok, State} |
%%                                   {stop, Reason, State}
%% @end
%%-------------------------------------------------------------------------
handle_info(refresh_nodes, State, Election) ->
    case cands(Election) -- [node()] of
    [] ->
        case nodes() -- [node()] of
        [] ->
            restart_refresh_nodes_timer(),
            {ok, State};
        _ ->
            {stop, restart, State}
        end;
    _ ->
        {ok, State}
    end;

handle_info(Info, State, Election) ->
    io:format("~p: unknown info: ~p, cands: ~p~n", [node(), Info, cands(Election)]),
    {ok, State}.

%%-------------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a locks_leader when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the locks_leader terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%-------------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%-------------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Election, Extra) ->
%%                                          {ok, NewState} |
%%                                          {ok, NewState, NewElection}
%% @end
%%-------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra, _Election) ->
    {ok, State}.

%%%------------------------------------------------------------------------
%%% Internal functions
%%%------------------------------------------------------------------------

restart_refresh_nodes_timer() ->
    Timeout = application:get_env(leader, refresh_nodes_timeout, 5000),
    {ok, _TRef} = timer:send_after(Timeout, refresh_nodes).

cands(Election) ->
    [node(P) || P <- locks_leader:candidates(Election)].
