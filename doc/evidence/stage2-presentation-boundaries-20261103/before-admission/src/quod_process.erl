-module(quod_process).
-moduledoc """
Small process-ownership helpers shared across bounded workers.
""".

-export([kill_when_owner_dies/2]).

-doc """
Start a one-shot directional watcher. If `Owner` dies first, `Worker` is
force-killed even when it is stuck outside its receive loop. If `Worker` ends
first, the owner monitor is removed. The watcher never links the two domains.
""".
-spec kill_when_owner_dies(pid(), pid()) -> pid().
kill_when_owner_dies(Owner, Worker)
  when is_pid(Owner), is_pid(Worker) ->
    spawn(
      fun() ->
          OwnerRef = monitor(process, Owner),
          WorkerRef = monitor(process, Worker),
          receive
              {'DOWN', OwnerRef, process, Owner, _Reason} ->
                  exit(Worker, kill);
              {'DOWN', WorkerRef, process, Worker, _Reason} ->
                  demonitor(OwnerRef, [flush]),
                  ok
          end
      end).
