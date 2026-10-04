# frozen_string_literal: true

class Star < ApplicationRecord
  belongs_to :user
  belongs_to :project, counter_cache: true
  after_create_commit :notify_recipient
  before_destroy :cleanup_notification
  after_create_commit :reset_user_starred_project_ids
  after_destroy_commit :reset_user_starred_project_ids
  has_many :notifications, as: :notifiable # rubocop:disable Rails/HasManyOrHasOneDependent
  has_noticed_notifications model_name: "NoticedNotification"

  private

    def reset_user_starred_project_ids
      user&.reset_starred_project_ids
    end

    def notify_recipient
      return if user.id == project.author_id

      StarNotification.with(user: user, project: project).deliver_later(project.author)
    end

    def cleanup_notification
      notifications_as_star.destroy_all
    end
end
