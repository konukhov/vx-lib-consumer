require 'json'
require 'timeout'
require 'spec_helper'

describe Vx::Consumer do

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
      its(:queue_options)    { should eq(exclusive: true, durable: false) }
      its(:ack)              { should be_true }
      its(:routing_key)      { should be_nil }
      its(:content_type)     { should eq 'application/json' }
    end
  end

  it "simple pub/sub" do
    consumer = Bob.subscribe
    sleep 1
    3.times {|n| Bob.publish("a" => n) }

    Timeout.timeout(3) do
      loop do
        break if Bob._collected.size == 3
        sleep 0.1
      end
    end
    consumer.cancel

    expect(Bob._collected).to eq([{"a"=>0}, {"a"=>1}, {"a"=>2}])
  end

  it "pub/sub in multithreaded environment" do
    handle_errors do
      cns = []
      30.times do
        cns << Bob.subscribe
      end

      90.times do |n|
        Thread.new do
          Bob.publish("a" => n)
        end
      end

      Timeout.timeout(3) do
        loop do
          break if Bob._collected.size == 90
          sleep 0.1
        end
      end
      cns.map(&:cancel)

      expect(Bob._collected.map{|c| c["a"] }.sort).to eq((0...90).to_a)
    end
  end

  it "should catch errors" do
    error = nil
    Vx::Consumer.configure do |c|
      c.on_error do |e, env|
        error = [e, env]
      end
    end
    consumer = Bob.subscribe
    sleep 0.1
    Bob.publish "not json"

    sleep 0.1
    consumer.cancel

    expect(error[0]).to be_an_instance_of(JSON::ParserError)
    expect(error[1][:consumer]).to_not be_nil
  end

  it "should wait shutdown" do
    consumer = Bob.subscribe
    Bob.publish a: 1

    th = Thread.new {
      consumer.wait
    }
    sleep 1
    Vx::Consumer.shutdown

    Timeout.timeout(1) do
      th.join
    end

    expect(Bob._collected).to eq(["a" => 1])
  end

  def handle_errors
    begin
      yield
    rescue Exception => e
      Vx::Consumer.exception_handler(e, {})
      raise e
    end
  end
end
