"""Optional exact Windows identity/liveness query; never CPU/progress inference."""
import ctypes as ct
from ctypes import wintypes as wt
import os


def query_windows(pid, expected=None):
    if os.name != 'nt':
        return None, 'UNKNOWN'
    api = ct.WinDLL('kernel32', use_last_error=True)
    api.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
    api.OpenProcess.restype = wt.HANDLE
    api.GetProcessTimes.argtypes = [wt.HANDLE] + [ct.POINTER(wt.FILETIME)] * 4
    api.GetProcessTimes.restype = wt.BOOL
    api.WaitForSingleObject.argtypes = [wt.HANDLE, wt.DWORD]
    api.WaitForSingleObject.restype = wt.DWORD
    api.CloseHandle.argtypes = [wt.HANDLE]
    handle = api.OpenProcess(0x1000 | 0x100000, False, pid)
    if not handle:
        return None, 'PROCESS_EXITED' if ct.get_last_error() == 87 and expected else 'UNKNOWN'
    try:
        fields = [wt.FILETIME() for _ in range(4)]
        if not api.GetProcessTimes(handle, *[ct.byref(field) for field in fields]):
            return None, 'UNKNOWN'
        creation = str((fields[0].dwHighDateTime << 32) | fields[0].dwLowDateTime)
        identity = {'kind': 'WINDOWS_FILETIME', 'value': creation}
        if expected is not None and expected != identity:
            return identity, 'PROCESS_EXITED'  # Original identity is absent; PID may be reused.
        result = api.WaitForSingleObject(handle, 0)
        return identity, 'ALIVE' if result == 258 else 'PROCESS_EXITED' if result == 0 else 'UNKNOWN'
    finally:
        api.CloseHandle(handle)


def own_identity():
    identity, _ = query_windows(os.getpid())
    return (os.getpid(), identity) if identity is not None else (None, None)
