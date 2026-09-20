%% @doc The io.macula PQ fleet's station pins: where a terminal caller dials
%% in, and the node id that dial is pinned to.
%%
%% ONE ENTRY PER STATION, AND THE CALLER PICKS. Every terminal tool here used
%% to share a single hardcoded helsinki pin. That is invisible with one caller
%% and wrong the moment several run at once: every one of them arrives at the
%% mesh through the same station, so a fan-out test measures one route six
%% times and reports it as six.
%%
%% THE 11.x DIAL IS PINNED (D5). A seed without its node id is refused, so a
%% station name is only usable together with the id minted for that box, and
%% the two must never drift apart. Both columns come from macula-demo's
%% topologies/eu/stations.csv, which agrees id-for-id with the cutover ledger
%% at infrastructure/scripts/pq-cutover-node-ids.txt.
%%
%% NAMES ARE THE PLAIN FORM. The pq. and pq- prefixed forms still resolve but
%% are dead scaffolding left over from the cutover. Nothing new carries them.
%% All six plain names were confirmed to resolve over IPv6; the fleet is
%% AAAA-only by design, so a host with no IPv6 path reaches none of them.
-module(mcl_echo_stations).

-export([pin/1, names/0, default/0]).

%% Every station serves the mesh on the same port. The admin port differs on
%% two boxes (8444 rather than 8443) but no caller here touches it.
-define(DIAL_PORT, 4433).

-type pin() :: #{host := binary(),
                 port := pos_integer(),
                 expected_node_id := binary()}.
-export_type([pin/0]).

%% @doc Every station a caller may pick, in the order a fan-out should spread
%% across them.
-spec names() -> [atom()].
names() ->
    [helsinki, falkenstein, frankfurt, nuremberg, paris, amsterdam].

%% @doc The station a tool dials when nobody said otherwise.
-spec default() -> atom().
default() -> helsinki.

%% @doc The dial pin for a station, by name. Accepts the atom, or the string
%% or binary a command line hands over.
-spec pin(atom() | binary() | string()) ->
          {ok, pin()} | {error, {unknown_station, binary()}}.
pin(Name) when is_atom(Name)   -> pin_for(Name);
pin(Name) when is_binary(Name) -> pin(unicode:characters_to_list(Name));
pin(Name) when is_list(Name)   -> pin_named(Name, names()).

%% Matched against the known names rather than list_to_existing_atom/1: an
%% unknown name from a command line is an ordinary mistake to report, not a
%% badarg to crash on.
pin_named(Name, []) ->
    {error, {unknown_station, unicode:characters_to_binary(Name)}};
pin_named(Name, [Known | Rest]) ->
    pin_matched(atom_to_list(Known) =:= Name, Known, Name, Rest).

pin_matched(true, Known, _Name, _Rest)  -> pin_for(Known);
pin_matched(false, _Known, Name, Rest)  -> pin_named(Name, Rest).

pin_for(helsinki) ->
    seed(<<"station-fi-helsinki.macula.io">>,
         <<16#004d1f470097ccf8826ce291900e882fdb1f20375e53901facaec0f23eb4efd8:256>>);
pin_for(falkenstein) ->
    seed(<<"station-de-falkenstein.macula.io">>,
         <<16#00df68247d119685f94030afdb203ab7a2a105fb6093a964dbf0509a57e86435:256>>);
pin_for(frankfurt) ->
    seed(<<"station-de-frankfurt.macula.io">>,
         <<16#00cd0008ec2e72b6572b7bf6fc8b048d7fe83993faf1fc544370f2bc1eb71f85:256>>);
pin_for(nuremberg) ->
    seed(<<"station-de-nuremberg.macula.io">>,
         <<16#00a9b4143e24ae42e5a058dd28c9aab585636acd17012cc4d418a3bb5413af22:256>>);
pin_for(paris) ->
    seed(<<"station-fr-paris.macula.io">>,
         <<16#0063acc4a5af409ca6b15041975128d389222c48366fb3a1dfb948da01f7ca94:256>>);
pin_for(amsterdam) ->
    seed(<<"station-nl-ams.macula.io">>,
         <<16#000370eebafa9a89a44c9448b4796788fbff1885abd67c80d681d28cebb04b0c:256>>).

seed(Host, NodeId) ->
    {ok, #{host => Host, port => ?DIAL_PORT, expected_node_id => NodeId}}.
