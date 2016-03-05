-module(rlimit).
%% This module implements an RED strategy layered on top of a token bucket
%% for shaping a message flow down to a user defined rate limit. Each message
%% must be assigned a symbolical size in tokens.
%%
%% The rate is measured and limited over short intervals, by default the
%% interval is set to one second.
%%
%% There is a total amount of tokens allowed to be sent or received by
%% the flow during each interval. As the the number of tokens approaches
%% that limit the probability of a message being delayed increases.
%%
%% When the amount of tokens has exceeded the limit all messages are delayed
%% until the start of the next interval.
%%
%% When the number of tokens needed for a message exceeds the number of tokens
%% allowed per interval the receiver or sender must accumulate tokens over
%% multiple intervals.

%% exported functions
-export([new/3, join/1, wait/2, atake/3, take/2,
         get_limit/1, set_limit/2, prev_allowed/1]).

%% private functions
-export([reset/1]).


%% @doc Create a new rate limited flow.
%% @end
-spec new(atom(), pos_integer() | infinity, non_neg_integer()) -> ok.
new(Name, Limit, Interval) ->
    ets:new(Name, [public, named_table, set]),
    {ok, TRef} = timer:apply_interval(Interval, ?MODULE, reset, [Name]),
    ets:insert(Name, [
        {version, 0},
        {limit, Limit},
        {burst, burst(Limit)},
        {fair, fair(Limit)}, %% Should be limit / size(group)
        {tokens, tokens(Limit)},
        {timer, TRef},
        %% How many allowed during the current interval
        {allowed, 0},
        %% How many allowed during the previous interval
        {prev_allowed, 0}]),
    ok.


%% @doc Update a maximum speed.
set_limit(Name, Limit) ->
    ets:insert(Name, [
        {limit, Limit},
        {burst, burst(Limit)},
        {fair, fair(Limit)}, %% Should be limit / size(group)
        {tokens, tokens(Limit)}]),
    ok.


get_limit(Name) ->
    ets:lookup_element(Name, limit, 2).


prev_allowed(Name) ->
    ets:lookup_element(Name, prev_allowed, 2).


%% @private Reset the token counter of a flow.
-spec reset(atom()) -> true.
reset(Name) ->
    %% The version number starts at 0 and restarts when it reaches 16#FFFF.
    %% The version number can be rolling because we only use it as a way to
    %% tell logical intervals apart.
    ets:update_counter(Name, version, {2,1,16#FFFF,0}),
    %% Add Limit number of tokens to the bucket at the start of each interval.
    Limit = ets:lookup_element(Name, limit, 2),
    %% Cap the token counter to Limit multiple a number of intevals to protect
    %% us from huge bursts after idle intervals. The default is to only accumulate
    %% five intervals worth of tokens in the bucket.
    Burst = ets:lookup_element(Name, burst, 2),
    Allowed = ets:lookup_element(Name, allowed, 2),
    ets:insert(Name, {prev_allowed, Allowed}),
    ets:update_counter(Name, allowed, {2,-Allowed}),
    ets:update_counter(Name, tokens, {2,Limit,Burst,Burst}).


%% @doc Add the current process as the member of a flow.
%% The process is removed from the flow when it exists. Exiting is the only
%% way to remove a member of a flow.
%% @end
-spec join(atom()) -> ok.
join(_Name) ->
    ok.

%% @doc Wait until the start of the next interval.
%% @end
-spec wait(atom(), non_neg_integer()) -> non_neg_integer().
wait(Name, _Version) ->
    %% @todo Don't sleep for an arbitrary amount of time.
    timer:sleep(100),
    %% @todo Warn when NewVersion =:= Version
    ets:lookup_element(Name, version, 2).

%% @doc Asynchronously aquire a slot to send or receive N tokens.
%% A user defined message will be sent to the calling process once a slot
%% has been aquired. A linked process is started to perform the operation.
%% @end
-spec atake(non_neg_integer(), term(), atom()) -> pid().
atake(N, Message, Name) ->
    Caller = self(),
    spawn_link(fun() -> take(N, Name), Caller ! Message end).


%% @doc Aquire a slot to send or receive N tokens.
%% @end
-spec take(non_neg_integer(), atom()) -> ok.
take(N, Name) when is_integer(N), N >= 0, is_atom(Name) ->
    Limit = ets:lookup_element(Name, limit, 2),
    Version = ets:lookup_element(Name, version, 2),
%   Before = now(),
    ok = take(N, Name, Limit, Version),
%   After = now(),
%   _Delay = timer:now_diff(After, Before),
    ok.

take(_N, _Name, infinity, _Version) ->
    ok;
take(N, Name, Limit, Version) when N >= 0 ->
    M = slice(N, Limit),
    case ets:update_counter(Name, tokens, [{2,0},{2,-M}]) of
        %% Empty bucket. Wait until the next interval for more tokens.
        [_, Tokens] when Tokens =< 0 ->
            ets:update_counter(Name, tokens, {2,M}),
            NewVersion = wait(Name, Version),
            take(N, Name, Limit, NewVersion);
        [Previous, Tokens] ->
            %% Use difference between the bottom of the bucket and the previous
            %% token count and the packet size to compute the probability of a
            %% message being delayed.
            %% This gives smaller control protocol messages a higher likelyness of
            %% receiving service, avoiding starvation from larger data protocol
            %% messages consuming the rate of entire intervals when a low rate
            %% is used.
            case rand:uniform(Previous) of
                %% Allow message if the random number falls within
                %% the range of tokens left in the bucket after take.
                Rand when Rand =< Tokens ->
                    ets:update_counter(Name, allowed, {2,M}),
                    ok;
                 %% Disallow message if the random number falls within
                 %% the range of the tokens taken from the bucket.
                 Rand when Rand > Tokens ->
                    ets:update_counter(Name, tokens, {2,M}),
                    NewVersion = wait(Name, Version),
                    take(N, Name, Limit, NewVersion)
            end
    end.

%% @private Only take at most Limit tokens during an interval.
%% This ensures that we can send messages that are larger than
%% the Limit/Burst of a flow.
-spec slice(non_neg_integer(), non_neg_integer()) -> non_neg_integer().
slice(Tokens, Limit) -> min(Tokens,  Limit).

%% @private
-spec burst(Limit) -> Burst
    when
        Limit :: non_neg_integer() | infinity,
        Burst :: non_neg_integer() | infinity.
burst(infinity) ->
    infinity;

burst(Limit) ->
    Limit * 5.

%% @private
-spec tokens(Limit) -> Tokens
    when
        Limit  :: non_neg_integer() | infinity,
        Tokens :: non_neg_integer() | infinity.
tokens(infinity) ->
    infinity;

tokens(Limit) ->
    Limit * 5.

%% @private
-spec fair(Limit) -> Fair
    when
        Limit :: non_neg_integer() | infinity,
        Fair  :: non_neg_integer() | infinity.
fair(infinity) ->
    infinity;

fair(Limit) ->
    Limit div 5.
