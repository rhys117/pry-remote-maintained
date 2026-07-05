# frozen_string_literal: true

require 'pry'
require 'optparse'
require 'drb/drb'
require 'reline'
require 'open3'
require 'pp'

module PryRemote
  DefaultHost = ENV['PRY_REMOTE_DEFAULT_HOST'] || "127.0.0.1"
  DefaultPort = ENV['PRY_REMOTE_DEFAULT_PORT'] || 9876

  # A class to represent an input object created from DRb. This is used because
  # Pry checks for arity to know if a prompt should be passed to the object.
  #
  # @attr [#readline] input Object to proxy
  InputProxy = Struct.new :input do
    # Reads a line from the input
    def readline(prompt)
      case readline_arity
      when 1 then input.readline(prompt)
      else        input.readline
      end
    end

    def completion_proc=(val)
      input.completion_proc = val
    end

    def readline_arity
      input.method_missing(:method, :readline).arity
    rescue NameError
      0
    end
  end

  # Class used to wrap inputs so that they can be sent through DRb.
  #
  # This is to ensure the input is used locally and not reconstructed on the
  # server by DRb.
  class IOUndumpedProxy
    include DRb::DRbUndumped

    def initialize(obj)
      @obj = obj
      @tty = obj.respond_to?(:tty?) && obj.tty?
    end

    def completion_proc=(val)
      if @obj.respond_to? :completion_proc=
        @obj.completion_proc = proc { |*args, &block| val.call(*args, &block) }
      end
    end

    def completion_proc
      @obj.completion_proc if @obj.respond_to? :completion_proc
    end

    def readline(prompt)
      if Reline == @obj
        @obj.readline(prompt, true)
      elsif @obj.method(:readline).arity == 1
        @obj.readline(prompt)
      else
        $stdout.print prompt
        @obj.readline
      end
    end

    def puts(*lines)
      @obj.puts(*lines)
    end

    def print(*objs)
      @obj.print(*objs)
    end

    def printf(*args)
      @obj.printf(*args)
    end

    def write(data)
      @obj.write data
    end

    def <<(data)
      @obj << data
      self
    end

    def flush
      @obj.flush if @obj.respond_to?(:flush)
    end

    # Whether the underlying stream is a TTY, captured when the proxy is
    # built — this is answered over DRb and the client's terminal doesn't
    # change mid-session.
    def tty?
      @tty
    end
  end

  # Ensure that system (shell command) output is redirected for remote session.
  System = proc do |output, cmd, _|
    status = nil
    Open3.popen3 cmd do |stdin, stdout, stderr, wait_thr|
      stdin.close # Send EOF to the process

      until stdout.eof? and stderr.eof?
        if res = IO.select([stdout, stderr])
          res[0].each do |io|
            next if io.eof?
            output.write io.read_nonblock(1024)
          end
        end
      end

      status = wait_thr.value
    end

    unless status.success?
      output.puts "Error while executing command: #{cmd}"
    end
  end

  ClientEditor = proc do |initial_content, line|
    # Hack to use Pry::Editor
    Pry::Editor.new(Pry.new).edit_tempfile_with_content(initial_content, line)
  end

  # Plain-PP print proc, used when the client passes --no-color so result
  # output doesn't ship ANSI escapes the client can't render.
  NonColorPrint = proc do |_output, value, pry_instance|
    pry_instance.pager.open do |pager|
      pager.print pry_instance.config.output_prefix
      PP.pp(value, pager, pry_instance.output.width - 1)
    end
  end

  # A client is used to retrieve information from the client program.
  Client = Struct.new(:input, :output, :thread, :stdout, :stderr,
                      :editor, :color) do
    # Waits until both an input and output are set
    def wait
      sleep 0.01 until input and output and thread
    end

    # Tells the client the session is terminated
    def kill
      thread.run
    end

    # @return [InputProxy] Proxy for the input
    def input_proxy
      InputProxy.new input
    end
  end

  class Server
    def self.run(object, host = DefaultHost, port = DefaultPort, options = {})
      new(object, host, port, options).run
    end

    def initialize(object, host = DefaultHost, port = DefaultPort, options = {})
      @host    = host
      @port    = port

      @object  = object
      @options = options

      @client = PryRemote::Client.new
      DRb.start_service uri, @client
    end

    # Code that has to be called for Pry-remote to work properly
    def setup
      @hooks = Pry::Hooks.new

      @hooks.add_hook :before_eval, :pry_remote_capture do
        capture_output
      end

      @hooks.add_hook :after_eval, :pry_remote_uncapture do
        uncapture_output
      end

      # Before Pry starts, save the pager config.
      # We want to disable this because the pager won't do anything useful in
      # this case (it will run on the server).
      Pry.config.pager, @old_pager = false, Pry.config.pager

      # As above, but for system config
      Pry.config.system, @old_system = PryRemote::System, Pry.config.system

      Pry.config.editor, @old_editor = editor_proc, Pry.config.editor

      # The client decides whether its terminal can render ANSI (--no-color
      # toggles this). When off, also swap the print proc to plain PP so
      # expression results don't ship ANSI escapes the client can't render.
      want_color = @client.color.nil? ? true : @client.color
      Pry.config.color, @old_color = want_color, Pry.config.color
      @old_print = Pry.config.print
      Pry.config.print = NonColorPrint unless want_color
    end

    # Code that has to be called after setup to return to the initial state
    def teardown
      # Reset config
      Pry.config.editor = @old_editor
      Pry.config.pager  = @old_pager
      Pry.config.system = @old_system
      Pry.config.color  = @old_color
      Pry.config.print  = @old_print

      puts "[pry-remote] Remote session terminated"

      begin
        @client.kill
      rescue DRb::DRbConnError
        puts "[pry-remote] Continuing to stop service"
      ensure
        puts "[pry-remote] Ensure stop service"
        DRb.stop_service
      end
    end

    # Captures $stdout and $stderr if so requested by the client.
    def capture_output
      @old_stdout, $stdout = if @client.stdout
                               [$stdout, @client.stdout]
                             else
                               [$stdout, $stdout]
                             end

      @old_stderr, $stderr = if @client.stderr
                               [$stderr, @client.stderr]
                             else
                               [$stderr, $stderr]
                             end
    end

    # Resets $stdout and $stderr to their previous values.
    def uncapture_output
      $stdout = @old_stdout
      $stderr = @old_stderr
    end

    def editor_proc
      proc do |file, line|
        File.write(file, @client.editor.call(File.read(file), line))
      end
    end

    # Actually runs pry-remote
    def run
      puts "[pry-remote] Waiting for client on #{uri}"
      @client.wait

      puts "[pry-remote] Client received, starting remote session"
      setup

      Pry.start(@object, @options.merge(input: client.input_proxy,
                                        output: client.output,
                                        hooks: @hooks))
    ensure
      teardown
    end

    # @return Object to enter into
    attr_reader :object

    # @return [PryServer::Client] Client connecting to the pry-remote server
    attr_reader :client

    # @return [String] Host of the server
    attr_reader :host

    # @return [Integer] Port of the server
    attr_reader :port

    # @return [String] URI for DRb
    def uri
      "druby://#{host}:#{port}"
    end
  end

  # Parses arguments and allows to start the client.
  class CLI
    def initialize(args = ARGV)
      options = {
        server: DefaultHost,
        port: DefaultPort,
        wait: false,
        persist: false,
        capture: true,
        skip_rc: false,
        color: $stdout.tty?,
        autocomplete: $stdout.tty?
      }

      parser = OptionParser.new do |o|
        o.banner = "Usage: #{$PROGRAM_NAME} [OPTIONS]"

        o.on('-s', '--server HOST', "Host of the server (#{DefaultHost})") { |v| options[:server] = v }
        o.on('-p', '--port PORT', Integer, "Port of the server (#{DefaultPort})") { |v| options[:port] = v }
        o.on('-w', '--wait', "Wait for the pry server to come up") { options[:wait] = true }
        o.on('-r', '--persist', "Persist the client to wait for the pry server to come up each time") { options[:persist] = true }
        o.on('-c', '--[no-]capture', "Captures $stdout and $stderr from the server") { |v| options[:capture] = v }
        o.on('--[no-]color', "Enable syntax highlighting (default: on when stdout is a TTY)") { |v| options[:color] = v }
        o.on('--[no-]autocomplete', "Show completions in a dropdown as you type; each keystroke queries the server, so disable on high-latency connections (default: on when stdout is a TTY)") { |v| options[:autocomplete] = v }
        o.on('-f', '--skip-rc', "Disables loading of .pryrc and its plugins, requires, and command history") { options[:skip_rc] = true }
        o.on('-h', '--help', "Show this help message") do
          puts o
          exit
        end
      end
      parser.parse!(args)

      @host = options[:server]
      @port = options[:port]

      @wait = options[:wait]
      @persist = options[:persist]
      @capture = options[:capture]
      @color = options[:color]
      @autocomplete = options[:autocomplete]

      if options[:skip_rc]
        Pry.config.should_load_rc = false
        Pry.config.should_load_plugins = false
        Pry.config.history_load = false
      end
    end

    # @return [String] Host of the server
    attr_reader :host

    # @return [Integer] Port of the server
    attr_reader :port

    # @return [String] URI for DRb
    def uri
      "druby://#{host}:#{port}"
    end

    attr_reader :wait
    attr_reader :persist
    attr_reader :capture
    attr_reader :color
    attr_reader :autocomplete
    alias wait? wait
    alias persist? persist
    alias capture? capture
    alias color? color
    alias autocomplete? autocomplete

    def run
      while true
        connect
        break unless persist?
      end
    end

    # Connects to the server
    #
    # @param [IO] input  Object holding input for pry-remote. Reline is used
    #   by default (rather than Pry.config.input, which prefers Readline when
    #   available) so that highlighting, autocompletion and history work.
    # @param [IO] output Object pry-debug will send its output to
    def connect(input = Reline, output = Pry.config.output)
      local_ip = UDPSocket.open {|s| s.connect(@host, 1); s.addr.last}
      DRb.start_service "druby://#{local_ip}:0"
      client = DRbObject.new(nil, uri)

      cleanup(client)

      setup_reline if Reline == input

      input  = IOUndumpedProxy.new(input)
      output = IOUndumpedProxy.new(output)

      begin
        client.input  = input
        client.output = output
      rescue DRb::DRbConnError => ex
        if wait? || persist?
          sleep 1
          retry
        else
          raise ex
        end
      end

      if capture?
        client.stdout = $stdout
        client.stderr = $stderr
      end

      client.editor = ClientEditor

      begin
        client.color = color?
      rescue DRb::DRbRemoteError, NoMethodError
        # Server runs an older pry-remote whose Client has no color slot;
        # session still works, results just aren't highlighted server-side.
        $stderr.puts "[pry-remote] Server uses an older pry-remote without color support"
      end

      client.thread = Thread.current

      sleep
      DRb.stop_service
    end

    # Reline runs locally on the client, while Pry's REPL runs on the server
    # and only ever sees a DRb proxy as its input — so everything that REPL
    # would normally configure on Reline has to be wired up here instead.
    def setup_reline
      if color?
        Reline.output_modifier_proc = lambda do |text, _|
          Pry::SyntaxHighlighter.highlight(text)
        end
      end

      # The completion proc itself is installed by the server's Pry REPL and
      # round-trips over DRb; this only turns on the IRB-style dropdown that
      # displays the candidates as you type.
      Reline.autocompletion = autocomplete?

      load_history
    end

    # Loads the local Pry history file into Reline so that previous sessions
    # are reachable with up-arrow. The client never writes the file: the
    # server-side Pry appends each eval'd line to its own history file, which
    # is the same file whenever client and server share a machine.
    def load_history
      return if @history_loaded
      return unless Pry.config.history_load

      @history_loaded = true
      history_file = File.expand_path(Pry.config.history_file)
      return unless File.exist?(history_file)

      File.foreach(history_file) do |line|
        line = line.chomp
        Reline::HISTORY << line unless line.empty?
      end
    end

    # Clean up the client
    def cleanup(client)
      begin
        # The method we are calling here doesn't matter.
        # This is a hack to close the connection of DRb.
        client.cleanup
      rescue DRb::DRbConnError, DRb::DRbRemoteError, NoMethodError
      end
    end
  end
end

class Object
  # Starts a remote Pry session
  #
  # @param [String]  host Host of the server
  # @param [Integer] port Port of the server
  # @param [Hash] options Options to be passed to Pry.start
  def remote_pry(host = PryRemote::DefaultHost, port = PryRemote::DefaultPort, options = {})
    PryRemote::Server.new(self, host, port, options).run
  end

  # a handy alias as many people may think the method is named after the gem
  # (pry-remote)
  alias pry_remote remote_pry
end
