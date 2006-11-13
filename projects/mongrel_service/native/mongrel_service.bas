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

#include once "mongrel_service.bi"

namespace mongrel_service
    sub debug(byref message as string)
        dim handle as integer
        
        handle = freefile
        open EXEPATH + "\service.log" for append as #handle
        
        print #handle, message
        
        close #handle
    end sub
    
    constructor SingleMongrel()
        with this.__service
            .name = "single"
            .description = "Mongrel Single Process service"
            
            '# TODO: fix inheritance here
            .onInit = @single_onInit
            .onStart = @single_onStart
            .onStop = @single_onStop
        end with
        
        '# TODO: fix inheritance here
        single_mongrel = @this
    end constructor
    
    destructor SingleMongrel()
        '# TODO: fin inheritance here
    end destructor
    
    function single_onInit(byref self as ServiceProcess) as integer
        dim result as integer
        debug("single_onInit()")
        
        debug("single_onInit() done")
        return result
    end function
    
    sub single_onStart(byref self as ServiceProcess)
        debug("single_onStart()")
        debug("single_onStart() done")
    end sub
    
    sub single_onStop(byref self as ServiceProcess)
        debug("single_onStop()")
        debug("single_onStop() done")
    end sub
    
    sub application()
        dim simple as SingleMongrel
        dim host as ServiceHost
        dim ctrl as ServiceController = ServiceController("Mongrel Win32 Service", "version 0.3.0", _
                                                            "(c) 2006 The Mongrel development team.")
        
        '# add SingleMongrel (service)
        host.Add(simple.__service)
        select case ctrl.RunMode()
            '# call from Service Control Manager (SCM)
            case RunAsService:
                host.Run()
                
            '# call from console, useful for debug purposes.
            case RunAsConsole:
                ctrl.Console()
                
            case else:
                ctrl.Banner()
                print "mongrel_service is not designed to run form commandline,"
                print "please use mongrel_rails service:: commands to create a win32 service."
        end select
    end sub
end namespace

'# MAIN: start native mongrel_service here
mongrel_service.application()
