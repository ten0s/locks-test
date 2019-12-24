-module(test).
-export([run/0, run/1, stop/0]).
-export([
    ping/1,
    start_leader/2,
    stop_leader/1,
    is_leader/1,
    ping_nodes/2,
    pause/0,
    continue/0,
    graph/0,
    join/1,
    leave/1,
    restart/1
]).
%-compile(export_all).

%% $ rebar3 compile
%% $ erl -noshell -hidden -pa _build/default/lib/*/ebin/ _checkouts/*/ebin/ -eval 'test:run(investigate).'

-define(MASTER, 'master@127.0.0.1').
-define(MAX_NAMES, 10).
-define(START_ARGS, "-pa _build/default/lib/*/ebin _checkouts/*/ebin/ -connect_all false").

run() ->
    run(investigate).

run(OnFail) when OnFail =:= investigate; OnFail =:= heal ->
    Hosts = ["127.0.0.1"],
    Names = slave_names(?MAX_NAMES),
    ok = start_master(),
    register(master_loop, spawn(fun () ->
        loop(OnFail, Hosts, Names, [])
    end)).

stop() ->
    [leave_(Node) || Node <- nodes()].

graph() ->
    master_loop ! graph.

join(Node) ->
    master_loop ! {join, Node}.

leave(Node) ->
    master_loop ! {leave, Node}.

pause() ->
    master_loop ! pause.

continue() ->
    master_loop ! continue.

restart(Node) ->
    master_loop ! {restart, Node}.

investigate(OnFail, Hosts, Names, Nodes) ->
    receive
        graph ->
            L = [{Node, is_leader(Node)} || Node <- Nodes],
            {ok, DotFile, PngFile} = build_nodes_graph(L),
            io:format("~nCheck graph: ~s ~s~n", [DotFile, PngFile]),
            investigate(OnFail, Hosts, Names, Nodes);
        {restart, Node} ->
            stop_leader(Node),
            start_leader(Node, Nodes -- [Node]),
            investigate(OnFail, Hosts, Names, Nodes);
        {join, Node} ->
            Name = node_name(Node),
            Host = node_host(Node),
            Node = join(Host, Name, Nodes),
            investigate(OnFail, Hosts, lists:delete(Name, Names), [Node | Nodes]);
        {leave, Node} ->
            leave_(Node),
            loop(OnFail, Hosts, [node_name(Node) | Names], lists:delete(Node, Nodes));
        continue ->
            loop(OnFail, Hosts, Names, Nodes);
        Msg ->
            io:format("### Unknown: ~p~n", [Msg]),
            investigate(OnFail, Hosts, Names, Nodes)
    end.

%% OnFailAction, AvailableHosts, AvailableNames, RunningNodes
loop(OnFail, Hosts, Names, Nodes) ->
    receive
        graph ->
            L = [{Node, is_leader(Node)} || Node <- Nodes],
            {ok, DotFile, PngFile} = build_nodes_graph(L),
            io:format("~nCheck graph: ~s ~s~n", [DotFile, PngFile]),
            loop(OnFail, Hosts, Names, Nodes);
        pause ->
            investigate(OnFail, Hosts, Names, Nodes);
        Msg ->
            io:format("### Unknown: ~p~n", [Msg]),
            loop(OnFail, Hosts, Names, Nodes)
    after 0 ->
        case oneof(lists:flatten(
            [join || Names =/= []] ++
            [leave || Nodes =/= []] ++
            [check_cluster || Nodes =/= []] ++
            [ping_nodes || length(Nodes) > 1]
        )) of
        join ->
            Host = oneof(Hosts),
            Name = oneof(Names),
            Node = join(Host, Name, Nodes),
            loop(OnFail, Hosts, lists:delete(Name, Names), [Node | Nodes]);
        leave ->
            Node = oneof(Nodes),
            leave_(Node),
            loop(OnFail, Hosts, [node_name(Node) | Names], lists:delete(Node, Nodes));
        check_cluster ->
            io:format("*** CHECK CLUSTER ***~n", []),
            L = [{Node, is_leader(Node)} || Node <- Nodes],
            case check_cluster(L) of
            {[Leader], []} ->
                io:format("*** SINGLE LEADER: ~p, CONSENSUS ***~n", [Leader]),
                loop(OnFail, Hosts, Names, Nodes);
            {Leaders, []} ->
                io:format("*** MULTIPLE LEADERS: ~p ***~n", [Leaders]),
                loop(OnFail, Hosts, Names, Nodes);
            {Leaders, FailedNodes} ->
                io:format("~nCheck nodes: ~p~n", [L]),
                case OnFail of
                investigate ->
                    io:format("Connect to master@127.0.0.1 and run:~n"),
                    io:format("test:graph().~n"),
                    io:format("test:restart(Node).~n"),
                    io:format("test:join(Node).~n"),
                    io:format("test:leave(Node).~n"),
                    io:format("test:ping_nodes(Node, Nodes).~n"),
                    io:format("test:is_leader(Node).~n"),
                    io:format("Run test:continue(). to proceed~n"),
                    investigate(OnFail, Hosts, Names, Nodes);
                heal ->
                    heal_cluster(OnFail, Hosts, Names, Nodes, Leaders, FailedNodes)
                end
            end;
        ping_nodes ->
            Node = oneof(Nodes),
            ping_nodes(Node, Nodes -- [Node]),
            loop(OnFail, Hosts, Names, Nodes)
        end
    end.

heal_cluster(OnFail, Hosts, Names, Nodes, Leaders, FailedNodes) ->
    receive
        graph ->
            L = [{Node, is_leader(Node)} || Node <- Nodes],
            {ok, DotFile, PngFile} = build_nodes_graph(L),
            io:format("~nCheck graph: ~s ~s~n", [DotFile, PngFile]),
            heal_cluster(OnFail, Hosts, Names, Nodes, Leaders, FailedNodes);
        pause ->
            heal_cluster(OnFail, Hosts, Names, Nodes, Leaders, FailedNodes);
        Msg ->
            io:format("### Unknown: ~p~n", [Msg]),
            heal_cluster(OnFail, Hosts, Names, Nodes, Leaders, FailedNodes)
    after 0 ->
        io:format("*** HEAL CLUSTER ***~n", []),
        restart_leaders(FailedNodes, Nodes),
        %% No need to connect the leaders since pings will do it shortly
        %connect_leaders(Leaders, Nodes),

        L = [{Node, is_leader(Node)} || Node <- Nodes],
        case check_cluster(L) of
        {[Leader2], []} ->
            io:format("*** SINGLE LEADER: ~p, CONSENSUS ***~n", [Leader2]),
            loop(OnFail, Hosts, Names, Nodes);
        {Leaders2, []} ->
            io:format("*** MULTIPLE LEADERS: ~p ***~n", [Leaders2]),
            loop(OnFail, Hosts, Names, Nodes);

        {[], FailedNodes2} ->
            io:format("*** NO LEADER, FAILED: ~p ***~n", [FailedNodes2]),
            io:format("~nCheck nodes: ~p~n", [L]),
            heal_cluster(OnFail, Hosts, Names, Nodes, Leaders, FailedNodes2);
        {[Leader2], FailedNodes2} ->
            io:format("*** SINGLE LEADER: ~p, FAILED: ~p ***~n", [Leader2, FailedNodes2]),
            io:format("~nCheck nodes: ~p~n", [L]),
            heal_cluster(OnFail, Hosts, Names, Nodes, [Leader2], FailedNodes2);
        {Leaders2, FailedNodes2} ->
            io:format("*** MULTIPLE LEADERS: ~p, FAILED: ~p ***~n", [Leaders2, FailedNodes2]),
            io:format("~nCheck nodes: ~p~n", [L]),
            heal_cluster(OnFail, Hosts, Names, Nodes, Leaders2, FailedNodes2)
        end
    end.

restart_leaders([], _Nodes) ->
    io:format("*** NO NODES TO RESTART ***~n", []);
restart_leaders(FailedNodes, Nodes) ->
    [restart_leader(Node, Nodes) || Node <- FailedNodes].

restart_leader(Node, Nodes) ->
    %% In RE when timeout
    stop_leader(Node),
    timer:sleep(rand:uniform(5000)),
    %% Supervisor's job
    start_leader(Node, Nodes -- [Node]).

%% connect_leaders([], _Nodes) ->
%%     io:format("*** NO LEADERS TO CONNECT ***~n", []);
%% connect_leaders(Leaders, Nodes) ->
%%     [ping_nodes(Leader, Nodes) || Leader <- Leaders].

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

leave_(Node) ->
    io:format("*** LEAVE ~p ***~n", [Node]),
    stop_worker(Node),
    stop_slave(Node).

check_cluster(L) ->
    lists:foldl(fun
        ({Node, true}, {Leaders, Fails}) ->
            {[Node | Leaders], Fails};
        ({_Node, false}, Acc) ->
            Acc;
        ({Node, _Other}, {Leaders, Fails}) ->
            {Leaders, [Node | Fails]}
    end, {[], []}, L).

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

ping(Node) ->
    rpc(Node, ping).

start_leader(Node, Nodes) ->
    rpc(Node, {start_leader, Nodes}).

stop_leader(Node) ->
    rpc(Node, stop_leader).

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
            lists:foldl(fun (KNode, Acc2) ->
                [node_name(Node), " -- ", node_name(KNode), "\n" | Acc2]
            end, Acc1, KNodes)
    end, [], Infos),
    Dot = [Header, Defines, Connections, Footer],
    {{Y,Mon,D},{H,M,S}} = calendar:local_time(),
    Ts = io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B-~2..0B-~2..0B", [Y, Mon, D, H, M, S]),
    DotFile = ["cluster-", Ts, ".dot"],
    PngFile = ["cluster-", Ts, ".png"],
    ok = file:write_file(DotFile, Dot),
    os:cmd(["dot", " -T png ", " -o ", PngFile, " ", DotFile]),
    case os:getenv("IMAGE_VIEWER") of
    ImageViewer when is_list(ImageViewer) ->
        os:cmd([ImageViewer, " ", PngFile, "&"]);
    _ ->
        ok
    end,
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
    after 10000 ->
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
            {Ref, From, stop_leader} ->
                catch exit(LeaderPid, restart), % might be nil
                From ! {Ref, ok},
                Loop(nil);
            {Ref, From, is_leader} ->
                From ! {Ref, catch asg_manager:is_leader()},
                Loop(LeaderPid);
            {Ref, From, known_nodes} ->
                From ! {Ref, erlang:nodes()},
                Loop(LeaderPid);
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

node_host(Node) ->
    tl(lists:dropwhile(fun ($@) -> false; (_) -> true end, atom_to_list(Node))).
