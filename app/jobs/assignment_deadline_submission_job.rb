# frozen_string_literal: true

class AssignmentDeadlineSubmissionJob < ApplicationJob
  # Duplicate jobs queue on the locked assignment row and time out their tuple
  # lock. Retry the few that slip past the staleness checks.
  retry_on ActiveRecord::QueryCanceled, wait: 0.seconds, attempts: 3

  queue_as :default

  def perform(assignment_id)
    assignment = Assignment.find_by(id: assignment_id)

    return if assignment.nil? || (assignment.status == "closed")

    # set_deadline_job re-enqueues this job on every assignment commit, so the
    # queue can hold several jobs for the same deadline. Drop the duplicates
    # before taking the row lock.
    return unless close_due?(assignment)

    assignment.with_lock do
      # with_lock reloads the row under FOR UPDATE, so status is fresh here;
      # a duplicate that closed the assignment while we waited exits without
      # forking anything.
      close!(assignment) if close_due?(assignment)
    end
  end

  private

    def close_due?(assignment)
      assignment.status == "open" && Time.zone.now - assignment.deadline >= -10
    end

    def close!(assignment)
      assignment.projects.each do |proj|
        next unless proj.project_submission == false

        submission = proj.fork(proj.author)
        submission.project_submission = true
        proj.assignment_id = nil
        proj.save!
        submission.save!
      end
      assignment.status = "closed"
      assignment.save!
    end
end
