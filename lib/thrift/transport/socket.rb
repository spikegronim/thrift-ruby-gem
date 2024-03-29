# encoding: ascii-8bit
# 
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements. See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership. The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License. You may obtain a copy of the License at
# 
#   http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied. See the License for the
# specific language governing permissions and limitations
# under the License.
# 

require 'socket'

module Thrift
  class Socket < BaseTransport
    def initialize(host='localhost', port=9090, timeout=nil)
      @host = host
      @port = port
      @timeout = timeout
      @desc = "#{host}:#{port}"
      @handle = nil
    end

    attr_accessor :handle, :timeout

    def open
      begin
        addrinfo = ::Socket::getaddrinfo(@host, @port, nil, ::Socket::SOCK_STREAM).first
        @handle = ::Socket.new(addrinfo[4], ::Socket::SOCK_STREAM, 0)
        @handle.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_NODELAY, 1)
        sockaddr = ::Socket.sockaddr_in(addrinfo[1], addrinfo[3])
        begin
          @handle.connect_nonblock(sockaddr)
        rescue Errno::EINPROGRESS
          unless IO.select(nil, [ @handle ], nil, @timeout)
            raise TransportException.new(TransportException::NOT_OPEN, "Connection timeout to #{@desc}")
          end
          begin
            @handle.connect_nonblock(sockaddr)
          rescue Errno::EISCONN
          end
        end
        @handle
      rescue StandardError => e
        raise TransportException.new(TransportException::NOT_OPEN, "Could not connect to #{@desc}: #{e}")
      end
    end

    def open?
      !@handle.nil? and !@handle.closed?
    end

    def write(str)
      raise IOError, "closed stream" unless open?
      begin
        if @timeout.nil? || @timeout == 0
          @handle.write(str)
        else
          len = 0
          start = Time.now
          timespent = 0
          while timespent < @timeout
            rd, wr, err = IO.select([@handle], [@handle], [@handle], @timeout - timespent)
        
            if err and not err.empty?
               # for example the peer suddenly closed the connection
              raise TransportException.new(TransportException::UNKNOWN, "Socket: error reported for socket by IO.select")
            end

            if rd and not rd.empty?
              # for example you are re-using this connection and there is stale data in the read buffer
              raise TransportException.new(TransportException::UNKNOWN, "Socket: bytes in read buffer at inappropriate time")
            end

            if wr and not wr.empty?
              this_write = @handle.write_nonblock(str[len..-1])
              len += this_write
              break if len >= str.length
            end

            timespent = Time.now - start
          end
          if len < str.length
            raise TransportException.new(TransportException::TIMED_OUT, "Socket: Timed out writing #{str.length} (wrote #{len}) bytes to #{@desc}")
          else
            len
          end
        end
      rescue TransportException => e
        # pass this on
        raise e
      rescue StandardError => e
        @handle.close
        @handle = nil
        raise TransportException.new(TransportException::NOT_OPEN, e.message)
      end
    end

    def read(sz)
      raise IOError, "closed stream" unless open?

      begin
        if @timeout.nil? || @timeout == 0
          data = @handle.readpartial(sz)
        else
          # it's possible to interrupt select for something other than the timeout
          # so we need to ensure we've waited long enough, but not too long
          start = Time.now
          timespent = 0
          pieces = []
          bytes_read = 0
          while timespent < @timeout && bytes_read < sz
            rd, wr, err = IO.select([@handle], nil, [@handle], @timeout - timespent)

            if err and not err.empty?
               # for example the peer suddenly closed the connection
              raise TransportException.new(TransportException::UNKNOWN, "Socket: error reported for socket by IO.select")
            end

            if rd and not rd.empty?
              # never assume you can read all of sz in one call to read
              pieces << @handle.readpartial(sz - bytes_read)
              if pieces.last.nil? || pieces.last.length == 0
                raise TransportException.new(TransportException::NOT_OPEN, "EOF reading #{@desc}")
              end
              bytes_read += pieces.last.length 
            end

            timespent = Time.now - start
          end

          data = pieces.reduce(&:+)
          if data.nil? || data.length < sz
            raise TransportException.new(TransportException::TIMED_OUT, "Socket: Timed out reading #{sz} bytes (got #{bytes_read} from #{@desc}")
          end
        end
      rescue TransportException => e
        # don't let this get caught by the StandardError handler
        raise e
      rescue StandardError => e
        @handle.close unless @handle.closed?
        @handle = nil
        raise TransportException.new(TransportException::NOT_OPEN, e.message)
      end
      if (data.nil? || data.length < sz)
        raise TransportException.new(TransportException::UNKNOWN, "Socket: Could not read #{sz} bytes from #{@desc}")
      end
      data
    end

    def close
      @handle.close unless @handle.nil? || @handle.closed?
      @handle = nil
    end

    def to_io
      @handle
    end
  end
end
