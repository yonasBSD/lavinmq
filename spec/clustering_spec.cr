require "./spec_helper"
require "../src/lavinmq/clustering/client"
require "../src/lavinmq/clustering/controller"

describe LavinMQ::Clustering::Client do
  follower_data_dir = "/tmp/lavinmq-follower"

  around_each do |spec|
    FileUtils.rm_rf follower_data_dir
    p = Process.new("etcd", {
      "--data-dir=/tmp/clustering-spec.etcd",
      "--logger=zap",
      "--log-level=error",
      "--unsafe-no-fsync=true",
      "--force-new-cluster=true",
    }, output: STDOUT, error: STDERR)

    sock = Socket.tcp(Socket::Family::INET)
    loop do
      sleep 0.02
      sock.connect "127.0.0.1", 2379
      break
    rescue Socket::ConnectError
      next
    end
    sock.close
    begin
      spec.run
    ensure
      p.terminate(graceful: false)
      FileUtils.rm_rf "/tmp/clustering-spec.etcd"
      FileUtils.rm_rf follower_data_dir
    end
  end

  it "can stream changes" do
    LavinMQ::Config.instance.clustering_min_isr = 1
    replicator = LavinMQ::Clustering::Server.new(LavinMQ::Config.instance, LavinMQ::Etcd.new, 0)
    tcp_server = TCPServer.new("localhost", 0)
    spawn(replicator.listen(tcp_server), name: "repli server spec")
    config = LavinMQ::Config.new.tap &.data_dir = follower_data_dir
    repli = LavinMQ::Clustering::Client.new(config, 1, replicator.password, proxy: false)
    done = Channel(Nil).new
    spawn(name: "follow spec") do
      repli.follow("localhost", tcp_server.local_address.port)
      done.send nil
    end

    with_amqp_server(replicator: replicator) do |s|
      with_channel(s) do |ch|
        q = ch.queue("repli")
        q.publish_confirm "hello world"
      end
      repli.close
      done.receive
    end

    server = LavinMQ::Server.new(follower_data_dir)
    begin
      q = server.vhosts["/"].queues["repli"].as(LavinMQ::DurableQueue)
      q.message_count.should eq 1
      q.basic_get(true) do |env|
        String.new(env.message.body).to_s.should eq "hello world"
      end.should be_true
    ensure
      server.close
    end
  end

  it "will failover" do
    config1 = LavinMQ::Config.new
    config1.data_dir = "/tmp/failover1"
    config1.clustering_advertised_uri = "tcp://localhost:5681"
    config1.clustering_port = 5681
    config1.amqp_port = 5671
    config1.http_port = 15671
    controller1 = LavinMQ::Clustering::Controller.new(config1)

    config2 = LavinMQ::Config.new
    config2.data_dir = "/tmp/failover2"
    config2.clustering_advertised_uri = "tcp://localhost:5682"
    config2.clustering_port = 5682
    config2.amqp_port = 5672
    config2.http_port = 15672
    controller2 = LavinMQ::Clustering::Controller.new(config2)

    listen = Channel(String).new
    spawn(name: "etcd elect leader spec") do
      etcd = LavinMQ::Etcd.new
      etcd.elect_listen("lavinmq/leader") do |value|
        listen.send value
      end
    rescue LavinMQ::Etcd::Error
      # expect this when etcd nodes are terminated
    end
    sleep 0.5
    spawn(name: "failover1") do
      controller1.run
    end
    spawn(name: "failover2") do
      controller2.run
    end
    sleep 0.1
    leader = listen.receive
    case leader
    when /1$/
      controller1.stop
      listen.receive.should match /2$/
      sleep 0.1
      controller2.stop
    when /2$/
      controller2.stop
      listen.receive.should match /1$/
      sleep 0.1
      controller1.stop
    else fail("no leader elected")
    end
  end
end
