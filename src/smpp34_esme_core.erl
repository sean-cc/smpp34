-module(smpp34_esme_core).
-behaviour(gen_fsm).

-include_lib("smpp34pdu/include/smpp34pdu.hrl").
-include("util.hrl").

-define(SOCK_OPTS, [binary, {packet, raw}, {active, once}]).

-record(st, {owner, mref,
			 tx, tx_mref, 
		     rx, rx_mref,
			 params, socket,
			 close_reason}).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/3, stop/1, send/2, send/3]).

%% ------------------------------------------------------------------
%% gen_fsm Function Exports
%% ------------------------------------------------------------------

-export([init/1, open/2, closed/2, open/3, closed/3, handle_event/3, handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Owner, Host, Port) ->
  gen_fsm:start(?MODULE, [Owner, Host, Port], []).

stop(Pid) ->
	gen_fsm:sync_send_all_state_event(Pid, close).

send(Pid, Body) ->
	send(Pid, ?ESME_ROK, Body).

send(Pid, Status, Body) ->
	gen_fsm:sync_send_event(Pid, {tx, Status, Body}).

%% ------------------------------------------------------------------
%% gen_fsm Function Definitions
%% ------------------------------------------------------------------

init([Owner, Host, Port]) ->
	process_flag(trap_exit, true),
	Mref = erlang:monitor(process, Owner),
	St = #st{owner=Owner, mref=Mref},
	case gen_tcp:connect(Host, Port, ?SOCK_OPTS) of
		{error, Reason} ->
			{stop, Reason};
		{ok, Socket} ->
			St0 = St#st{socket=Socket},

			case smpp34_tx_sup:start_child(Socket) of
				{error, Reason} ->
					{stop, Reason};
				{ok, Tx} ->
					St1 = St0#st{tx=Tx},

					TxMref = erlang:monitor(process, Tx),
					St2 = St1#st{tx_mref=TxMref},

					case smpp34_rx_sup:start_child(Tx, Socket) of
						{error, Reason} ->
							{stop, Reason};
						{ok, Rx} ->
							St3 = St2#st{rx=Rx},

							RxMref = erlang:monitor(process, Rx),
							St4 = St3#st{rx_mref=RxMref},

							case smpp34_rx:controll_socket(Rx, Socket) of
								{error, Reason} ->
									{stop, Reason};
								ok ->
									{ok, open, St4#st{params={Host, Port}}}
							end
					end
			end
	end.

open(_Event, St) ->
  {next_state, open, St}.
 
closed(_Event, St) ->
  {next_state, closed, St}.


open({tx, Status, Body}, _From, #st{tx=Tx}=St) ->
  {reply, catch(smpp34_tx:send(Tx, Status, Body)), open, St};
open(_Event, _From, St) ->
  {reply, {error, _Event}, open, St}.

closed(_Event, _From, #st{close_reason=undefined}=St) ->
  {reply, {error, closed}, closed, St};
closed(_Event, _From, #st{close_reason={error, R}}=St) ->
  {reply, {error, R}, closed, St};
closed(_Event, _From, #st{close_reason=R}=St) ->
  {reply, {error, R}, closed, St}.

handle_event(_Event, StateName, St) ->
  {next_state, StateName, St}.

handle_sync_event(close, _From, closed, St) ->
	{reply, {error, closed}, closed, St};
handle_sync_event(close, _From, _, St) ->
	do_stop(close, St),
	{reply, ok, closed, St};
handle_sync_event(_Event, _From, StateName, St) ->
  {reply, ok, StateName, St}.

handle_info({Rx, Pdu}, StateName, #st{rx=Rx, owner=Owner}=St) ->
  Owner ! {esme_data, self(), Pdu},
  {next_state, StateName, St};
handle_info(#'DOWN'{reason=normal}, _, St) ->
  {next_state, closed, St};
handle_info(#'DOWN'{ref=MRef, reason=R}, _, #st{mref=MRef}=St) ->
  {stop, R, St};
handle_info(#'DOWN'{ref=MRef, reason=R}, _, #st{tx_mref=MRef}=St) ->
  do_stop(tx, St),
  {next_state, closed, St#st{close_reason=R}};
handle_info(#'DOWN'{ref=MRef, reason=R}, _, #st{rx_mref=MRef}=St) ->
  do_stop(rx, St),
  {next_state, closed, St#st{close_reason=R}};
handle_info(_Info, StateName, St) ->
  {next_state, StateName, St}.

terminate(_, _, _) ->
 ok.

code_change(_OldVsn, StateName, St, _Extra) ->
  {ok, StateName, St}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

do_stop(close, #st{tx=Tx, rx=Rx}) ->
	catch(smpp34_tx:stop(Tx)),
	catch(smpp34_rx:stop(Rx));
do_stop(rx, #st{tx=Tx}) ->
	catch(smpp34_tx:stop(Tx));
do_stop(tx, #st{rx=Rx}) ->
	catch(smpp34_rx:stop(Rx)).
