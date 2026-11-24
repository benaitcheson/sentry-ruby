# frozen_string_literal: true

# Runs specs in a forked child process, so the process-global state a Rails app
# boot leaves behind (load hooks, callbacks, singletons) dies with the child
# instead of leaking into later examples.
#
#   it "boots its own app", isolate: true do          # one process per example
#     make_basic_app { |config| config.traces_sample_rate = 1.0 }
#   end
#
#   RSpec.describe "boots once", isolate: :group do   # one process per group
#     before(:all) { make_basic_app }
#   end
#
# Both forms also work on a context or describe block. The whole lifecycle
# (hooks, `let`s, bodies) runs in the child, so the parent never touches the
# app. The child sends back plain data and the parent records it on the real
# examples, so formatters, retries and the exit status behave as usual.
#
# Without `fork` (JRuby, Windows) tagged specs run in-process instead.
#
# This hooks into RSpec::Core::Example#run, RSpec::Core::ExampleGroup.run and
# the private Example#start/finish/set_exception, because an `around` hook
# can't skip the example body in the parent. The specs in spec/isolation_spec.rb
# guard that seam across RSpec upgrades.
module Test
  module Isolation
    TIMEOUT = 120

    ChildCrashed = Class.new(StandardError)

    # Stands in for RSpec's reporter inside a group-isolated child and keeps
    # what the parent needs to replay.
    class Recorder
      attr_reader :examples, :non_example_errors

      def initialize
        @examples = []
        @non_example_errors = []
      end

      def example_finished(example)
        @examples << [example.id, Isolation.summarize(example)]
      end

      def notify_non_example_exception(error, context)
        @non_example_errors << { error: Isolation.serialize_error(error), context: context }
      end

      def fail_fast_limit_met?
        false
      end

      def method_missing(*)
        nil
      end

      def respond_to_missing?(*)
        true
      end
    end

    module ExampleExtension
      def run(example_group_instance, reporter)
        return super unless metadata[:isolate] == true && Isolation.forking?

        summary = Isolation.run_in_child do
          super(example_group_instance, RSpec::Core::NullReporter)
          Isolation.summarize(self)
        end
        Isolation.replay(self, summary, reporter)
      end
    end

    module GroupExtension
      def run(reporter = RSpec::Core::NullReporter)
        return super unless Isolation.isolate_group?(self)

        result = Isolation.run_in_child do
          recorder = Recorder.new
          super(recorder)
          { examples: recorder.examples, errors: recorder.non_example_errors }
        end

        Isolation.replay_group(self, result, reporter)
      end
    end

    class << self
      def forking?
        Process.respond_to?(:fork) && !@in_child
      end

      def isolate_group?(group)
        return false unless forking? && group.metadata[:isolate] == :group

        parent = group.superclass
        !(parent.respond_to?(:metadata) && parent.metadata && parent.metadata[:isolate] == :group)
      end

      def run_in_child
        reader, writer = IO.pipe
        reader.binmode
        writer.binmode

        pid = fork do
          @in_child = true
          reader.close
          Coverage.start_in_child
          data = Marshal.dump(yield)
          writer.write(data)
          writer.close
          Coverage.save_from_child
          $stdout.flush
          $stderr.flush
          exit!(0)
        end

        writer.close
        wait_for_result(reader, pid)
      ensure
        reader&.close
        writer&.close
      end

      def summarize(example)
        result = example.execution_result
        summary = { status: result.status, message: result.pending_message }
        summary[:error] = serialize_error(example.exception) if example.exception
        summary
      end

      def serialize_error(error)
        serialized = { class: error.class.name, message: error.message, backtrace: error.backtrace }
        serialized[:all] = error.all_exceptions.map { |e| serialize_error(e) } if error.respond_to?(:all_exceptions)
        serialized
      end

      def replay(example, summary, reporter)
        RSpec.current_example = example
        example.send(:start, reporter)

        case summary[:status]
        when :failed
          example.send(:set_exception, rebuild_error(summary[:error]))
        when :pending
          RSpec::Core::Pending.mark_pending!(example, summary[:message])
        end

        example.send(:finish, reporter)
      ensure
        example.execution_result.ensure_timing_set(RSpec::Core::Time)
        RSpec.current_example = nil
      end

      def replay_group(group, result, reporter)
        reporter.example_group_started(group)

        by_id = group.descendants.flat_map(&:examples).to_h { |example| [example.id, example] }
        recorded = result.fetch(:examples, []).to_h
        crash = result[:crash]

        by_id.each do |id, example|
          summary = recorded[id] || (crash && { status: :failed, error: crash })
          replay(example, summary, reporter) if summary
        end

        result.fetch(:errors, []).each do |entry|
          reporter.notify_non_example_exception(rebuild_error(entry[:error]), entry[:context])
        end

        recorded.values.none? { |s| s[:status] == :failed } && !crash
      ensure
        reporter.example_group_finished(group)
      end

      def wait_for_result(reader, pid)
        if IO.select([reader], nil, nil, TIMEOUT)
          data = reader.read
          status = Process.wait2(pid).last
          return Marshal.load(data) unless data.empty?

          crashed("isolated spec exited without reporting (#{status.inspect})")
        else
          Process.kill("KILL", pid)
          Process.wait(pid)
          crashed("isolated spec timed out after #{TIMEOUT}s")
        end
      end

      def crashed(message)
        error = { class: ChildCrashed.name, message: message, backtrace: [] }
        { status: :failed, error: error, crash: error, examples: [] }
      end

      def rebuild_error(error)
        return RSpec::Core::MultipleExceptionError.new(*error[:all].map { |e| rebuild_error(e) }) if error[:all]

        klass = Object.const_get(error[:class]) if error[:class]
        exception = klass.is_a?(Class) && klass <= Exception ? klass.new(error[:message]) : ChildCrashed.new("#{error[:class]}: #{error[:message]}")
        exception.set_backtrace(error[:backtrace] || [])
        exception
      rescue NameError, ArgumentError, TypeError
        ChildCrashed.new("#{error[:class]}: #{error[:message]}").tap { |e| e.set_backtrace(error[:backtrace] || []) }
      end
    end

    # The child exits with `exit!`, which skips SimpleCov's at_exit hook, so it
    # starts its own measurement (the same thing SimpleCov's subprocess support
    # does) and stores its result for the parent to merge at exit.
    module Coverage
      module_function

      def start_in_child
        return unless simplecov_running?

        ::Coverage.result(stop: false, clear: true)
        SimpleCov.at_fork.call(Process.pid)
      end

      def save_from_child
        SimpleCov.result if simplecov_running?
      end

      def simplecov_running?
        defined?(::SimpleCov) && ::SimpleCov.running
      end
    end
  end
end

RSpec::Core::Example.prepend(Test::Isolation::ExampleExtension)
RSpec::Core::ExampleGroup.singleton_class.prepend(Test::Isolation::GroupExtension)
