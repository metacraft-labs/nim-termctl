/* Internal Win32 state only. Never owns/copies/releases a Nim closure. The
 * installing Nim owner retains the typed closure until destroy has drained
 * all real native borrows. Handler execution allocates no descriptor/node. */
#include "ctrl_owner.h"
struct TcCtrlOwner {
  void *code, *environment;
  TcCtrlInvoke invoke;
  DWORD owner_thread;
  HANDLE signal, drained;
  uint64_t generation;
  unsigned active;
  int retired, received;
};
static SRWLOCK control_lock = SRWLOCK_INIT;
static TcCtrlOwner *current;
static uint64_t next_generation;
static int handler_registered;
static int registration_transition;

static BOOL WINAPI control_handler(DWORD kind) {
  TcCtrlOwner *borrow;
  if (kind != CTRL_C_EVENT && kind != CTRL_BREAK_EVENT &&
      kind != CTRL_CLOSE_EVENT && kind != CTRL_LOGOFF_EVENT &&
      kind != CTRL_SHUTDOWN_EVENT) return FALSE;
  AcquireSRWLockExclusive(&control_lock);
  borrow = current;
  if (!borrow || borrow->retired) {
    ReleaseSRWLockExclusive(&control_lock);
    return FALSE;
  }
  if (borrow->active++ == 0) ResetEvent(borrow->drained);
  borrow->received = 1;
  SetEvent(borrow->signal);
  ReleaseSRWLockExclusive(&control_lock);
  if (borrow->code) borrow->invoke(borrow, borrow->code, borrow->environment);
  AcquireSRWLockExclusive(&control_lock);
  if (--borrow->active == 0) SetEvent(borrow->drained);
  ReleaseSRWLockExclusive(&control_lock);
  return TRUE;
}
TcCtrlOwner *tc_ctrl_prepare(void *code, void *environment, TcCtrlInvoke invoke) {
  TcCtrlOwner *owner = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*owner));
  if (!owner) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return NULL; }
  owner->owner_thread = GetCurrentThreadId();
  owner->code = code; owner->environment = environment; owner->invoke = invoke;
  owner->retired = 1;
  owner->signal = CreateEventW(NULL, TRUE, FALSE, NULL);
  owner->drained = CreateEventW(NULL, TRUE, TRUE, NULL);
  if (!owner->signal || !owner->drained) {
    DWORD error = GetLastError();
    if (owner->signal) CloseHandle(owner->signal);
    if (owner->drained) CloseHandle(owner->drained);
    HeapFree(GetProcessHeap(), 0, owner); SetLastError(error); return NULL;
  }
  return owner;
}
int tc_ctrl_publish(TcCtrlOwner *owner) {
  DWORD error = ERROR_SUCCESS; int needs_registration = 0;
  AcquireSRWLockExclusive(&control_lock);
  if (!owner || !owner->retired || owner->active || owner->generation) error = ERROR_INVALID_PARAMETER;
  else if (registration_transition) error = ERROR_BUSY;
  else if (next_generation == UINT64_MAX) error = ERROR_ARITHMETIC_OVERFLOW;
  else if (!handler_registered) { registration_transition = 1; needs_registration = 1; }
  if (error) { ReleaseSRWLockExclusive(&control_lock); SetLastError(error); return 0; }
  if (needs_registration) {
    ReleaseSRWLockExclusive(&control_lock);
    if (!SetConsoleCtrlHandler(control_handler, TRUE)) error = GetLastError();
    AcquireSRWLockExclusive(&control_lock);
    registration_transition = 0;
    if (!error) handler_registered = 1;
  }
  if (!error) {
    if (current) { current->retired = 1; SetEvent(current->signal); }
    owner->generation = ++next_generation; owner->retired = 0; current = owner;
  }
  ReleaseSRWLockExclusive(&control_lock); SetLastError(error);
  return error == ERROR_SUCCESS;
}
/* Detach raw state before unregistering, outside our lock. Never wait for
 * an OS operation while holding the lock needed by an in-flight handler.
 * A racing publication receives ERROR_BUSY before it changes any state.
 * A failed OS removal leaves a static handler that returns FALSE and can
 * never dereference the retired Nim environment. */
static int retire_owner(TcCtrlOwner *owner, int use_current) {
  int remove = 0, ok = 1; DWORD error = ERROR_SUCCESS;
  AcquireSRWLockExclusive(&control_lock);
  if (use_current) owner = current;
  if (owner && current == owner) {
    current = NULL;
    if (handler_registered && !registration_transition) {
      registration_transition = 1; remove = 1;
    }
  }
  if (owner) { owner->retired = 1; SetEvent(owner->signal); }
  ReleaseSRWLockExclusive(&control_lock);
  if (remove) {
    ok = SetConsoleCtrlHandler(control_handler, FALSE) != 0;
    if (!ok) error = GetLastError();
    AcquireSRWLockExclusive(&control_lock);
    if (ok) handler_registered = 0;
    registration_transition = 0;
    ReleaseSRWLockExclusive(&control_lock);
  }
  SetLastError(error); return ok;
}
int tc_ctrl_retire(TcCtrlOwner *owner) { return retire_owner(owner, 0); }
int tc_ctrl_retire_current(void) { return retire_owner(NULL, 1); }
DWORD tc_ctrl_owner_thread(TcCtrlOwner *owner) { return owner->owner_thread; }
int tc_ctrl_is_retired(TcCtrlOwner *owner) {
  int value;
  AcquireSRWLockExclusive(&control_lock); value = owner->retired;
  ReleaseSRWLockExclusive(&control_lock); return value;
}
int tc_ctrl_destroy(TcCtrlOwner **slot) {
  TcCtrlOwner *owner = *slot;
  int ok;
  if (!owner) return 1;
  if (owner->owner_thread != GetCurrentThreadId()) { SetLastError(ERROR_INVALID_THREAD_ID); return 0; }
  ok = tc_ctrl_retire(owner);
  /* Retirement blocks new borrows, and every prior borrow owns this stable
   * descriptor until it decrements active and signals drained under lock. */
  if (WaitForSingleObject(owner->drained, INFINITE) != WAIT_OBJECT_0) return 0;
  AcquireSRWLockExclusive(&control_lock);
  if (!owner->retired || owner->active) {
    ReleaseSRWLockExclusive(&control_lock); SetLastError(ERROR_BUSY); return 0;
  }
  /* Acquiring the lock also joins the handler's final SetEvent and its
   * last descriptor access, not merely the kernel wakeup of this waiter. */
  CloseHandle(owner->signal); CloseHandle(owner->drained);
  HeapFree(GetProcessHeap(), 0, owner); *slot = NULL;
  ReleaseSRWLockExclusive(&control_lock);
  return ok;
}
HANDLE tc_ctrl_borrow_event(void) {
  HANDLE event;
  AcquireSRWLockExclusive(&control_lock); event = current ? current->signal : NULL;
  ReleaseSRWLockExclusive(&control_lock); return event;
}
int tc_ctrl_wait(DWORD timeout) {
  HANDLE lease = NULL; uint64_t generation = 0; DWORD status; int valid;
  AcquireSRWLockExclusive(&control_lock);
  if (current && !current->retired) {
    if (DuplicateHandle(GetCurrentProcess(), current->signal, GetCurrentProcess(), &lease, 0, FALSE, DUPLICATE_SAME_ACCESS)) generation = current->generation;
  }
  ReleaseSRWLockExclusive(&control_lock);
  if (!lease) return 0;
  status = WaitForSingleObject(lease, timeout); CloseHandle(lease);
  AcquireSRWLockExclusive(&control_lock);
  valid = status == WAIT_OBJECT_0 && current && !current->retired && current->generation == generation && current->received;
  ReleaseSRWLockExclusive(&control_lock); return valid;
}
int tc_ctrl_received(void) {
  int received;
  AcquireSRWLockExclusive(&control_lock); received = current && current->received;
  ReleaseSRWLockExclusive(&control_lock); return received;
}
int tc_ctrl_reset(void) {
  int ok = 1;
  AcquireSRWLockExclusive(&control_lock);
  if (current) { current->received = 0; ok = ResetEvent(current->signal) != 0; }
  ReleaseSRWLockExclusive(&control_lock); return ok;
}
