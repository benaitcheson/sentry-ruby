# frozen_string_literal: true

# Run by spec/isolation_spec.rb in a separate rspec process. Not part of the suite.
require "spec_helper"

RUNNER_PID = Process.pid

RSpec.describe "isolated examples", isolate: true do
  it("fails an expectation") { expect(1).to eq(2) }
  it("raises an error") { raise ArgumentError, "boom" }
  it("dies without reporting") { exit!(3) }
  it("skips") { skip "not today" }
  it("passes") do
    expect(Process.pid).not_to eq(RUNNER_PID)
  end

  context "with a failing hook" do
    before { raise "hook failed" }

    it("reports the hook error") { }
  end
end

RSpec.describe "not isolated" do
  it("runs in the parent process") { expect(Process.pid).to eq(RUNNER_PID) }
end

RSpec.describe "per-example isolation reports several errors" do
  context "with a failing body and a failing after hook", isolate: true do
    after { raise "after hook failed" }

    it("reports both errors") { raise "body failed" }
  end
end

RSpec.describe "group isolation", isolate: :group do
  before(:all) { @booted_in = Process.pid }

  it("runs the group in a child process") { expect(@booted_in).not_to eq(RUNNER_PID) }

  it("shares before(:all) state across examples") do
    $group_runs = ($group_runs || 0) + 1
    expect(@booted_in).to eq(Process.pid)
  end

  it("keeps state from earlier examples of the group") { expect($group_runs).to eq(1) }

  it("sets state that must not leak") { $group_leak = :leaked }

  it("fails inside the group") { expect(:a).to eq(:b) }

  it("skips inside the group") { skip "group skip" }
end

RSpec.describe "after a group-isolated group" do
  it("sees no state from the group") { expect($group_leak).to be_nil }
end
