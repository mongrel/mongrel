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

#define SERVICEFB_INCLUDE_UTILS
#include once "lib/ServiceFB/ServiceFB.bi"
#include once "process.bi"

namespace mongrel_service
    using fb.svc
    using fb.svc.utils
    
    declare function single_onInit(byref as ServiceProcess) as integer
    declare sub single_onStart(byref as ServiceProcess)
    declare sub single_onStop(byref as ServiceProcess)
    
    '# SingleMongrel
    type SingleMongrel
        declare constructor()
        declare destructor()
        
        '# TODO: replace for inheritance here
        'declare function onInit() as integer
        'declare sub onStart()
        'declare sub onStop()
        
        __service       as ServiceProcess
        __child_pid     as uinteger
    end type
    
    '# TODO: replace with inheritance here
    dim shared single_mongrel_ref as SingleMongrel ptr
end namespace
