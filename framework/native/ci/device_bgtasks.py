"""lldb's half of framework/native/ci/device-run: iOS launches and expires native-demo's background tasks.

  python3 device_bgtasks.py <udid> <pid> <identifier prefix> > tasks.lldb; xcrun lldb --batch -s tasks.lldb

Prints lldb commands. Attached to the running app, lldb asks BGTaskScheduler, as Apple's documentation of
background tasks says to test them from the debugger, to launch the refresh task, lets the app run 5 s (the
shell completes it), then to launch the processing task, lets the app run 0.5 s (the shell takes the launch
and sets the task's expiration handler), and asks iOS to expire it (`_simulateLaunchForTaskWithIdentifier:`,
`_simulateExpirationForTaskWithIdentifier:`). Both tasks must have been scheduled first (the selftest does).
An expression needs the app stopped, so `run_for` continues it and stops it again; it detaches at the end and
the app keeps running. `wait_stopped` waits for the attach to stop the app: minutes when lldb has no copy of
the device's shared cache and reads it from the device.

Seen with lldb 2103 (Xcode 27.2) on iOS 27.2: this ran through once and both tasks answered; once lldb
crashed while `run_for` had the app running; once the first expression failed (`NSClassFromString`
undeclared), hence the `@import Foundation`. A breakpoint on BGTask's own methods never resolved (the
device's frameworks have no symbols here).
"""
import sys
import time

SCHEDULER = '(id)[NSClassFromString(@"BGTaskScheduler") sharedScheduler]'


def wait_stopped(debugger, seconds=300):
    import lldb
    process = debugger.GetSelectedTarget().GetProcess()
    deadline = time.time() + seconds
    while process.IsValid() and process.GetState() != lldb.eStateStopped and time.time() < deadline:
        debugger.GetCommandInterpreter().HandleCommand("process status", lldb.SBCommandReturnObject())
        time.sleep(0.5)
    state = lldb.SBDebugger.StateAsCString(process.GetState()) if process.IsValid() else "not attached"
    print(f"device_bgtasks: the app is {state}", flush=True)


def run_for(debugger, seconds):
    """Lets the stopped app run for a while, then stops it again (an expression needs it stopped)."""
    import lldb
    process = debugger.GetSelectedTarget().GetProcess()
    debugger.SetAsync(True)
    process.Continue()
    time.sleep(seconds)
    process.Stop()
    for _ in range(100):
        if process.GetState() == lldb.eStateStopped:
            break
        time.sleep(0.1)
    debugger.SetAsync(False)
    print(f"device_bgtasks: ran {seconds} s", flush=True)


def commands(udid, pid, prefix):
    def simulate(what, task):
        return f'expression -l objc -- (void)[{SCHEDULER} _simulate{what}ForTaskWithIdentifier:@"{prefix}{task}"]'
    return [f"device select {udid}", f"device process attach -p {pid}", f"command script import {__file__}",
            "script device_bgtasks.wait_stopped(lldb.debugger)", "thread select 1",
            "expression -l objc -- @import Foundation",
            simulate("Launch", "refresh"), "script device_bgtasks.run_for(lldb.debugger, 5)",
            simulate("Launch", "processing"), "script device_bgtasks.run_for(lldb.debugger, 0.5)",
            simulate("Expiration", "processing"), "process detach"]


if __name__ == "__main__":
    print("\n".join(commands(*sys.argv[1:4])))
