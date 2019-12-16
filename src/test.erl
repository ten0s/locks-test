-module(test).
-export([run/0, stop/0]).
%-compile(export_all).

%% $ rebar3 compile
%% $ erl -noshell -hidden -pa _build/default/lib/*/ebin/ -eval 'test:run().'

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
        Host = oneof(Hosts),
        Name = oneof(Names),
        Node = join(Host, Name, Nodes),
        loop(Hosts, lists:delete(Name, Names), [Node | Nodes]);
    leave ->
        Node = oneof(Nodes),
        leave(Node),
        loop(Hosts, [node_name(Node) | Names], lists:delete(Node, Nodes));
    count_leaders ->
        case count_leaders(Nodes) of
        ok ->
            loop(Hosts, Names, Nodes);
        error ->
            io:format("*** LEAVE ALL ***~n", []),
            [leave(Node) || Node <- Nodes],
            Names2 = [node_name(Node) || Node <- Nodes] ++ Names,
            loop(Hosts, Names2, [])
        end;
    ping_nodes ->
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
    io:format("*** JOIN '~s@~s' ***~n", [Name, Host]),
    Node = start_slave(Host, Name, ?START_ARGS),
    start_worker(Node),
    %%
    %% !!! This fixes the problem !!!
    %%
    %ping_nodes(Node, Nodes),
    start_leader(Node, Nodes),
    Node.

leave(Node) ->
    io:format("*** LEAVE ~p ***~n", [Node]),
    stop_worker(Node),
    stop_slave(Node).

count_leaders(Nodes) ->
    io:format("*** COUNT LEADERS ***~n", []),
    L = [{Node, is_leader(Node)} || Node <- Nodes],
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
        {ok, DotFile, PngFile} = build_nodes_graph(L),
        io:format("~nCheck graph: ~s ~s~n", [DotFile, PngFile]),
        io:format("~p~n", [calendar:local_time()]),
        io:fread("\nPress Enter to continue", ""),
        error
    end.

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
    io:format("*** PING NODES ***~n", []),
    rpc(Node, {ping_nodes, Nodes}).

-record(info, {
    node,
    is_leader,
    known_nodes
}).

build_nodes_graph(Nodes) ->
    Infos = lists:foldl(fun ({Node, IsLeader}, Acc) ->
        Info = #info{
            node = Node,
            is_leader = IsLeader,
            known_nodes = known_nodes(Node)
        },
        [Info | Acc]
    end, [], Nodes),
    %% `strict` mode to remove duplicate edges
    Header = "strict graph {\n",
    Footer = "}\n",
    Defines = [dot_node(I) || I <- Infos],
    Connections = lists:foldl(fun (#info{node = Node, known_nodes = KNodes}, Acc1) ->
        lists:foldl(fun (KNode, Acc2) -> [node_name(Node), " -- ", node_name(KNode), "\n" | Acc2] end, Acc1, KNodes)
    end, [], Infos),
    Dot = [Header, Defines, Connections, Footer],
    {{Y,Mon,D},{H,M,S}} = calendar:local_time(),
    Ts = io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B-~2..0B-~2..0B", [Y, Mon, D, H, M, S]),
    DotFile = ["cluster-", Ts, ".dot"],
    PngFile = ["cluster-", Ts, ".png"],
    ok = file:write_file(DotFile, Dot),
    os:cmd(["dot", " -T png ", " -o ", PngFile, " ", DotFile]),
    os:cmd(["xviewer", " ", PngFile]),
    {ok, DotFile, PngFile}.

dot_node(Info) ->
    [node_name(Info#info.node), " ", dot_props([dot_prop_label(Info), dot_prop_color(Info)])].

dot_props(Props) ->
    ["[",
        [[P, " "] || P <- Props],
     "]\n"].

dot_prop_label(#info{node = Node, known_nodes = KNodes}) ->
    dot_prop("label", [node_name(Node), "^", integer_to_list(length(KNodes))]).

dot_prop_color(#info{is_leader = IsLeader}) ->
    Color =
        case IsLeader of
        true  -> "blue";
        false -> "black";
        _     -> "red"
        end,
    dot_prop("color", Color).

dot_prop(Name, Value) ->
    [Name, "=", "\"", Value, "\""].

known_nodes(Node) ->
    rpc(Node, known_nodes).

rpc(Node, Req) ->
    Ref = make_ref(),
    Self = self(),
    {worker, Node} ! {Ref, Self, Req},
    receive
    {Ref, Rep} ->
        Rep
    after 60000 ->
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
            {Ref, From, known_nodes} ->
                From ! {Ref, erlang:nodes()},
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
