// C interface of an ElmLean app in native mode (see framework/lean/ElmLean/Native.lean).
// Every string is JSON; every returned string is malloc'ed and owned by the caller (free it).
#pragma once

/// Start Lean's runtime and the app (module initializers, task manager). Call once, on the main thread.
/// Returns 0 on success; on failure, prints Lean's error to stderr and returns 1.
int elmlean_boot(void);
/// The first view (runs the app's boot commands).
char *elmlean_start(void);
/// One user event: {"seq":n,"path":[…],"event":{…}}.
char *elmlean_event(const char *json);
/// A system event from the shell ({"scene":…}, {"captured":…}, {"bgtask":…} or {"bgtaskExpired":…}), as the
/// app's `system` maps it.
char *elmlean_system(const char *json);
/// Apply every queued host answer; the current view.
char *elmlean_drain(void);
/// The shell's answer to a capability request: {"id":n,"result":…}.
void elmlean_cap_result(const char *json);
/// Block the calling thread until a host answer or a capability request is queued.
void elmlean_wait(void);
