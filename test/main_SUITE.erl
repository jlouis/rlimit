-module(main_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

suite() ->
    [{timetrap,{seconds,30}}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, _Config) ->
    ok.

init_per_testcase(rlimit, Config) ->
    %% Set up the test rlimit
    rlimit:new(test_flow, 512, 1000),
    rlimit:join(test_flow),
    Config;
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

groups() ->
    [].

all() -> 
    [rlimit].

rlimit() -> [].

rlimit(_Config) -> 
    rlimit:reset(test_flow),
    ok = rlimit:take(512 div 16, test_flow),
    ok = rlimit:take(512, test_flow),
    ok = rlimit:take(512 * 2, test_flow),
    ok = rlimit:take(512 * 6, test_flow),

    Pid = rlimit:atake(512, continue, test_flow),
    receive continue -> ok end,
    false = is_process_alive(Pid),
    ok.

    
