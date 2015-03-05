require 'oj'
require 'timeout'
require 'spec_helper'

describe Vx::Lib::Consumer do

  before do
    Bob.timeout = 0.1
  end

  context "test consumer declaration" do
    context "alice" do
      subject { Alice.params }
      its(:exchange_name)    { should eq 'amq.fanout' }
      its(:exchange_options) { should eq(durable: true, auto_delete: false, type: :fanout) }
      its(:queue_name)       { should eq '' }
      its(:queue_options)    { should eq(exclusive: false, durable: true, auto_delete: false) }
      its(:ack)              { should be_false }
      its(:routing_key)      { should eq 'mykey' }
      its(:headers)          { should be_nil }
      its(:content_type)     { should eq 'text/plain' }
    end

    context "bob" do
      subject { Bob.params }
      its(:exchange_name)    { should eq 'bob_exch' }
      its(:exchange_options) { should eq(durable: false, auto_delete: true, type: :topic) }
      its(:queue_name)       { should eq 'bob_queue' }
      its(:queue_options)    { should eq(durable: false, auto_delete: true) }
      its(:ack)              { should be_true }
      its(:routing_key)      { should be_nil }
      its(:content_type)     { should eq 'application/json' }
    end
  end

  it "simple pub/sub" do
    consumer = Bob.subscribe
    sleep 1
    3.times {|n| Bob.publish("a" => n) }

    Timeout.timeout(5) do
      loop do
        break if Bob._collected.size == 3
        sleep 0.1
      end
    end

    Timeout.timeout(3) do
      consumer.graceful_shutdown
    end

    expect(Bob._collected).to eq([{"a"=>0}, {"a"=>1}, {"a"=>2}])
  end

  it "start/stop many times" do
    fn = lambda do |idx|
      consumer = Bob.subscribe
      sleep 1
      3.times {|n| Bob.publish("a" => n + (3 * idx)) }

      Timeout.timeout(5) do
        loop do
          break if Bob._collected.size == 3 + (3 * idx)
          sleep 0.1
        end
      end
      Timeout.timeout(3) do
        consumer.graceful_shutdown
      end

      expect(consumer).to be_closed
    end

    10.times do |n|
      fn.call(n)
    end

    expect(Bob._collected.flat_map(&:values)).to eq((0..29).to_a)
  end

  it "pub/sub in multithreaded environment" do
    handle_errors do
      cns = []
      30.times do |n|
        cns << Bob.subscribe
      end

      90.times do |n|
        Thread.new do
          Bob.publish("a" => n)
        end
      end

      Timeout.timeout(10) do
        loop do
          break if Bob._collected.size >= 90
          sleep 0.1
        end
      end

      Timeout.timeout(1) do
        cns.map(&:graceful_shutdown)
      end

      expect(Bob._collected.map{|c| c["a"] }.uniq.sort).to eq((0...90).to_a)
    end
  end

  it "should catch errors" do
    error = nil
    Vx::Lib::Consumer.configure do |c|
      c.on_error do |e, env|
        error = [e, env]
      end
    end
    consumer = Bob.subscribe
    sleep 0.1
    Bob.publish "not json"

    sleep 0.1
    consumer.cancel

    expect(error[0]).to be_an_instance_of(Oj::ParseError)
    expect(error[1][:consumer]).to_not be_nil
  end

  it "should wait shutdown" do
    bob1 = Bob.subscribe
    bob2 = Bob.subscribe
    Bob.publish a: 1
    Bob.publish a: 2

    th1 = bob1.wait_shutdown
    th2 = bob2.wait_shutdown
    sleep 0.2
    Vx::Lib::Consumer.shutdown

    Timeout.timeout(1) do
      [th1, th2].map(&:join)
    end

    expect(Bob._collected.map(&:values).flatten.sort).to eq [1,2]
  end

  it "should work with graceful_shutdown" do
    Bob.timeout = 1

    consumer = Bob.subscribe
    10.times do |n|
      Bob.publish a: n
    end

    sleep 0.1
    Timeout.timeout(10) do
      consumer.graceful_shutdown
    end

    expect(Bob._collected).to_not be_empty
  end

  it "should work with try_graceful_shutdown" do
    Bob.timeout = 1

    consumer = Bob.subscribe
    1.times do |n|
      Bob.publish a: n
    end

    sleep 0.1
    expect(consumer.try_graceful_shutdown).to be_false

    Timeout.timeout(2) do
      while consumer.running?
        sleep 0.1
      end
    end

    expect(consumer.try_graceful_shutdown).to be_true
  end

  it "running? should be true when consumer process task" do
    Bob.timeout = 1
    consumer = Bob.subscribe

    expect(consumer.running?).to be_false

    10.times do |n|
      Bob.publish a: n
    end

    sleep 0.1
    expect(consumer.running?).to be_true

    Timeout.timeout(1) do
      consumer.cancel
    end

    sleep 0.1
    expect(consumer.running?).to be_false
  end

  def handle_errors
    begin
      yield
    rescue Exception => e
      Vx::Lib::Consumer.exception_handler(e, {})
      raise e
    end
  end
end
