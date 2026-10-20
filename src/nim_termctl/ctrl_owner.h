#ifndef NIM_TERMCTL_CTRL_OWNER_H
#define NIM_TERMCTL_CTRL_OWNER_H
#include <windows.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct TcCtrlOwner TcCtrlOwner;
typedef void (__cdecl *TcCtrlInvoke)(TcCtrlOwner *, void *, void *);
TcCtrlOwner *tc_ctrl_prepare(void *, void *, TcCtrlInvoke);
int tc_ctrl_publish(TcCtrlOwner *);
int tc_ctrl_retire(TcCtrlOwner *);
int tc_ctrl_retire_current(void);
int tc_ctrl_destroy(TcCtrlOwner **);
DWORD tc_ctrl_owner_thread(TcCtrlOwner *);
int tc_ctrl_is_retired(TcCtrlOwner *);
HANDLE tc_ctrl_borrow_event(void);
int tc_ctrl_wait(DWORD);
int tc_ctrl_received(void);
int tc_ctrl_reset(void);
#ifdef __cplusplus
}
#endif
#endif
