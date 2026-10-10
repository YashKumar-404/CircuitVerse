# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Production Action Mailer configuration", type: :mailer do
  let(:app_config) do
    config = ActiveSupport::OrderedOptions.new
    %i[action_mailer action_controller active_job active_record active_storage
       active_support i18n public_file_server].each do |key|
      config[key] = ActiveSupport::OrderedOptions.new
    end
    config
  end

  let(:config_context) do
    Struct.new(:config) do
      def routes
        Rails.application.routes
      end
    end.new(app_config)
  end

  def with_aws_environment(region: "ap-south-1")
    keys = %w[AWS_ACCESS_KEY_ID_SES AWS_SECRET_ACCESS_KEY_SES AWS_REGION]
    previous = keys.index_with { |key| ENV.fetch(key, nil) }
    ENV["AWS_ACCESS_KEY_ID_SES"] = "spec_access_key"
    ENV["AWS_SECRET_ACCESS_KEY_SES"] = "spec_secret_key"
    if region
      ENV["AWS_REGION"] = region
    else
      ENV.delete("AWS_REGION")
    end
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def load_production_config(region: "ap-south-1")
    with_aws_environment(region: region) do
      allow(Rails.application).to receive(:configure) do |&block|
        config_context.instance_eval(&block)
      end
      load Rails.root.join("config/environments/production.rb").to_s
    end
  end

  it "builds one SESv2 client with bounded timeouts and retries" do
    load_production_config

    settings = app_config.action_mailer.ses_v2_settings
    client = settings[:sesv2_client]

    expect(app_config.action_mailer.delivery_method).to eq(:ses_v2)
    expect(client).to be_a(Aws::SESV2::Client)
    expect(client.config.http_open_timeout).to eq(5)
    expect(client.config.http_read_timeout).to eq(15)
    expect(client.config.max_attempts).to eq(3)
  end

  it "hands the same client to every delivery handler Action Mailer builds" do
    load_production_config

    settings = app_config.action_mailer.ses_v2_settings
    handler_class = ActionMailer::Base.delivery_methods[:ses_v2]
    clients = Array.new(2) { handler_class.new(settings).instance_variable_get(:@client) }

    expect(clients.first).to equal(settings[:sesv2_client])
    expect(clients.last).to equal(clients.first)
  end

  it "boots with no AWS_REGION, as the production image build does" do
    load_production_config(region: nil)

    client = app_config.action_mailer.ses_v2_settings[:sesv2_client]

    expect(client.config.region).to eq("ap-south-1")
  end
end
