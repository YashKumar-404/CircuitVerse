# frozen_string_literal: true

require "rails_helper"

RSpec.describe AssignmentDeadlineSubmissionJob, type: :job do
  include ActiveJob::TestHelper

  before do
    @primary_mentor = FactoryBot.create(:user)
    @group = FactoryBot.create(:group, primary_mentor: @primary_mentor)
    @assignment = FactoryBot.create(:assignment, group: @group)
  end

  describe "#perform" do
    it "when the assignment is nil" do
      expect(described_class.perform_now(nil)).to be_nil
    end

    it "when the assignment is closed" do
      @assignment.status = "closed"
      expect(described_class.perform_now(@assignment.id)).to be_nil
    end

    describe "when the assignment is open" do
      before do
        @assignment.status = "open"
      end

      it "if deadline has not passed, don't close" do
        @assignment.deadline = Time.zone.now + 20
        @assignment.save!
        described_class.perform_now(@assignment.id)
        @assignment.reload
        expect(@assignment.status).to eq("open")
      end

      it "if deadline is more than 10 seconds away, don't close" do
        @assignment.deadline = Time.zone.now + 11
        @assignment.save!
        described_class.perform_now(@assignment.id)
        @assignment.reload
        expect(@assignment.status).to eq("open")
      end

      it "if deadline has passed close assignment" do
        @assignment.deadline = Time.zone.now - 10
        @assignment.save!
        described_class.perform_now(@assignment.id)
        @assignment.reload
        expect(@assignment.status).to eq("closed")
      end

      describe "when unsubmitted projects exist" do
        before do
          @assignment.deadline = Time.zone.now - 10
          @assignment.save!
          @student = FactoryBot.create(:user)
        end

        it "forks and detaches them, keeping already submitted projects" do
          unsubmitted = FactoryBot.create(:project, author: @student)
          submitted = FactoryBot.create(:project, author: @student, project_submission: true)
          @assignment.projects << unsubmitted
          @assignment.projects << submitted

          expect { described_class.perform_now(@assignment.id) }.to change(Project, :count).by(1)
          unsubmitted.reload
          submitted.reload
          expect(unsubmitted.assignment_id).to be_nil
          expect(submitted.assignment_id).to eq(@assignment.id)
        end

        it "saves the fork as the submitted copy of the author" do
          project = FactoryBot.create(:project, author: @student)
          @assignment.projects << project

          described_class.perform_now(@assignment.id)

          forked = Project.find_by(forked_project_id: project.id)
          expect(forked.project_submission).to be(true)
          expect(forked.author_id).to eq(@student.id)
          @assignment.reload
          expect(@assignment.status).to eq("closed")
        end
      end

      it "closes inside the assignment row lock" do
        @assignment.deadline = Time.zone.now - 10
        @assignment.save!
        expect_any_instance_of(Assignment).to receive(:with_lock).and_call_original
        described_class.perform_now(@assignment.id)
      end

      describe "when a duplicate job already handled the assignment" do
        before do
          @assignment.deadline = Time.zone.now - 10
          @assignment.save!
        end

        it "skips when the row is already closed before the lock" do
          FactoryBot.create(:project, author: FactoryBot.create(:user), assignment: @assignment)
          snapshot = Assignment.find(@assignment.id)
          allow(Assignment).to receive(:find_by).and_return(snapshot)
          @assignment.update!(status: "closed")

          expect { described_class.perform_now(@assignment.id) }.not_to change(Project, :count)
        end

        it "skips forking when the row closed while waiting for the lock" do
          FactoryBot.create(:project, author: FactoryBot.create(:user), assignment: @assignment)
          snapshot = Assignment.find(@assignment.id)
          allow(Assignment).to receive(:find_by).and_return(snapshot)
          allow(snapshot).to receive(:status).and_return("open", "open", "closed")

          expect { described_class.perform_now(@assignment.id) }.not_to change(Project, :count)
        end

        it "skips forking when the deadline moved out while waiting for the lock" do
          FactoryBot.create(:project, author: FactoryBot.create(:user), assignment: @assignment)
          snapshot = Assignment.find(@assignment.id)
          allow(Assignment).to receive(:find_by).and_return(snapshot)
          allow(snapshot).to receive(:deadline).and_return(Time.zone.now - 10, 24.hours.from_now)

          expect { described_class.perform_now(@assignment.id) }.not_to change(Project, :count)
        end
      end

      describe "when the assignment row lock times out" do
        before do
          @assignment.update!(deadline: Time.zone.now - 10)
          FactoryBot.create(:project, author: FactoryBot.create(:user), assignment: @assignment)
        end

        it "retries and closes on a later attempt" do
          calls = 0
          allow_any_instance_of(described_class).to receive(:close!).and_wrap_original do |method, assignment|
            calls += 1
            raise ActiveRecord::QueryCanceled if calls == 1

            method.call(assignment)
          end

          perform_enqueued_jobs { described_class.perform_later(@assignment.id) }

          expect(calls).to eq(2)
          @assignment.reload
          expect(@assignment.status).to eq("closed")
        end

        it "raises after the final attempt" do
          allow_any_instance_of(described_class).to receive(:close!)
            .and_raise(ActiveRecord::QueryCanceled)

          perform_enqueued_jobs do
            expect { described_class.perform_later(@assignment.id) }
              .to raise_error(ActiveRecord::QueryCanceled)
          end

          @assignment.reload
          expect(@assignment.status).to eq("open")
        end
      end
    end
  end
end
