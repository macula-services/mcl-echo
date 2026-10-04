%%% @doc The echo handler — the hello-world target every Macula SDK's own
%%% quickstart README calls first. Advertised via the standard
%%% `mcl_om_capabilities' path as `Org/echo'; this module is only the
%%% per-call handler.
%%%
%%% THE GUARD IS THE PLATFORM'S NOW (mcl-om#13, mcl_om 0.37.0): the
%%% inbound guard pipeline wraps this handler with a payload-size stage
%%% and a fixed-window rate stage, whose limits this capability declares
%%% in `mcl_echo_service:capabilities/0'. The pipeline counts denials
%%% and publishes one `denials_observed' fact per window with activity.
%%% The handler itself is a pure echo: whatever the platform passes it,
%%% minus the platform-injected `caller'.
-module(mcl_echo_mesh_rpc).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

-spec init([]) -> {ok, undefined}.
init([]) ->
    {ok, undefined}.

-spec handle_request(term(), undefined) -> {reply, term(), undefined}.
handle_request(Payload, State) ->
    {reply, strip_caller(Payload), State}.

%% `caller' is platform metadata about the call, not something the
%% caller themselves put in their own message (it deterministically
%% overwrites any same-named key they supplied — see
%% `macula_station_link:with_caller/2''s own doc) — an echo handler
%% that reflected it back would be showing a caller a field they never
%% actually sent.
strip_caller(Payload) when is_map(Payload) ->
    maps:remove(caller, Payload);
strip_caller(Payload) ->
    Payload.
