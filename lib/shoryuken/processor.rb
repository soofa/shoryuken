require 'json'

module Shoryuken
  class Processor
    include Celluloid
    include Util

    def initialize(manager)
      @manager = manager
    end

    attr_accessor :proxy_id

    def process(queue, sqs_msg)
      @manager.async.real_thread(proxy_id, Thread.current)

      worker = Shoryuken.worker_registry.fetch_worker(queue, sqs_msg)

        body = get_body(worker.class, sqs_msg)

        worker.class.server_middleware.invoke(worker, queue, sqs_msg, body) do
          worker.perform(sqs_msg, body)
        end

        @manager.async.processor_done(queue, current_actor)
    end

    private

    def get_body(worker_class, sqs_msg)
      if sqs_msg.is_a? Array
        sqs_msg.map { |m| parse_body(worker_class, m) }
      else
        parse_body(worker_class, sqs_msg)
      end
    end

    def parse_body(worker_class, sqs_msg)
      body_parser = worker_class.get_shoryuken_options['body_parser']

      case body_parser
      when :json
        JSON.parse(sqs_msg.body)
      when Proc
        body_parser.call(sqs_msg)
      when :text, nil
        sqs_msg.body
      else
        if body_parser.respond_to?(:parse)
          # JSON.parse
          body_parser.parse(sqs_msg.body)
        elsif body_parser.respond_to?(:load)
          # see https://github.com/phstc/shoryuken/pull/91
          # JSON.load
          body_parser.load(sqs_msg.body)
        end
      end
    rescue => e
      # Add special check for Soofa messages that have somehow been sent to SQS without terminating '}'
      # They also have a bunch of corrupted characters at the end, but this check seems to catch them
      if sqs_msg.body[-1] != "}"  # could also check for last character being corrupted, but this seems to work
        return { device: "FAIL-CORRUPTED", message: "{status}Corrupted message: #{sqs_msg.body}"}
      end
      logger.error { "Error parsing the message body: #{e.message}\nbody_parser: #{body_parser}\nsqs_msg.body: #{sqs_msg.body}" }
      raise
    end
  end
end
