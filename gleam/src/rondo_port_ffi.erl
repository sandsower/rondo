-module(rondo_port_ffi).
-export([open_port/2, close_port/1, port_info/1, receive_port_message/2, run_shell_command/3]).

open_port(Command, Args) ->
    FullCmd = binary_to_list(Command),
    FullArgs = [binary_to_list(A) || A <- Args],
    try
        Port = erlang:open_port(
            {spawn_executable, FullCmd},
            [{args, FullArgs},
             binary,
             exit_status,
             stderr_to_stdout,
             {line, 65536}]
        ),
        {ok, Port}
    catch
        _:Reason ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

close_port(Port) ->
    try
        erlang:port_close(Port),
        ok
    catch
        _:_ -> ok
    end.

port_info(Port) ->
    case erlang:port_info(Port) of
        undefined -> {error, <<"port closed">>};
        Info -> {ok, Info}
    end.

receive_port_message(Port, TimeoutMs) ->
    receive
        {Port, {data, {eol, Line}}} ->
            {ok, {line, Line}};
        {Port, {data, {noeol, Chunk}}} ->
            {ok, {partial, Chunk}};
        {Port, {exit_status, Code}} ->
            {ok, {exit_status, Code}}
    after TimeoutMs ->
        {error, timeout}
    end.

run_shell_command(Command, WorkDir, TimeoutMs) ->
    Self = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        Port = erlang:open_port(
            {spawn, binary_to_list(Command)},
            [{cd, binary_to_list(WorkDir)}, exit_status, binary, stderr_to_stdout]
        ),
        ExitCode = receive
            {Port, {exit_status, Code}} -> Code
        end,
        Self ! {Ref, ExitCode}
    end),
    receive
        {Ref, Code} -> {ok, Code}
    after TimeoutMs ->
        exit(Pid, kill),
        {error, timeout}
    end.
