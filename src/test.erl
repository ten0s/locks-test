-module(test).
-export([run/0, stop/0]).
%-compile(export_all).

%% $ rebar3 compile
%% $ erl -noshell -pa _build/default/lib/*/ebin/ -eval 'test:run().'

-define(MASTER, 'master@127.0.0.1').
-define(MAX_NAMES, 10).
-define(START_ARGS, "-pa _build/default/lib/*/ebin -connect_all false").

run() ->
    Hosts = ["127.0.0.1"],
    Names = slave_names(?MAX_NAMES),
    ok = start_master(),
    {ok, _Nodes} = loop(Hosts, Names, []).

stop() ->
    [leave(Node) || Node <- nodes()].

loop(Hosts, Names, Nodes) ->
    case oneof(lists:flatten(
        [join || Names =/= []] ++
        [leave || Nodes =/= []] ++
        [count_leaders || Nodes =/= []] ++
        [ping_nodes || length(Nodes) > 1]
    )) of
    join ->
        io:format("*** JOIN ***~n", []),
        Host = oneof(Hosts),
        Name = oneof(Names),
        Node = join(Host, Name, Nodes),
        loop(Hosts, lists:delete(Name, Names), [Node | Nodes]);
    leave ->
        io:format("*** LEAVE ***~n", []),
        Node = oneof(Nodes),
        leave(Node),
        loop(Hosts, [node_name(Node) | Names], lists:delete(Node, Nodes));
    count_leaders ->
        io:format("*** COUNT LEADERS ***~n", []),
        case count_leaders(Nodes) of
        ok ->
            loop(Hosts, Names, Nodes);
        error ->
            io:format("*** LEAVE ALL NODES ***~n", []),
            [leave(Node) || Node <- Nodes],
            Names2 = [node_name(Node) || Node <- Nodes] ++ Names,
            loop(Hosts, Names2, [])
        end;
    ping_nodes ->
        io:format("*** PING NODES ***~n", []),
        Node = oneof(Nodes),
        ping_nodes(Node, Nodes -- [Node]),
        loop(Hosts, Names, Nodes)
    end.

start_master() ->
    case node() of
    'nonode@nohost' ->
        os:cmd("epmd -daemon"),
        {ok, _} = net_kernel:start([?MASTER, longnames]),
        ok;
    _Node ->
        ok
    end.

join(Host, Name, Nodes) ->
    Node = start_slave(Host, Name, ?START_ARGS),
    start_worker(Node),
    %%
    %% !!! This fixes the problem !!!
    %%
    %ping_nodes(Node, Nodes),
    start_leader(Node, Nodes),
    Node.

leave(Node) ->
    stop_worker(Node),
    stop_slave(Node).

count_leaders(Nodes) ->
    L = pmap(fun(Node) -> {Node, is_leader(Node)} end, Nodes),
    case catch lists:sum([count_leader(Res) || {_Node, Res} <- L]) of
    0 ->
        io:format("*** NO LEADER ***~n", []),
        ok;
    1 ->
        io:format("*** SINGLE LEADER ***~n", []),
        ok;
    N when is_integer(N) ->
        io:format("*** MULTIPLE (~p) LEADERS ***~n", [N]),
        ok;
    _ ->
        io:format("~nCheck nodes: ~p~n", [L]),
        io:fread("\nPress Enter to continue", ""),
        error
    end.

pmap(F, L) ->
    Pids = [spawn_monitor(fun() ->
                                  exit({ok, F(N)})
                          end) || N <- L],
    collect(Pids).

collect([{Pid, MRef}|Pids]) ->
    Res = receive
              {'DOWN', MRef, process, Pid, Reason} ->
                  case Reason of
                      {ok, Good} ->
                          Good;
                      Bad ->
                          {'EXIT', Bad}
                  end
          end,
    [Res | collect(Pids)];
collect([]) ->
    [].


count_leader(true) ->
    1;
count_leader(false) ->
    0;
count_leader(Other) ->
    throw(Other).

start_slave(Host, Name, Args) ->
    {ok, Node} = slave:start(Host, Name, Args),
    Node.

stop_slave(Node) ->
    slave:stop(Node).

slave_names(Num) ->
    [slave_name(I) || I <- lists:seq(1, Num)].

slave_name(Idx) ->
    "slave" ++ integer_to_list(Idx).

start_worker(Node) ->
    spawn(Node, worker(self())),
    receive
    started ->
        ok
    after 1000 ->
        exit({worker_start_timeout, Node})
    end.

stop_worker(Node) ->
    rpc(Node, stop).

%% ping(Node) ->
%%     rpc(Node, ping).

start_leader(Node, Nodes) ->
    rpc(Node, {start_leader, Nodes}).

is_leader(Node) ->
    rpc(Node, is_leader).

ping_nodes(Node, Nodes) ->
    rpc(Node, {ping_nodes, Nodes}).

rpc(Node, Req) ->
    Ref = make_ref(),
    Self = self(),
    {worker, Node} ! {Ref, Self, Req},
    receive
    {Ref, Rep} ->
        Rep
    after 1200000 ->
            timeout
    end.

worker(Parent) ->
    fun () ->
        process_flag(trap_exit, true),
        %io:format("~p: starting worker~n", [node()]),
        application:ensure_all_started(leader),
        register(worker, self()),
        Parent ! started,
        (fun Loop(LeaderPid) ->
            receive
            {Ref, From, ping} ->
                From ! {Ref, pong},
                Loop(LeaderPid);
            {Ref, From, stop} ->
                %io:format("~p: stopping worker~n", [node()]),
                asg_manager:stop(),
                timer:sleep(100),
                From ! {Ref, ok};
            {Ref, From, {ping_nodes, Nodes}} ->
                [net_adm:ping(Node) || Node <- Nodes],
                From ! {Ref, ok},
                Loop(LeaderPid);
            {Ref, From, {start_leader, Nodes}} ->
                {ok, Pid} = asg_manager:start_link(Nodes),
                From ! {Ref, ok},
                Loop(Pid);
            {Ref, From, is_leader} ->
                From ! {Ref, catch asg_manager:is_leader()},
                Loop(LeaderPid);
            {'EXIT', LeaderPid, restart} ->
                io:format("~p: leader restart~n", [node()]),
                {ok, Pid} = asg_manager:start_link(),
                Loop(Pid);
            Other ->
                io:format("Unexpected: ~p~n", [Other]),
                Loop(LeaderPid)
            end
        end)(nil)
    end.

oneof(L) ->
    lists:nth(rand:uniform(length(L)), L).

node_name(Node) ->
    lists:takewhile(fun ($@) -> false; (_) -> true end, atom_to_list(Node)).
