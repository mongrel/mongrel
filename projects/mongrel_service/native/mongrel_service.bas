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
'##################################################################

#include once "mongrel_service.bi"

namespace mongrel_service
    constructor SingleMongrel()
    end constructor
    
    destructor SingleMongrel()
    end destructor
    
    function SingleMongrel.onInit(byref self as ServiceProcess) as integer
        dim result as integer
        
        return result
    end function
    
    sub SingleMongrel.onStart(byref self as ServiceProcess)
    end sub
    
    sub SingleMongrel.onStop(byref self as ServiceProcess)
    end sub
end namespace
