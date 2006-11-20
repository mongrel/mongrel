'##################################################################
'# 
'# mongrel_service: Win32 native implementation for mongrel
'#                  (using ServiceFB and FreeBASIC)
'# 
'# Copyright (c) 2006 Multimedia systems
'# (c) and code by Luis Lavena
'# Portions (c) Louis Thomas
'# 
'#  mongrel_service (native) and mongrel_service gem_pluing are licensed
'#  in the same terms as mongrel, please review the mongrel license at
'#  http://mongrel.rubyforge.org/license.html
'#  
'#  Louis Thomas licensing:
'#  http://www.latenighthacking.com/projects/lnhfslicense.html
'#  
'##################################################################

'##################################################################
'# Requirements:
'# - FreeBASIC 0.17, Win32 CVS Build (as for November 09, 2006).
'# 
'# SendSignal from Louis Thomas is included in the repository
'# in a pre-compiled form (also included the modified source code).
'# The C code is ugly as hell, but get the job done.
'#
'# Compile instructions:
'# cl /c native\send_signal.cpp /Fonative\send_signal.obj
'# lib native\send_signal.obj /out:lib\libsend_signal.a
'# 
'##################################################################

#include once "process.bi"

private sub _dprint(byref message as string)
    dim handle as integer
    
    handle = freefile
    open EXEPATH + "\process.log" for append as #handle
    
    print #handle, message
    
    close #handle
end sub

function spawn(byref cmdLine as string) as uinteger
    dim result as uinteger
    dim as HANDLE StdInRd, StdOutRd, StdErrRd
    dim as HANDLE StdInWr, StdOutWr, StdErrWr
    
    dim pi as PROCESS_INFORMATION
    dim si as STARTUPINFO
    dim sa as SECURITY_ATTRIBUTES
    
    '// INIT
    with sa
        .nLength = sizeof( sa )
        .bInheritHandle = TRUE
        .lpSecurityDescriptor = NULL
    end with
    
    '# Create the pipes
    '# StdIn
    if (CreatePipe( @StdInRd, @StdInWr, @sa, 0 ) = 0) then
        _dprint("Error creating StdIn pipes.")
        end 0
    end if
    
    '# StdOut
    if (CreatePipe( @StdOutRd, @StdOutWr, @sa, 0 ) = 0) then
        _dprint("Error creating StdOut pipes.")
        end 0
    end if
    
    '# StdErr
    if (CreatePipe( @StdErrRd, @StdErrWr, @sa, 0 ) = 0) then
        _dprint("Error creating StdErr pipes.")
        end 0
    end if

    '# Ensure the handles to the pipe are not inherited.
    SetHandleInformation( StdInWr, HANDLE_FLAG_INHERIT, 0)
    SetHandleInformation( StdOutRd, HANDLE_FLAG_INHERIT, 0)
    SetHandleInformation( StdErrRd, HANDLE_FLAG_INHERIT, 0)

    '# Set the Std* handles ;-)
    with si
        .cb = sizeof( si )
        .hStdError = StdErrWr
        .hStdOutput = StdOutWr
        .hStdInput = StdInRd
        .dwFlags = STARTF_USESTDHANDLES
    end with
    '// INIT
    
    if (CreateProcess(NULL, _
                        StrPtr(cmdLine), _
                        NULL, _
                        NULL, _
                        TRUE, _
                        CREATE_NEW_PROCESS_GROUP, _                 '// CREATE_NEW_PROCESS_GROUP or DETACHED_PROCESS, _
                        NULL, _
                        NULL, _
                        @si, _
                        @pi) = 0) then
        _dprint("Error in CreateProcess (" + str(GetLastError()))
    else
        CloseHandle(pi.hProcess)
        CloseHandle(pi.hThread)
        result = pi.dwProcessId
        _dprint("Success in CreateProcess, PID " + str(result))
    end if
    
    return result
end function

private function tricky_console_handler(byval dwCtrlType as DWORD) as BOOL
    _dprint("tricky_console_handler got dwCtrlType = " + str(dwCtrlType))
    return (dwCtrlType = CTRL_C_EVENT)
end function

public function terminate_spawned(byval pid as uinteger) as BOOL
    dim result as BOOL
    
    result = FALSE
    
    '# hook custom console_handler
    SetConsoleCtrlHandler(@tricky_console_handler, TRUE)
    
    '# fire CTRL_C_EVENT to all the children 
    if not (GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0) = 0) then
        '# it worked
        _dprint("GenerateConsoleCtrlEvent worked.")
        result = TRUE
    else
        _dprint("GenerateConsoleCtrlEvent failed, error " + str(GetLastError()))
    end if
    
    '# we should check here if the pid no longer exist.
    '# ...
    
    '# remove our custom console handler
    SetConsoleCtrlHandler(@tricky_console_handler, FALSE)
    
    return result
end function
