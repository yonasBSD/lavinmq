require "logger"
require "digest/sha1"
require "./amqp/io"
require "./segment_position"
require "./policy"
require "./observable"

module AvalancheMQ
  class Queue
    include PolicyTarget
    include Observable

    class QueueFile < File
      include AMQP::IO
    end

    alias ArgumentNumber = UInt16 | Int32 | Int64

    @durable = false
    @log : Logger
    @message_ttl : ArgumentNumber?
    @max_length : ArgumentNumber?
    @expires : ArgumentNumber?
    @dlx : String?
    @dlrk : String?
    @overflow : String?
    @closed = false
    @deleted = false
    @exclusive_consumer = false
    property last_get_time : Int64
    getter name, durable, exclusive, auto_delete, arguments, policy, vhost, consumers
    def_equals_and_hash @vhost.name, @name

    def initialize(@vhost : VHost, @name : String,
                   @exclusive = false, @auto_delete = false,
                   @arguments = Hash(String, AMQP::Field).new)
      @log = @vhost.log.dup
      @log.progname += " queue=#{@name}"
      handle_arguments
      @consumers = Deque(Client::Channel::Consumer).new
      @message_available = Channel(Nil).new(1)
      @consumer_available = Channel(Nil).new(1)
      @unacked = Deque(SegmentPosition).new
      @ready = Deque(SegmentPosition).new
      @segments = Hash(UInt32, QueueFile).new do |h, seg|
        path = File.join(@vhost.data_dir, "msgs.#{seg.to_s.rjust(10, '0')}")
        h[seg] = QueueFile.open(path, "r")
      end
      @last_get_time = Time.now.epoch_ms # reset when redecalred
      spawn deliver_loop, name: "Queue#deliver_loop #{@vhost.name}/#{@name}"
      schedule_expiration_of_queue(@last_get_time)
    end

    def self.generate_name
      "amq.gen-#{Random::Secure.urlsafe_base64(24)}"
    end

    def has_exclusive_consumer?
      @exclusive_consumer
    end

    def apply_policy(@policy : Policy)
      handle_arguments
      @policy.not_nil!.definition.each do |k, v|
        case k
        when "max-length"
          @max_length = v.as_i64
        when "message-ttl"
          @message_ttl = v.as_i64
        when "overflow"
          @overflow = v.as_s
        when "expires"
          @expires = v.as_i64
        when "dead-letter-exchange"
          @dlx = v.as_s
        when "dead-letter-routing-key"
          @dlrk = v.as_s
        when "upstream"
          @vhost.upstreams.try &.link(v.as_s, self)
        when "upstream-set"
          @vhost.upstreams.try &.link_set(v.as_s, self)
        end
      end
    end

    private def handle_arguments
      message_ttl = @arguments["x-message-ttl"]?
      @message_ttl = message_ttl if message_ttl.is_a? ArgumentNumber
      expires = @arguments["x-expires"]?
      @expires = expires if expires.is_a? ArgumentNumber
      @dlx = @arguments["x-dead-letter-exchange"]?.try &.to_s
      @dlrk = @arguments["x-dead-letter-routing-key"]?.try &.to_s
      max_length = @arguments["x-max-length"]?
      @max_length = max_length if max_length.is_a? ArgumentNumber
      @overflow = @arguments.fetch("x-overflow", "drop-head").try &.to_s
    end

    def immediate_delivery?
      @consumers.any? { |c| c.accepts? }
    end

    def message_count : UInt32
      @ready.size.to_u32
    end

    def empty? : Bool
      @ready.size.zero?
    end

    def consumer_count : UInt32
      @consumers.size.to_u32
    end

    def unacked_count : UInt32
      @unacked.size.to_u32
    end

    def close_unused_segments_and_report_used : Set(UInt32)
      s = Set(UInt32).new
      @ready.each { |sp| s << sp.segment }
      @unacked.each { |sp| s << sp.segment }
      @segments.each do |seg, f|
        unless s.includes? seg
          @log.debug { "Closing non referenced segment #{seg}" }
          f.close
        end
      end
      @segments.select! s.to_a
      s
    end

    private def deliver_loop
      i = 0
      loop do
        unless @ready[0]?
          @log.debug { "Waiting for msgs" }
          @message_available.receive
        end
        break if @closed
        @log.debug { "Looking for available consumers" }
        c = nil
        @consumers.size.times do
          c = @consumers.shift
          @consumers.push c
          break if c.accepts?
          c = nil
        end
        if c
          @log.debug { "Getting a new message" }
          if env = get(c.no_ack)
            @log.debug { "Delivering #{env.segment_position} to consumer" }
            c.deliver(env.message, env.segment_position, self)
            @log.debug { "Delivery done" }
          end
        else
          @log.debug "No consumer available"
          now = Time.now.epoch_ms
          schedule_expiration_of_queue(now)
          schedule_expiration_of_next_msg(now)
          @log.debug "Waiting for consumer"
          @consumer_available.receive
        end
        Fiber.yield if (i += 1) % 1000 == 0
      end
      @log.debug "Exiting delivery loop"
    rescue Channel::ClosedError
      @log.debug "Delivery loop channel closed"
    end

    def close(deleting = false) : Nil
      if @closed
        @log.debug "Already closed"
        return
      end
      @log.info "Closing"
      @closed = true
      @message_available.close
      @consumer_available.close
      loop do
        c = @consumers.shift? || break
        c.cancel
      end
      @segments.each_value &.close
      if !deleting && ((@auto_delete || @exclusive) && @expires.nil?)
        delete
      end
      notifyObservers(:close)
      @log.info "Closed"
    end

    protected def delete
      return if @deleted
      @log.info "Deleting"
      @vhost.apply AMQP::Queue::Delete.new 0_u16, 0_u16, @name, false, false, false
      @deleted = true
      notifyObservers(:delete)
    end

    def details
      {
        name: @name, durable: @durable, exclusive: @exclusive,
        auto_delete: @auto_delete, arguments: @arguments,
        consumers: @consumers.size, vhost: @vhost.name,
        messages: @ready.size + @unacked.size,
        ready: @ready.size,
        unacked: @unacked.size,
        policy: @policy.try &.name,
        exclusive_consumer_tag: @exclusive ? @consumers.first?.try(&.tag) : nil,
        state: @closed ? "closed" : "running",
        effective_policy_definition: @policy,
      }
    end

    def to_json(json : JSON::Builder)
      details.to_json(json)
    end

    def publish(sp : SegmentPosition, flush = false)
      if @max_length.try { |ml| @ready.size >= ml }
        @log.debug { "Overflow #{@max_length} #{@overflow}" }
        case @overflow
        when "reject-publish"
          return false
        when "drop-head"
          drophead
        end
      end
      @log.debug { "Enqueuing message #{sp}" }
      @ready.push sp
      @message_available.send nil unless @message_available.full?
      @log.debug { "Enqueued successfully #{sp}" }
      true
    end

    private def metadata(sp) : MessageMetadata
      seg = @segments[sp.segment]
      seg.seek(sp.position, IO::Seek::Set)
      ts = seg.read_int64
      ex = seg.read_short_string
      rk = seg.read_short_string
      pr = AMQP::Properties.decode seg
      MessageMetadata.new(ts, ex, rk, pr)
    end

    private def schedule_expiration_of_next_msg(now)
      sp = @ready[0]? || return nil
      @log.debug { "Checking if next message has to be expired" }
      meta = metadata(sp)
      @log.debug { "Next message: #{meta}" }
      exp_ms = meta.properties.expiration.try(&.to_i64?) || @message_ttl
      if exp_ms
        expire_at = meta.timestamp + exp_ms
        expire_in = expire_at - now
        spawn(expire_later(expire_in, meta, sp),
          name: "Queue#expire_later(#{expire_in}) #{@vhost.name}/#{@name}")
      else
        @log.debug { "No message to expire" }
      end
    end

    private def expire_later(expire_in, meta, sp)
      @log.debug { "Expiring #{sp} in #{expire_in}ms" }
      sleep expire_in.milliseconds if expire_in > 0
      return unless @ready[0]? == sp
      @ready.shift
      expire_msg(meta, sp, :expired)
    end

    def expire_msg(sp : SegmentPosition, reason : Symbol)
      expire_msg(metadata(sp), sp, reason)
    end

    private def expire_msg(meta : MessageMetadata, sp : SegmentPosition, reason : Symbol)
      @log.debug { "Expiring #{sp} now due to #{reason}" }
      dlx = meta.properties.headers.try(&.fetch("x-dead-letter-exchange", nil)) || @dlx
      dlrk = meta.properties.headers.try(&.fetch("x-dead-letter-routing-key", nil)) || @dlrk || meta.routing_key
      if dlx
        env = read(sp)
        msg = env.message
        msg.exchange_name = dlx.to_s
        msg.routing_key = dlrk.to_s
        msg.properties.expiration = nil
        msg.properties.headers ||= Hash(String, AMQP::Field).new
        msg.properties.headers.not_nil!.delete("x-dead-letter-exchange")
        msg.properties.headers.not_nil!.delete("x-dead-letter-routing-key")

        unless msg.properties.headers.not_nil!.has_key? "x-death"
          msg.properties.headers.not_nil!["x-death"] = Array(Hash(String, AMQP::Field)).new(1)
        end
        xdeaths = msg.properties.headers.not_nil!.fetch("x-death").as(Array(Hash(String, AMQP::Field)))
        xd = xdeaths.find { |d| d["queue"] == @name && d["reason"] == reason.to_s }
        xdeaths.delete(xd)
        count = xd ? xd["count"].as(Int32) : 0
        death = Hash(String, AMQP::Field){
          "exchange"     => meta.exchange_name,
          "queue"        => @name,
          "routing_keys" => [meta.routing_key.as(AMQP::Field)],
          "reason"       => reason.to_s,
          "count"        => count + 1,
          "time"         => Time.utc_now,
        }
        death["original-expiration"] = meta.properties.expiration if meta.properties.expiration
        xdeaths.unshift death

        @log.debug { "Dead-lettering #{sp} to exchange \"#{msg.exchange_name}\", routing key \"#{msg.routing_key}\"" }
        @vhost.publish msg
      end
      ack(sp, true)
    end

    private def schedule_expiration_of_queue(now)
      return unless @expires && @consumers.empty?
      spawn(name: "Queue#schedule_expiration_of_queue #{@vhost.name}/#{@name}") do
        sleep @expires.not_nil!.milliseconds
        next unless @consumers.empty?
        next schedule_expiration_of_queue(@last_get_time) if @last_get_time > now
        @log.debug "Expired"
        delete
      end
    end

    def get(no_ack : Bool) : Envelope | Nil
      return if @closed
      sp = @ready.shift? || return nil
      @unacked << sp unless no_ack
      read(sp)
    end

    def peek(length = 1) : Array(Envelope) | Nil
      return if @closed
      Array.new(length) { |i| @ready[i]?.try { |sp| read(sp) } }.compact
    end

    private def read(sp : SegmentPosition) : Envelope
      seg = @segments[sp.segment]
      seg.seek(sp.position, IO::Seek::Set)
      ts = seg.read_int64
      ex = seg.read_short_string
      rk = seg.read_short_string
      pr = AMQP::Properties.decode seg
      sz = seg.read_uint64
      bd = Bytes.new(sz)
      seg.read_fully(bd)
      msg = Message.new(ts, ex, rk, pr, sz, bd)
      Envelope.new(sp, msg)
    end

    def ack(sp : SegmentPosition, flush : Bool)
      return if @closed
      @log.debug { "Acking #{sp}" }
      idx = @unacked.rindex(sp)
      @log.debug { "Acking idx #{idx} in unacked deque" }
      @unacked.delete_at(idx) if idx
      @consumer_available.send nil unless @consumer_available.full?
    end

    def reject(sp : SegmentPosition, requeue : Bool)
      return if @closed
      @log.debug { "Rejecting #{sp}" }
      idx = @unacked.rindex(sp)
      @log.debug { "Rejecting idx #{idx} in unacked deque" }
      if idx
        @unacked.delete_at(idx)
        if requeue
          i = @ready.index { |rsp| rsp > sp } || 0
          @ready.insert(i, sp)
          @message_available.send nil unless @message_available.full?
        else
          expire_msg(sp, :rejected)
        end
      end
    end

    private def drophead
      if sp = @ready.shift?
        @log.debug { "Dropping head #{sp}" }
        expire_msg(sp, :maxlen)
      end
    end

    def add_consumer(consumer : Client::Channel::Consumer)
      return if @closed
      @consumers.push consumer
      @exclusive_consumer = true if consumer.exclusive
      @log.debug { "Adding consumer (now #{@consumers.size})" }
      @consumer_available.send nil unless @consumer_available.full?
      notifyObservers(:add_consumer, consumer)
    end

    def rm_consumer(consumer : Client::Channel::Consumer)
      if @consumers.delete consumer
        @exclusive_consumer = false if consumer.exclusive
        consumer.unacked.each { |sp| reject(sp, true) }
        @log.debug { "Removing consumer (#{@consumers.size} left)" }
        notifyObservers(:rm_consumer, consumer)
        delete if @consumers.size == 0 && @auto_delete
      end
    end

    def purge
      purged_count = message_count
      @ready.clear
      @consumers.each { |c| c.unacked.clear }
      @log.debug { "Purged #{purged_count} messages" }
      purged_count
    end

    def match?(frame)
      @durable == frame.durable &&
        @exclusive == frame.exclusive &&
        @auto_delete == frame.auto_delete &&
        @arguments == frame.arguments
    end

    def match?(durable, auto_delete, arguments)
      @durable == durable &&
        @auto_delete == auto_delete &&
        @arguments == arguments
    end

    def in_use?
      !(empty? && @consumers.empty?)
    end
  end
end
