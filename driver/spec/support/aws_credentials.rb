# frozen_string_literal: true

require "aws-sdk-bedrockruntime"
require "fileutils"
require "tmpdir"

# The AWS credentials and region the AWS SDK finds on its own, set up for a
# spec, so nothing on this machine is found and nothing reaches AWS.
module AWSCredentials
  # For the block, every AWS_ variable and AMAZON_REGION is unset, the SDK's config and
  # credentials files are empty ones in a new directory, and the EC2
  # metadata endpoint is off, so the SDK's credential chain finds nothing and
  # never waits on the network. changes then set some. Yields the directory.
  # Afterwards those variables are as they were, even ones the block set.
  #
  # The SDK reads its files once and keeps them, so they're forgotten before
  # the block and after it.
  def without_aws_credentials(changes = {})
    before = aws_variables
    Dir.mktmpdir("quaack-aws") do |dir|
      reset_aws_variables("AWS_CONFIG_FILE" => File.join(dir, "config"),
                          "AWS_SHARED_CREDENTIALS_FILE" => File.join(dir, "credentials"),
                          "AWS_EC2_METADATA_DISABLED" => "true", **changes)
      yield dir
    end
  ensure
    reset_aws_variables(before)
  end

  # Appends a section to the SDK's config file in dir, such as
  # `write_aws_config(dir, "profile named", "region = eu-central-1")`.
  def write_aws_config(dir, section, *lines) = append(File.join(dir, "config"), section, lines)

  # Appends a profile with static keys to the SDK's credentials file in dir.
  def write_aws_profile(dir, name, access_key, secret_key)
    append(File.join(dir, "credentials"), name,
           ["aws_access_key_id = #{access_key}", "aws_secret_access_key = #{secret_key}"])
  end

  private

  def aws_variables = ENV.to_h.select { |name, _| name.start_with?("AWS_") || name == "AMAZON_REGION" }

  # Unsets every AWS_ variable and AMAZON_REGION, then sets variables.
  def reset_aws_variables(variables)
    aws_variables.each_key { ENV.delete(it) }
    ENV.update(variables)
    forget_aws_files
  end

  def append(path, section, lines)
    File.open(path, "a") { it.write("[#{section}]\n#{lines.join("\n")}\n\n") }
    forget_aws_files
  end

  def forget_aws_files = Aws.instance_variable_set(:@shared_config, nil)
end
