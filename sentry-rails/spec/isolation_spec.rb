# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"

RSpec.describe "isolate: true metadata" do
  PARENT_PID = Process.pid

  context "when examples are tagged", order: :defined do
    it "runs in a child process", isolate: true do
      expect(Process.pid).not_to eq(PARENT_PID)
    end

    it "keeps global state changed by the example out of the parent", isolate: true do
      $isolation_leak = :leaked
    end

    it "does not see state changed by an isolated example" do
      expect($isolation_leak).to be_nil
    end
  end

  context "when reporting results to RSpec" do
    before(:context) do
      fixture = File.join(__dir__, "fixtures/isolation_examples.rb")

      Dir.mktmpdir do |dir|
        out = File.join(dir, "report.json")
        @coverage_dir = File.join(dir, "coverage")
        system(
          { "SENTRY_RAILS_COVERAGE_DIR" => @coverage_dir },
          "bundle", "exec", "rspec", fixture,
          "--format", "json", "--out", out, "--no-color",
          out: File::NULL, err: File::NULL
        )
        @report = JSON.parse(File.read(out))
        resultset = File.join(@coverage_dir, ".resultset.json")
        coverage_runs = File.exist?(resultset) ? JSON.parse(File.read(resultset)).values : []
        child_only_line = File.readlines(fixture).index { |line| line.include?("expect(Process.pid).not_to eq(RUNNER_PID)") }
        @child_only_line_hits = coverage_runs.sum { |run| run.dig("coverage", fixture, "lines", child_only_line).to_i }
      end
    end

    def example_named(description)
      @report.fetch("examples").find { |e| e["description"] == description } or raise "no example #{description}"
    end

    it "passes isolated examples that pass and leaves untagged examples in the runner" do
      expect(example_named("passes")["status"]).to eq("passed")
      expect(example_named("runs in the parent process")["status"]).to eq("passed")
    end

    it "reports an expectation failure with its message" do
      example = example_named("fails an expectation")

      expect(example["status"]).to eq("failed")
      expect(example.dig("exception", "class")).to eq("RSpec::Expectations::ExpectationNotMetError")
      expect(example.dig("exception", "message")).to include("expected: 2", "got: 1")
    end

    it "reports an unexpected error with its class, message and backtrace" do
      example = example_named("raises an error")

      expect(example["status"]).to eq("failed")
      expect(example["exception"]).to include("class" => "ArgumentError", "message" => "boom")
      expect(example.dig("exception", "backtrace")).not_to be_empty
    end

    it "reports errors raised in hooks" do
      example = example_named("reports the hook error")

      expect(example["status"]).to eq("failed")
      expect(example.dig("exception", "message")).to eq("hook failed")
    end

    it "reports a child that dies without reporting" do
      example = example_named("dies without reporting")

      expect(example["status"]).to eq("failed")
      expect(example.dig("exception", "message")).to match(/exited without reporting.*exit 3/)
    end

    it "records coverage of code that only runs in the child process" do
      expect(@child_only_line_hits).to be_positive
    end

it "reports every error of an example that fails more than once" do
  example = example_named("reports both errors")

  expect(example["status"]).to eq("failed")
  expect(example.dig("exception", "message")).to include("body failed", "after hook failed")
end

it "runs a group-isolated group in a child process with shared before(:all) state" do
  expect(example_named("runs the group in a child process")["status"]).to eq("passed")
  expect(example_named("shares before(:all) state across examples")["status"]).to eq("passed")
  expect(example_named("keeps state from earlier examples of the group")["status"]).to eq("passed")
end

it "keeps state from a group-isolated group out of the runner" do
  expect(example_named("sees no state from the group")["status"]).to eq("passed")
end

it "reports failures and skips inside a group-isolated group" do
  failed = example_named("fails inside the group")
  skipped = example_named("skips inside the group")

  expect(failed["status"]).to eq("failed")
  expect(failed.dig("exception", "message")).to include("expected: :b", "got: :a")
  expect(skipped["status"]).to eq("pending")
  expect(skipped["pending_message"]).to eq("group skip")
end

    it "keeps skipped examples skipped with their reason" do
      example = example_named("skips")

      expect(example["status"]).to eq("pending")
      expect(example["pending_message"]).to eq("not today")
    end
  end
end
