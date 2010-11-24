-module(rscmgr).

-author('James Aimonetti <james@sfvoip.com>').
-export([start/0, start_link/0, stop/0]).

ensure_started(App) ->
    case application:start(App) of
	ok ->
	    ok;
	{error, {already_started, App}} ->
	    ok
    end.

%% @spec start_link() -> {ok,Pid::pid()}
%% @doc Starts the app for inclusion in a supervisor tree
start_link() ->
    rscmgr_deps:ensure(),
    ensure_started(sasl),
    ensure_started(crypto),
    ensure_started(amqp),
    rscmgr_sup:start_link().

%% @spec start() -> ok
%% @doc Start the rscmgr server.
start() ->
    rscmgr_deps:ensure(),
    ensure_started(sasl),
    ensure_started(crypto),
    ensure_started(amqp),
    application:start(rscmgr).

%% @spec stop() -> ok
%% @doc Stop the rscmgr server.
stop() ->
    application:stop(rscmgr).