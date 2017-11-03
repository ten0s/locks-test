%%%-------------------------------------------------------------------
%% @doc leader top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(leader_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    {ok, {{one_for_all, 0, 1}, [
%        {asg_manager, {asg_manager, start_link, []}, permanent, 5000, worker, [asg_manager]}
    ]}}.

%%====================================================================
%% Internal functions
%%====================================================================
