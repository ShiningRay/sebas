# frozen_string_literal: true

module SebasAgents
  VERSION = "0.1.0"
end

require_relative "sebas_agents/errors"
require_relative "sebas_agents/json_block"
require_relative "sebas_agents/advisory_checks"
require_relative "sebas_agents/model"
require_relative "sebas_agents/output"
require_relative "sebas_agents/verification_report"
require_relative "sebas_agents/role_prompts"

require_relative "sebas_agents/policy/milestones"
require_relative "sebas_agents/policy/evidence"
require_relative "sebas_agents/policy/dependencies"
require_relative "sebas_agents/lease"
require_relative "sebas_agents/ref_lock"
require_relative "sebas_agents/policy/scope"
require_relative "sebas_agents/policy/worker"
require_relative "sebas_agents/policy/merging_reconcile"
require_relative "sebas_agents/policy/routing"
require_relative "sebas_agents/policy/selection"
require_relative "sebas_agents/merge_queue"
require_relative "sebas_agents/auto_merge"
require_relative "sebas_agents/path_checks"

require_relative "sebas_agents/command_runner"
require_relative "sebas_agents/github_gateway"
require_relative "sebas_agents/run_record"
require_relative "sebas_agents/verifier"
require_relative "sebas_agents/verify_checks"
require_relative "sebas_agents/triager"
require_relative "sebas_agents/digest"
require_relative "sebas_agents/release"
require_relative "sebas_agents/cli"
