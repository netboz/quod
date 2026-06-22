%%%-------------------------------------------------------------------
%%% quod shared definitions.
%%%-------------------------------------------------------------------

%% Inbound transport events. A transport backend delivers these as plain
%% Erlang messages to the node so the QUIC library stays swappable:
%%
%%   {quod_peer_up,   Peer :: quod_quicer:peer()}
%%   {quod_peer_down, Peer :: quod_quicer:peer(), Reason :: term()}
%%   {quod_message,   Peer :: quod_quicer:peer(),
%%                    Channel :: binary(), Payload :: binary()}
%%
%% These are the four reactions onbrater got from MQTT hooks:
%%   connect/disconnect  -> quod_peer_up / quod_peer_down
%%   subscribe/unsubscribe -> quod_reg:subscribe/unsubscribe on {channel, Name}
%%   message             -> quod_message (routed to channel subscribers)

-define(QUOD_PEER_UP(Peer), {quod_peer_up, Peer}).
-define(QUOD_PEER_DOWN(Peer, Reason), {quod_peer_down, Peer, Reason}).
-define(QUOD_MESSAGE(Peer, Channel, Payload), {quod_message, Peer, Channel, Payload}).
