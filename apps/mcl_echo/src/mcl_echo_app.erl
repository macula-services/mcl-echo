%% @doc OTP application entry.
%%
%% mcl_om:boot/1 wires the mesh, the realm identity and health, then starts
%% this service. STORELESS as generated: no store_id/0 or data_dir/0 callback on
%% the service module, so no reckon-db is started.
%%
%% To make this a CMD/PRJ service that owns an event store, export store_id/0 and
%% data_dir/0 from mcl_echo_service. mcl_om:boot/1 picks them up and starts
%% the store plus its evoq subscription BEFORE start/1 fires, so you never call
%% reckon_db_sup:start_store/1 yourself.
-module(mcl_echo_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) -> mcl_om:boot(mcl_echo_service).

stop(_State) -> ok.
