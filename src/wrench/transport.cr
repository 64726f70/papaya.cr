class Transport
  enum Side : UInt8
    Client = 0_u8
    Remote = 1_u8
  end

  enum Reliable : UInt8
    Half   = 0_u8
    Full   = 1_u8
    Client = 2_u8
    Remote = 3_u8
  end

  getter client : IO
  getter remote : IO
  getter callback : Proc(Int64, Int64, Nil)?
  getter heartbeat : Proc(Nil)?
  getter mutex : Mutex
  getter workerFibers : Array(Fiber)
  property reliable : Reliable

  def initialize(@client, @remote : IO, @callback : Proc(Int64, Int64, Nil)? = nil, @heartbeat : Proc(Nil)? = nil)
    @mutex = Mutex.new :unchecked
    @workerFibers = [] of Fiber
    @reliable = Reliable::Full
  end

  def remote_tls_context=(value : OpenSSL::SSL::Context::Client)
    @remoteTlsContext = value
  end

  def remote_tls_context
    @remoteTlsContext
  end

  def remote_tls=(value : OpenSSL::SSL::Socket::Client)
    @remoteTls = value
  end

  def remote_tls
    @remoteTls
  end

  def client_tls_context=(value : OpenSSL::SSL::Context::Server)
    @clientTlsContext = value
  end

  def client_tls_context
    @clientTlsContext
  end

  def client_tls=(value : OpenSSL::SSL::Socket::Server)
    @clientTls = value
  end

  def client_tls
    @clientTls
  end

  def heartbeat_interval=(value : Time::Span)
    @heartbeatInterval = value
  end

  def heartbeat_interval
    @heartbeatInterval ||= 10_i32.seconds
  end

  private def sented_size=(value : Int64)
    @mutex.synchronize { @sentedSize = value }
  end

  def sented_size
    @mutex.synchronize { @sentedSize }
  end

  private def received_size=(value : Int64)
    @mutex.synchronize { @receivedSize = value }
  end

  def received_size
    @mutex.synchronize { @receivedSize }
  end

  private def latest_alive=(value : Time)
    @mutex.synchronize { @latestAlive = value }
  end

  private def latest_alive
    @mutex.synchronize { @latestAlive }
  end

  def alive_interval=(value : Time::Span)
    @aliveInterval = value
  end

  def alive_interval
    @aliveInterval || 1_i32.minutes
  end

  def extra_sented_size=(value : Int32 | Int64)
    @extraUploadedSize = value
  end

  def extra_sented_size
    @extraUploadedSize || 0_i32
  end

  def extra_received_size=(value : Int32 | Int64)
    @extraReceivedSize = value
  end

  def extra_received_size
    @extraReceivedSize || 0_i32
  end

  def finished?
    dead_count = @mutex.synchronize { workerFibers.count { |fiber| fiber.dead? } }
    all_task_size = @mutex.synchronize { workerFibers.size }

    dead_count == all_task_size
  end

  def reliable_status(reliable : Reliable = self.reliable)
    ->do
      case reliable
      in .half?
        self.sented_size || self.received_size
      in .full?
        self.sented_size && self.received_size
      in .client?
        self.sented_size
      in .remote?
        self.received_size
      end
    end
  end

  def cleanup_all
    client.close rescue nil
    remote.close rescue nil

    loop do
      finished = self.finished?

      if finished
        free_client_tls
        free_remote_tls

        break
      end

      sleep 0.25_f32
    end
  end

  def cleanup_side(side : Side, free_tls : Bool)
    case side
    in .client?
      client.close rescue nil
    in .remote?
      remote.close rescue nil
    end

    loop do
      finished = self.finished?

      if finished
        case side
        in .client?
          free_client_tls
        in .remote?
          free_remote_tls
        end

        break
      end

      sleep 0.25_f32
    end
  end

  def free_client_tls
    client_tls.try &.free
    client_tls_context.try &.free
  end

  def free_remote_tls
    remote_tls.try &.free
    remote_tls_context.try &.free
  end

  def update_latest_alive
    self.latest_alive = Time.local
  end

  def add_worker_fiber(fiber : Fiber)
    @mutex.synchronize { @workerFibers << fiber }
  end

  def perform
    update_latest_alive

    sent_fiber = spawn do
      exception = nil
      count = 0_i64

      loop do
        size = begin
          IO.super_copy(client, remote) { update_latest_alive }
        rescue ex : IO::CopyException
          exception = ex.cause
          ex.count
        end

        size.try { |_size| count += _size }

        break unless _latest_alive = latest_alive
        break if alive_interval <= (Time.local - _latest_alive)

        break if received_size && exception
        next sleep 0.05_f32.seconds if exception.is_a? IO::TimeoutError
        break
      end

      self.sented_size = (count || 0_i64) + extra_sented_size
    end

    receive_fiber = spawn do
      exception = nil
      count = 0_i64

      loop do
        size = begin
          IO.super_copy(remote, client) { update_latest_alive }
        rescue ex : IO::CopyException
          exception = ex.cause
          ex.count
        end

        size.try { |_size| count += _size }

        break unless _latest_alive = latest_alive
        break if alive_interval <= (Time.local - _latest_alive)

        break if sented_size && exception
        next sleep 0.05_f32.seconds if exception.is_a? IO::TimeoutError
        break
      end

      self.received_size = (count || 0_i64) + extra_received_size
    end

    mixed_fiber = spawn do
      loop do
        _sented_size = sented_size
        _received_size = received_size

        if _sented_size && _received_size
          break callback.try &.call _sented_size, _received_size
        end

        next sleep 0.25_f32.seconds unless heartbeat
        next sleep 0.25_f32.seconds if sented_size || received_size

        heartbeat.try &.call rescue nil
        sleep heartbeat_interval.seconds
      end
    end

    add_worker_fiber sent_fiber
    add_worker_fiber receive_fiber
    add_worker_fiber mixed_fiber
  end
end
