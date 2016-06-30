# -*- coding: utf-8 -*-
#
# Copyright 2016, Noah Kantrowitz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'shellwords'

require 'net/ssh'

require 'airlift/command_status'
require 'airlift/connection/base'
require 'airlift/errors'
require 'airlift/stat'


module Airlift
  module Connection
    # Connection plugin for running via SSH.
    #
    # @since 1.0.0
    class Ssh < Base
      DEFAULT_READ_SIZE = 32_000

      def initialize(*args)
        super
        @host = config.delete(:host)
      end

      # (see Base#execute_command)
      def execute_command(cmd)
        command_string = cmd.command
        # convert to a single string.
        command_string = Shellwords.join(command_string) if command_string.is_a?(Array)
        # Call cd if we have a working directory to use.
        # TODO The use of sh -c could result in extra unwanted variable interpoation.
        command_string = "sh -c #{Shellwords.escape("cd '#{cmd.cwd}' && exec #{command_string}")}" if cmd.cwd
        # Set any needed environment variables.
        command_string = "env #{cmd.environment.map {|k,v| "#{k}=#v}" }.join(' ')} #{command_string}" unless cmd.environment.empty?

        ssh_sudo_exec!(command_string, input: cmd.input, pty: cmd.pty, sudo: cmd.sudo) do |ch, action, data|
          case action
          when :stdout
            cmd.stdout << data
            cmd.live_stdout << data if cmd.live_stdout
          when :stderr
            cmd.stderr << data
            cmd.live_stderr << data if cmd.live_stderr
          when :exitstatus
            cmd.status = CommandStatus.new(data)
          end
        end
      end

      # (see Base#download_file)
      def download_file(path, &block)
        ssh_sudo_exec!('cat', path) do |ch, action, data|
          case action
          when :stdout
            block.call(data)
          when :exitstatus
            return false if data != 0
          end
        end
        true
      end

      # (see Base#upload_file)
      def upload_file(path, &block)
        # This uses cat> so that it can be sudo-d to directly write to root-owned
        # files without an upload + sudo mv. It could use tee but then it would
        # echo back all the data which would be a waste of bandwidth.
        # As with the sh in {#execute_command}, this could cause issues with paths
        # that contain literally $s or 's. Don't do that, seriously.
        ssh_sudo_exec!('sh', '-c', "cat > '#{path}'") do |ch, action, data|
          case action
          when :exec
            writer_proc = Proc.new do |writer_data|
              ch.send_data(writer_data)
              # TODO Do something here to pump the event loop so we don't
              # buffer everything forever. Alternatively check if send_data has
              # a sync version (or is always sync)?
            end
            block.call(writer_proc)
            ch.close
          when :exitstatus
            return false if data != 0
          end
        end
        true
      end

      # (see Base#stat)
      def stat(path, follow_symlink:)
        # TODO use existing Train stat parser code here.
        # depends on porting over the OS detection code.
        raise 'boom'
      end

      # (see Base#sync)
      def sync(local_path, remote_path)
        raise 'boom'
      end

      # (see Base#delete)
      def delete(path)
        ssh_sudo_exec!('rm', path) do |ch, action, data|
          case action
          when :exitstatus
            return false if data != 0
          end
        end
        true
      end

      # (see Base#close)
      def close
        # Shut down SSH.
        if @ssh_connection
          @ssh_connection.close
          @ssh_connection = nil
        end
        super
      end

      private

      # Create and memoize an SSH connection.
      #
      # @return [Net::SSH::Session]
      def ssh_connection
        @ssh_connection ||= Net::SSH.start(@host, config[:user], config[:ssh_options] || {})
      end

      # More flexible version of `Net::SSH::Session#exec`. The provided block
      # with be called at various points throughout the channel lifecycle.
      # The values passed to the block will be the SSH channel object, a symbol
      # indicating the type of callback, and an optional data value.
      #
      # Callback action types:
      # * `:connect` – After initial connection setup.
      # * `:pty` – After a PTY is allocated, if requested.
      # * `:exec` – After the command is successfully started.
      # * `:stdout` – Process stdout data is available. The data argument will
      #   be a string buffer.
      # * `:stderr` – Process stderr data is available. The data argument will
      #   be a string buffer.
      # * `:exitstatus` – Command has finished. The data argument will be the
      #   numeric exit code.
      #
      # @param cmd [Array<String>, Array<Array<String>>] Command string or array
      #   to execute.
      # @param pty [Boolean] Request a PTY or not.
      # @param block [Proc] Callback block for channel events.
      # @return [Net::SSH::Channel]
      def ssh_exec(*cmd, pty: true, &block)
        cmd = cmd.first if cmd.length == 1
        # Convert array to a string.
        cmd = Shellwords.join(cmd) if cmd.is_a?(Array)

        ssh_connection.open_channel do |ch|
          # Run on-connect stuff.
          block.call(ch, :connect, nil)

          pty_cb = Proc.new do |_, pty_success|
            raise Errors::CommandError("could not request PTY: #{cmd}") unless pty_success

            block.call(ch, :pty, nil)

            # Callback for stdout data.
            ch.on_data do |_, data|
              block.call(ch, :stdout, data)
            end

            # Callback for stderr data (mostly).
            ch.on_extended_data do |_, type, data|
              # Just in case someone does something wonky, SSH doesn't actually
              # define any other types but who knows.
              block.call(ch, :stderr, data) if type == 1
            end

            # Callback for getting the exit status.
            ch.on_request('exit-status') do |_, data|
              block.call(ch, :exitstatus, data.read_long)
            end

            # Implement this too but I'm not clear on when it actually gets used
            # by OpenSSH instead of exit-status.
            ch.on_request('exit-signal') do |_, data|
              block.call(ch, :exitstatus, data.read_long)
            end

            # Run the requested command.
            logger.debug("[Airlift::Connection::SSH] Running command: #{cmd}") if logger
            ch.exec cmd do |_, exec_success|
              raise Errors::CommandError("could not start ssh command execution: #{cmd}") unless exec_success
              block.call(ch, :exec, nil)
            end
          end

          # Start the whole thing!
          if pty
            ch.request_pty(&pty_cb)
          else
            pty_cb.call(ch, true)
          end

        end
      end

      # Like {#ssh_exec} but waits for the channel to finish execution.
      #
      # @see #ssh_exec
      # @return [Net::SSH::Channel]
      def ssh_exec!(*args, &block)
        ssh_exec(*args, &block).tap {|ch| ch.wait }
      end

      # Extends {#ssh_exec} to automatically run the command under sudo if
      # requested.
      def ssh_sudo_exec(*cmd, input: nil, pty: true, sudo: config[:sudo], &block)
        # Not actually using sudo features.
        unless sudo
          return ssh_exec(*cmd, pty: pty) do |ch, action, data|
            ch.send_data(input) if action == :exec
            block.call(ch, action, data)
          end
        end

        # Set up the sudo stuffs.
        sudo_password_buf = nil
        if sudo
          # Convert array to a string and other cleanups.
          cmd = cmd.first if cmd.length == 1
          cmd = Shellwords.join(cmd) if cmd.is_a?(Array)
          # Add the sudo command
          cmd = if sudo.is_a?(String)
            # Set up a buffer.
            sudo_password_buf = ''
            "sudo --prompt=__SUDO_PASSWORD__ #{cmd}"
          else
            "sudo --non-interactive #{cmd}"
          end
        end

        ssh_exec(*cmd, pty: pty) do |ch, action, data|
          # If we are waiting to see __SUDO_PASSWORD__, don't pass through
          # any data.
          if action == :stdout && sudo_password_buf
            sudo_password_buf << data
            data = ''
            if sudo_password_buf.end_with?('__SUDO_PASSWORD__')
              # Send the password and then the rest of the input.
              ch.send_data("#{sudo}\n")
              ch.send_data(input) if input
              sudo_password_buf = nil
            end
          elsif action == :exec && !sudo.is_a?(String)
            ch.send_data(input) if input
          end
          block.call(ch, action, data)
        end
      end

      # Like {#ssh_sudo_exec} but waits for the channel to finish execution.
      #
      # @see #ssh_sudo_exec
      # @return [Net::SSH::Channel]
      def ssh_sudo_exec!(*args, &block)
        ssh_sudo_exec(*args, &block).tap {|ch| ch.wait }
      end

    end
  end
end
