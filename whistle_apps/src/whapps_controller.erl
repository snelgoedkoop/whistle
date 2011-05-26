%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2010, James Aimonetti
%%% @doc
%%%
%%% @end
%%% Created :  1 Dec 2010 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(whapps_controller).

-behaviour(gen_server).

%% API
-export([start_link/0, start_app/1, set_amqp_host/1, set_couch_host/1, set_couch_host/3, stop_app/1, running_apps/0]).
-export([get_amqp_host/0, restart_app/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-import(logger, [format_log/3]).

-define(SERVER, ?MODULE). 
-define(MILLISECS_PER_DAY, 1000 * 60 * 60 * 24).
-define(STARTUP_FILE, [code:lib_dir(whistle_apps, priv), "/startup.config"]).

-record(state, {
	  amqp_host = "" :: string()
	 ,apps = [] :: list()
	 }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec(start_app/1 :: (App :: atom()) -> ok).
start_app(App) when is_atom(App) ->
    gen_server:cast(?MODULE, {start_app, App}).

stop_app(App) when is_atom(App) ->
    gen_server:cast(?MODULE, {stop_app, App}).

restart_app(App) when is_atom(App) ->
    gen_server:cast(?MODULE, {restart_app, App}).

set_amqp_host(H) ->
    gen_server:cast(?MODULE, {set_amqp_host, whistle_util:to_list(H)}).

get_amqp_host() ->
    gen_server:call(?MODULE, get_amqp_host).

set_couch_host(H) ->
    set_couch_host(H, "", "").
set_couch_host(H, U, P) ->
    couch_mgr:set_host(whistle_util:to_list(H), whistle_util:to_list(U), whistle_util:to_list(P)).

running_apps() ->
    gen_server:call(?SERVER, running_apps).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok, #state{}, 0}. % causes a timeout immediately, which we can use to do initialization things for state

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(get_amqp_host, _, #state{amqp_host=AmqpHost}=S) ->
    {reply, AmqpHost, S};
handle_call(running_apps, _, #state{apps=As}=S) ->
    {reply, As, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({start_app, App}, #state{apps=As}=State) ->
    add_app(App, As),
    {noreply, State};
handle_cast({stop_app, App}, #state{apps=As}=State) ->
    As1 = rm_app(App, As),
    {noreply, State#state{apps=As1}};
handle_cast({restart_app, App}, #state{apps=As}=State) ->
    As1 = rm_app(App, As),
    whistle_util:reload_app(App),
    add_app(App, As1),
    {noreply, State#state{apps=As1}};
handle_cast({set_amqp_host, H}, #state{apps=As}=State) ->
    lists:foreach(fun(A) ->
			  case erlang:function_exported(A, set_amqp_host, 1) of
			      true -> A:set_amqp_host(H);
			      false -> ok
			  end
		  end, As),
    {noreply, State#state{amqp_host=H}};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(timeout, State) ->
    spawn(fun() ->                  
                  logger:format_log(info, "Consult ~p got ~p", [?STARTUP_FILE, file:consult(?STARTUP_FILE)]),
                  {ok, Startup} = file:consult(?STARTUP_FILE),
                  WhApps = props:get_value(whapps, Startup, []),
                  lists:foreach(fun(WhApp) -> start_app(WhApp) end, WhApps)
          end),
    {noreply, State};
handle_info({add_successful_app, undefined}, State) ->
    format_log(info, "WHAPPS(~p): Failed to add app~n", [self()]),
    {noreply, State};
handle_info({add_successful_app, A}, State) ->
    format_log(info, "WHAPPS(~p): Adding app to ~p~n", [self(), A]),
    {noreply, State#state{apps=[A | State#state.apps]}};
handle_info(_Info, State) ->
    format_log(info, "WHAPPS(~p): Unhandled info ~p~n", [self(), _Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #state{apps=As}) ->
    format_log(info, "WHAPPS(~p): Terminating(~p)~n", [self(), _Reason]),
    lists:foreach(fun(App) -> spawn(fun() -> rm_app(App, []) end) end, As),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec(add_app/2 :: (App :: atom(), As :: list(atom())) -> no_return()).
add_app(App, As) ->
    Srv = self(),
    spawn(fun() ->
		  format_log(info, "APPS(~p): Starting app ~p if not in ~p~n", [self(), App, As]),
		  A = case (not lists:member(App, As)) andalso whistle_apps_sup:start_app(App) of
			  false -> undefined;
			  {ok, _} -> _ = application:start(App), App;
			  {ok, _, _} -> _ = application:start(App), App;
			  _E -> format_log(error, "WHAPPS_CTL(~p): ~p~n", [self(), _E]), undefined
		      end,
		  Srv ! {add_successful_app, A}
	  end).
		  

-spec(rm_app/2 :: (App :: atom(), As :: list(atom())) -> list()).
rm_app(App, As) ->
    format_log(info, "APPS(~p): Stopping app ~p if in ~p~n", [self(), App, As]),
    format_log(info, "APPS(~p): Stopping app_sup: ~p~n", [self(), whistle_apps_sup:stop_app(App)]),
    format_log(info, "APPS(~p): Stopping application: ~p~n", [self(), application:stop(App)]),
    lists:delete(App, As).