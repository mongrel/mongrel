
# Standard libraries
require 'socket'
require 'tempfile'
require 'yaml'
require 'time'
require 'etc'
require 'uri'
require 'stringio'

# Compiled Mongrel extension
require 'http11'

# Gem conditional loader
require 'mongrel/gems'
Mongrel::Gems.require 'cgi_multipart_eof_fix'
Mongrel::Gems.require 'fastthread'
require 'thread'

# Ruby Mongrel
require 'mongrel/cgi'
require 'mongrel/handlers'
require 'mongrel/command'
require 'mongrel/tcphack'
require 'mongrel/configurator'
require 'mongrel/uri_classifier'
require 'mongrel/const'
require 'mongrel/http_request'
require 'mongrel/header_out'
require 'mongrel/http_response'

# Mongrel module containing all of the classes (include C extensions) for running
# a Mongrel web server.  It contains a minimalist HTTP server with just enough
# functionality to service web application requests fast as possible.
module Mongrel

  # Used to stop the HttpServer via Thread.raise.
  class StopServer < Exception; end

  # Thrown at a thread when it is timed out.
  class TimeoutError < Exception; end

  class UriChangeEvent < Exception; end
  
  class MaxChildrenCapicityReached < Exception; end

  class CouldntConnect < Exception; end
  
  # A Hash with one extra parameter for the HTTP body, used internally.
  class HttpParams < Hash
    attr_accessor :http_body
  end

  class Server
    attr_accessor :classifier
    attr_reader   :acceptor
    attr_reader   :domain
    attr_reader   :host
    attr_reader   :port
    attr_reader   :timeout

    # Creates a working server on host:port (strange things happen if port isn't a Number).
    # Use HttpServer::run to start the server and HttpServer.acceptor.join to 
    # join the thread that's processing incoming requests on the socket.
    #
    # The num_processors optional argument is the maximum number of concurrent
    # processors to accept, anything over this is closed immediately to maintain
    # server processing performance.  This may seem mean but it is the most efficient
    # way to deal with overload.  Other schemes involve still parsing the client's request
    # which defeats the point of an overload handling system.
    # 
    # The throttle parameter is a sleep timeout (in hundredths of a second) that is placed between 
    # socket.accept calls in order to give the server a cheap throttle time.  It defaults to 0 and
    # actually if it is 0 then the sleep is not done at all.
    def initialize(throttle, timeout)
      @classifier = URIClassifier.new
      @throttle = throttle || 0
      @timeout = timeout || 60
    end

    # Does the majority of the IO processing.  It has been written in Ruby using
    # about 7 different IO processing strategies and no matter how it's done 
    # the performance just does not improve.  It is currently carefully constructed
    # to make sure that it gets the best possible performance, but anyone who
    # thinks they can make it faster is more than welcome to take a crack at it.
    def process_client(client)
      begin
        parser = HttpParser.new
        params = HttpParams.new
        request = nil
        data = client.readpartial(Const::CHUNK_SIZE)
        nparsed = 0

        # Assumption: nparsed will always be less since data will get filled with more
        # after each parsing.  If it doesn't get more then there was a problem
        # with the read operation on the client socket.  Effect is to stop processing when the
        # socket can't fill the buffer for further parsing.
        while nparsed < data.length
          nparsed = parser.execute(params, data, nparsed)

          if parser.finished?
            if not params[Const::REQUEST_PATH]
              # it might be a dumbass full host request header
              uri = URI.parse(params[Const::REQUEST_URI])
              params[Const::REQUEST_PATH] = uri.path
            end

            raise "No REQUEST PATH" if not params[Const::REQUEST_PATH]

            script_name, path_info, handlers = @classifier.resolve(params[Const::REQUEST_PATH])

            if handlers
              params[Const::PATH_INFO] = path_info
              params[Const::SCRIPT_NAME] = script_name

              # From http://www.ietf.org/rfc/rfc3875 :
              # "Script authors should be aware that the REMOTE_ADDR and REMOTE_HOST
              #  meta-variables (see sections 4.1.8 and 4.1.9) may not identify the
              #  ultimate source of the request.  They identify the client for the
              #  immediate request to the server; that client may be a proxy, gateway,
              #  or other intermediary acting on behalf of the actual source client."
              params[Const::REMOTE_ADDR] = client.peeraddr.last

              # select handlers that want more detailed request notification
              notifiers = handlers.select { |h| h.request_notify }
              request = HttpRequest.new(params, client, notifiers)

              # in the case of large file uploads the user could close the socket, so skip those requests
              break if request.body == nil  # nil signals from HttpRequest::initialize that the request was aborted

              # request is good so far, continue processing the response
              response = HttpResponse.new(client)

              # Process each handler in registered order until we run out or one finalizes the response.
              handlers.each do |handler|
                handler.process(request, response)
                break if response.done or client.closed?
              end

              # And finally, if nobody closed the response off, we finalize it.
              unless response.done or client.closed? 
                response.finished
              end
            else
              # Didn't find it, return a stock 404 response.
              client.write(Const::ERROR_404_RESPONSE)
            end

            break #done
          else
            # Parser is not done, queue up more data to read and continue parsing
            chunk = client.readpartial(Const::CHUNK_SIZE)
            break if !chunk or chunk.length == 0  # read failed, stop processing

            data << chunk
            if data.length >= Const::MAX_HEADER
              raise HttpParserError.new("HEADER is longer than allowed, aborting client early.")
            end
          end
        end
      rescue EOFError,Errno::ECONNRESET,Errno::EPIPE,Errno::EINVAL,Errno::EBADF
        client.close rescue nil
      rescue HttpParserError => e
        STDERR.puts "#{Time.now}: HTTP parse error, malformed request (#{params[Const::HTTP_X_FORWARDED_FOR] || client.peeraddr.last}): #{e.inspect}"
        STDERR.puts "#{Time.now}: REQUEST DATA: #{data.inspect}\n---\nPARAMS: #{params.inspect}\n---\n"
      rescue Errno::EMFILE
        reap_dead_workers('too many files')
      rescue Object => e
        STDERR.puts "#{Time.now}: Read error: #{e.inspect}"
        STDERR.puts e.backtrace.join("\n")
      ensure
        begin
          client.close
        rescue IOError
          # Already closed
        rescue Object => e
          STDERR.puts "#{Time.now}: Client error: #{e.inspect}"
          STDERR.puts e.backtrace.join("\n")
        end
        request.body.delete if request and request.body.class == Tempfile
      end
    end

    def reap_dead_workers(reason=nil)
      raise RuntimeError, "This method must be overridden in a derived class"
    end

    def configure_socket_options
      case RUBY_PLATFORM
      when /linux/
        # 9 is currently TCP_DEFER_ACCEPT
        $tcp_defer_accept_opts = [Socket::SOL_TCP, 9, 1]
        $tcp_cork_opts = [Socket::SOL_TCP, 3, 1]
      when /freebsd(([1-4]\..{1,2})|5\.[0-4])/
        # Do nothing, just closing a bug when freebsd <= 5.4
      when /freebsd/
        # Use the HTTP accept filter if available.
        # The struct made by pack() is defined in /usr/include/sys/socket.h as accept_filter_arg
        unless `/sbin/sysctl -nq net.inet.accf.http`.empty?
          $tcp_defer_accept_opts = [Socket::SOL_SOCKET, Socket::SO_ACCEPTFILTER, ['httpready', nil].pack('a16a240')]
        end
      end
    end
    
    # Runs the thing.  It returns the thread used so you can "join" it.  You can also
    # access the HttpServer::acceptor attribute to get the thread later.
    def run
      raise RuntimeError, "This method must be overridden in a derived class"
    end

    # Simply registers a handler with the internal URIClassifier.  When the URI is
    # found in the prefix of a request then your handler's HttpHandler::process method
    # is called.  See Mongrel::URIClassifier#register for more information.
    #
    # If you set in_front=true then the passed in handler will be put in the front of the list
    # for that particular URI. Otherwise it's placed at the end of the list.
    def register(uri, handler, in_front=false)
      begin
        @classifier.register(uri, [handler])
      rescue URIClassifier::RegistrationError
        handlers = @classifier.resolve(uri)[2]
        method_name = in_front ? 'unshift' : 'push'
        handlers.send(method_name, handler)
      end
      handler.listener = self
    end

    # Removes any handlers registered at the given URI.  See Mongrel::URIClassifier#unregister
    # for more information.  Remember this removes them *all* so the entire
    # processing chain goes away.
    def unregister(uri)
      @classifier.unregister(uri)
    end

    # Stops the acceptor thread and then causes the worker threads to finish
    # off the request queue before finally exiting.
    def stop(synchronous=false)
      unless @acceptor.nil?
        @acceptor.raise(StopServer.new)

        if synchronous
          sleep(0.5) while @acceptor.alive?
        end
      end
    end
  end

  # This is the main driver of Mongrel, while the Mongrel::HttpParser and Mongrel::URIClassifier
  # make up the majority of how the server functions.  It's a very simple class that just
  # has a thread accepting connections and a simple HttpServer.process_client function
  # to do the heavy lifting with the IO and Ruby.  
  #
  # You use it by doing the following:
  #
  #   server = HttpServer.new("0.0.0.0", 3000)
  #   server.register("/stuff", MyNiftyHandler.new)
  #   server.run.join
  #
  # The last line can be just server.run if you don't want to join the thread used.
  # If you don't though Ruby will mysteriously just exit on you.
  #
  # Ruby's thread implementation is "interesting" to say the least.  Experiments with
  # *many* different types of IO processing simply cannot make a dent in it.  Future
  # releases of Mongrel will find other creative ways to make threads faster, but don't
  # hold your breath until Ruby 1.9 is actually finally useful.
  class HttpServer < Server
    attr_reader :workers
    attr_reader :throttle
    attr_reader :num_processors

    # Creates a working server on host:port (strange things happen if port isn't a Number).
    # Use HttpServer::run to start the server and HttpServer.acceptor.join to 
    # join the thread that's processing incoming requests on the socket.
    #
    # The num_processors optional argument is the maximum number of concurrent
    # processors to accept, anything over this is closed immediately to maintain
    # server processing performance.  This may seem mean but it is the most efficient
    # way to deal with overload.  Other schemes involve still parsing the client's request
    # which defeats the point of an overload handling system.
    # 
    # The throttle parameter is a sleep timeout (in hundredths of a second) that is placed between 
    # socket.accept calls in order to give the server a cheap throttle time.  It defaults to 0 and
    # actually if it is 0 then the sleep is not done at all.
    def initialize(host, port, num_processors=950, throttle=nil, timeout=nil)
      @host = host
      @port = port
      @domain = "tcp"
      super(throttle, timeout)

      @socket = TCPServer.new(host, port) 
      @workers = ThreadGroup.new
      @num_processors = num_processors
    end

    # Used internally to kill off any worker threads that have taken too long
    # to complete processing.  Only called if there are too many processors
    # currently servicing.  It returns the count of workers still active
    # after the reap is done.  It only runs if there are workers to reap.
    def reap_dead_workers(reason='unknown')
      if @workers.list.length > 0
        STDERR.puts "#{Time.now}: Reaping #{@workers.list.length} threads for slow workers because of '#{reason}'"
        error_msg = "Mongrel timed out this thread: #{reason}"
        mark = Time.now
        @workers.list.each do |worker|
          worker[:started_on] = Time.now if not worker[:started_on]

          if mark - worker[:started_on] > @timeout + @throttle
            STDERR.puts "Thread #{worker.inspect} is too old, killing."
            worker.raise(TimeoutError.new(error_msg))
          end
        end
      end

      return @workers.list.length
    end
    
    # Performs a wait on all the currently running threads and kills any that take
    # too long.  It waits by @timeout seconds, which can be set in .initialize or
    # via mongrel_rails. The @throttle setting does extend this waiting period by
    # that much longer.
    def graceful_shutdown
      while (running_requests = reap_dead_workers("shutdown")) > 0
        STDERR.puts "Waiting for #{running_requests} requests to finish, could take #{@timeout + @throttle} seconds."
        sleep @timeout / 10
      end
    end
    
    # Runs the thing.  It returns the thread used so you can "join" it.  You can also
    # access the HttpServer::acceptor attribute to get the thread later.
    def run
      BasicSocket.do_not_reverse_lookup=true

      configure_socket_options

      if defined?($tcp_defer_accept_opts) and $tcp_defer_accept_opts
        @socket.setsockopt(*$tcp_defer_accept_opts) rescue nil
      end

      @acceptor = Thread.new do
        begin
          while true
            begin
              client = @socket.accept
  
              if defined?($tcp_cork_opts) and $tcp_cork_opts
                client.setsockopt(*$tcp_cork_opts) rescue nil
              end
  
              worker_list = @workers.list
  
              if worker_list.length >= @num_processors
                STDERR.puts "Server overloaded with #{worker_list.length} processors (#@num_processors max). Dropping connection."
                client.close rescue nil
                reap_dead_workers("max processors")
              else
                thread = Thread.new(client) {|c| process_client(c) }
                thread[:started_on] = Time.now
                @workers.add(thread)
  
                sleep @throttle if @throttle > 0
              end
            rescue StopServer
              @socket.close
              break
            rescue Errno::EMFILE
              reap_dead_workers("too many open files")
              sleep 0.5
            rescue Errno::ECONNABORTED
              # client closed the socket even before accept
              client.close rescue nil
            rescue Object => e
              STDERR.puts "#{Time.now}: Unhandled listen loop exception #{e.inspect}."
              STDERR.puts e.backtrace.join("\n")
            end
          end
          graceful_shutdown
        ensure
          @socket.close unless @socket.closed?
          # STDERR.puts "#{Time.now}: Closed socket."
        end
      end

      return @acceptor
    end
  end

  class UnixDispatchServer < Server
    attr_reader :min_children
    attr_reader :num_children
    attr_reader :max_children
    
    class << self
      def before_fork_procs; @before_fork_procs ||= []; end
      def after_fork_procs; @after_fork_procs ||= []; end
      
      def before_fork(&block)
        before_fork_procs << block
      end
      
      def after_fork(&block)
        after_fork_procs << block
      end
    end

    def initialize(options = {})
      super(options[:throttle], options[:timeout])
      @domain        = 'unix'
      @host          = options[:host]
      @port          = options[:port]
      @replace       = options[:replace]

      @min_children  = options[:min_children]
      @max_children  = (options[:max_children] == 0) ? nil : options[:max_children]
      raise ArgumentError, "max_children is set lower than min_children" if @max_children && @min_children > @max_children
      
      @terminate     = false
      @children      = Hash.new
      @listening_sockets = []
    end
    
    def close_server_socket
      @listening_sockets.delete(server_socket)
      server_socket.close  rescue nil
    end
    
    def establish_server_socket
      if @replace
        @replace.call
        @replace = nil
      end
      
      retries = 0
      begin
        @server_socket = TCPServer.new(@host, @port)
      rescue Errno::EADDRINUSE
        puts "In use"
        sleep 0.1
        retry if (retries += 1) <= 10
        raise CouldntConnect
      end
      @listening_sockets << @server_socket
      @server_socket
    end
    
    def server_socket
      @server_socket || establish_server_socket
    end
        
    def busy_children
      @children.values.select { |c| c.busy? }
    end
    
    def reap_dead_workers(reason='unknown')
      if busy_children.length > 0
        STDERR.puts "#{Time.now}: Reaping #{busy_children.length} child(ren) because of '#{reason}'"
        busy_children.each do |child|
          if child.busy? && child.running_seconds > @timeout # + @throttle
            STDERR.puts "Child #{child.pid} has been running too long, killing."
            evict_child(child)#.raise(TimeoutError.new(error_msg))
          end
        end
      end

      return busy_children.length
    end

    # Performs a wait on all the currently running threads and kills any that take
    # too long.  It waits by @timeout seconds, which can be set in .initialize or
    # via mongrel_rails. The @throttle setting does extend this waiting period by
    # that much longer.
    def graceful_shutdown
      while (reap_dead_workers("shutdown")) > 0
        STDERR.puts "Waiting for #{busy_children.length} requests to finish, could take #{@timeout + @throttle} seconds."
        process_incoming_connections(@timeout / 10)
      end
    end

    def run_child(server)
      BasicSocket.do_not_reverse_lookup = true

      configure_socket_options

      @acceptor = Thread.new do
        begin
          while not @terminate
            begin
              server.write("READY #{$$}\n")
              server.flush

              client = server.recv_io(TCPSocket) # read the client's file descriptor from the server!
              next unless client.is_a?(TCPSocket)
              if client.respond_to?(:setsockopt)  and defined?($tcp_cork_opts) and $tcp_cork_opts
                client.setsockopt(*$tcp_cork_opts) rescue nil
              end

              process_client(client)
            rescue StopServer
              @terminate = true
            rescue Errno::ECONNABORTED
              client.close rescue nil
            rescue Errno::EPIPE
              # server broke connection
              @terminate = true
            rescue SignalException => e
              # child signaled to terminate
              @terminate = true
            rescue Object => e
              @terminte = true
              STDERR.puts "Child #{$$} Unhandled listen loop exception #{e.inspect}."
              STDERR.puts e.backtrace.join("\n")
            end
          end
        ensure
          server.write("CLOSED #{$$}\n") rescue nil
          server.close rescue nil
        end
      end
      return @acceptor
    end

    def fork_child
      cio,sio = UNIXSocket::socketpair
      @listening_sockets << sio
      self.class.before_fork_procs.each { |p| p.call }
      pid = fork
      self.class.after_fork_procs.each { |p| p.call }
      
      if pid.nil? # child
        begin
          @listening_sockets.each { |io| io.close rescue nil }
          unless RUBY_PLATFORM =~ /djgpp|(cyg|ms|bcc)win|mingw/
            trap("INT")  { @terminate = true; stop }
            trap("HUP")  { @terminate = true; stop }
            trap("TERM") { @terminate = true; stop }
          end
          begin
            run_child(cio).join
          rescue StopServer
            nil # no need to log this, it's just going to terminate the child.
          end
          Kernel.exit!(0)
        rescue Object => e
          STDERR.puts "Child #{$$} Unhandled listen loop exception #{e.inspect}."
          STDERR.puts e.backtrace.join("\n")
        end
        Kernel.exit!(1)
      end

      cio.close rescue nil
      [pid,sio]
    end

    def evict_child_by_pid(pid)
      evict_child(@children[pid]) if @children.has_key?(pid)
    end
    
    def evict_child(child)
      return if child.nil?
      begin
        Process.kill("TERM", child.pid) 
        Process.waitpid(child.pid)
      rescue Errno::ESRCH,Errno::ECHILD => e
        nil # ignore
      rescue StopServer
        # be sure to pass the stop up the call chain until it gets to the toplevel handler!
        raise
      rescue Object => e
        STDERR.puts "Server #{$$} Unhandled exception #{e.inspect}."
        STDERR.puts :error, e.backtrace.join("\n")
      end
      
      child.close
      @listening_sockets.delete(child.socket)
      @children.delete(child.pid)
    end
    
    def gc_children
      @children.values.each do |child|
        begin
          do_evict = false
          do_evict = true if (child.closed? or child.hanging?)
        rescue Errno::ECHILD
          do_evict = true
        rescue StopServer
          raise # pass it up the chain, don't ignore it.
        rescue Object => e
          STDERR.puts "Server #{$$} Unhandled exception #{e.inspect}."
          STDERR.puts e.backtrace.join("\n")
        end

        evict_child(child) if do_evict
      end
    end
    
    def spawn_min_children
      spawn_child while @children.length < @min_children
    end
    
    def spawn_child
      raise MaxChildrenCapicityReached if @max_children && @children.length >= @max_children
      pid, socket = fork_child
      child = UnixDispatchChild.new(pid, socket)
      @children[pid] = child
      child
    end
    
    # Spawn a child process and wait for it to be ready
    def spawn_child!
      child = spawn_child
      process_child_status_update(child.socket)# wait for it to be ready
      child
    end
    
    def forward_http_request(client)
      child = @children.values.find { |c| not c.busy? } || spawn_child!
      child.receive(client)
    rescue MaxChildrenCapicityReached
      STDERR.puts "Server #{$$} Maximum number of child processes exceeded, request aborted"
      client.close rescue nil
    rescue StandardError => e
      STDERR.puts "Server #{$$} An error occurred accepting a new client connection, a restart may be necessary."
      STDERR.puts "Server #{$$} #{e.message}"
    end
    
    def process_child_status_update(socket)
      case socket.readline.chomp
      when /^READY\s+(\d+)$/
        return unless (child = @children[$1.to_i])
        child.close_client
      when /CLOSED\s+(\d+)/
        evict_child_by_pid($1.to_i)
      end
    rescue EOFError
      # Child process has gone mad - give it the boot
      evict_child(@children.values.find { |c| child.socket == socket })
    end
    
    def wait_for_incoming_connections(time_to_wait)
      connections = Kernel.select(@listening_sockets, nil, nil, time_to_wait)
      connections ? connections.first : []
    end
    
    def process_incoming_connections(time_to_wait = 60)
      incoming_connections = wait_for_incoming_connections(time_to_wait)
      count = incoming_connections.length
      
      http_connection, child_connections = incoming_connections.delete(server_socket), incoming_connections
      
      # By processing child_connections first, we give them a chance to become available before processing the HTTP connections
      child_connections.each { |child_connection| process_child_status_update(child_connection) }
      
      if http_connection
        begin
          forward_http_request(http_connection.accept)
        rescue StandardError => e
          STDERR.puts "Server #{$$} An error occurred accepting a new client connection, a restart may be necessary.   #{e.message}"
        end
      end
      
      return count
    end
    
    def run
      BasicSocket.do_not_reverse_lookup = true
      configure_socket_options

      if defined?($tcp_defer_accept_opts) and $tcp_defer_accept_opts
          server_socket.setsockopt(*$tcp_defer_accept_opts) rescue nil
      end

      @acceptor = Thread.new do
        begin
          while not @terminate
            begin
              gc_children
              spawn_min_children

              count = process_incoming_connections(60)
              
              # If nobody wants to talk to us, go terminate an excess child
              evict_child(@children.values.find { |c| not c.busy? }) if count = 0 && @children.length > @min_children
              
            rescue StopServer
              close_server_socket # immediately detach from the server socket
              @terminate = true
            rescue UriChangeEvent
              @children.values.each { |child| evict_child(child) }
            rescue CouldntConnect => e
              raise e
            rescue Object => e
              STDERR.puts "Server #{$$} Unhandled listen loop exception #{e.inspect}."
              STDERR.puts e.backtrace.join("\n")
            end
          end
          graceful_shutdown
        ensure
          close_server_socket
          @children.values.each { |child| evict_child(child) }
        end
      end # end thread

      return @acceptor
    end

    def register(uri, handler, in_front=false)
      super(uri,handler,in_front)
      @acceptor.raise(UriChangeEvent.new) if not @acceptor.nil? and @acceptor.alive?
    end

    def unregister(uri)
      super(uri)
      @acceptor.raise(UriChangeEvent.new) if not @acceptor.nil? and @acceptor.alive?
    end
  end
  
  class UnixDispatchChild
    attr_accessor :socket, :pid, :client, :request_start_time
    def initialize(pid, socket)
      @socket = socket
      @pid = pid
      @client = true
      @request_start_time = nil
    end
    
    def busy?
      @client ? true : false
    end
    
    def closed?
      if @socket.respond_to?(:closed?)
        @socket.closed?
      else
        true
      end
    end
    
    def hanging?
      Process.waitpid(pid, Process::WNOHANG) == pid
    end
    
    def close_client
      @client.close rescue nil if @client.respond_to?(:close)
      @client = nil
    end
    
    def running_seconds
      busy? ? ( Time.now - @request_start_time ) : 0
    end
    
    def close_socket
      @socket.close rescue nil if @socket.respond_to?(:close)
    end
    
    def close
      close_socket
      close_client
    end
    
    def receive(client)
      @request_start_time = Time.now
      raise ArgumentError, "Client is dead, but server tried to give it a connection anyways" if closed?
      @socket.send_io(client)
      @socket.flush
      @client = client
    end
  end
end

# Load experimental library, if present. We put it here so it can override anything
# in regular Mongrel.

$LOAD_PATH.unshift 'projects/mongrel_experimental/lib/'
Mongrel::Gems.require 'mongrel_experimental', ">=#{Mongrel::Const::MONGREL_VERSION}"

# vim:expandtab:shiftwidth=2:tabstop=2
