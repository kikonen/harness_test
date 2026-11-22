# frozen_string_literal: true

require_relative "harness_error"
require_relative "config_scalar"

# -- ModelProfile ---------------------------------------------------------
#
# The normalized form of ONE entry in the config 'models:' list: a value object
# holding exactly what the harness knows about one model, so validation lives in
# this one place (#valid?) instead of being re-guessed across HarnessConfig,
# SystemSettings, ModelConfig and the commands.
#
# Roles (issues #556, #572): 'id' selects the profile (-m, default_profile_id,
# /model, a saved session); 'name' is an optional display label (defaults to
# the id); 'model' is the value a request's model: field carries - never the
# id or the name. An entry that predates 'id:' keys itself by 'name:', which
# becomes the id.
#
# #new is NON-raising: it normalizes whatever it is given. #valid? is the single
# place that answers whether the profile is usable, and #valid! raises the
# startup config error from that one answer. Scalar coercions live in
# ConfigScalar, shared with HarnessConfig's other keys.
#
# Bracket access (profile[:id]) is a compatibility surface for the consumers and
# specs that still read profiles by key.
class ModelProfile
  include ConfigScalar

  SAMPLING_KEYS = %i[
    num_ctx max_tokens num_predict reasoning_effort temperature
    top_p top_k min_p presence_penalty repeat_penalty
  ].freeze

  attr_reader :id,
    :name,
    :model,
    :url,
    :api,
    :token,
    :vision,
    :streaming,
    :mcp_images

  def initialize(entry)
    entry = {} unless entry.is_a?(Hash)

    @id         = nonblank(entry[:id]) || nonblank(entry[:name])
    @model      = nonblank(entry[:model])
    @url        = nonblank(entry[:url])
    @name       = nonblank(entry[:name]) || @id
    @api        = nonblank(entry[:api])
    @token      = expand_env(nonblank(entry[:token]), "a model token")
    @vision     = entry[:vision] == true
    @streaming  = bool_or_nil(entry[:streaming])
    @mcp_images = entry[:mcp_images].is_a?(Hash) ? entry[:mcp_images] : nil
    @sampling   = SAMPLING_KEYS.to_h { |key| [key, number_or_nil(key, entry[key])] }
  end

  # Role-pure predicates: each role (id/model/url) answers for itself, so no
  # role is ever inferred from another. #valid? is the single usability answer.
  def id_present?
    !id.nil?
  end

  def model_present?
    !model.nil?
  end

  def url_present?
    ConfigScalar.http_url?(url)
  end

  def valid?
    problems.empty?
  end

  def valid!
    raise HarnessError, problems.first unless valid?
  end

  def problems
    return ["model profile needs an 'id' (it identifies the profile)"] unless id_present?

    reasons = []
    reasons << "model profile '#{id}' needs a 'model' (a model name, not a profile id)" if
      !model_present?
    if url.nil?
      reasons << "model profile '#{id}' needs a 'url' (no built-in endpoint default)"
    elsif !url_present?
      reasons << "model profile '#{id}' url must start with http(s) (got: #{url})"
    end
    reasons
  end

  def [](key)
    return public_send(key) if respond_to?(key)

    @sampling[key]
  end

  # Fill a declared mcp_images block to the full budget (defaults supply the
  # keys the profile left out). nil when the profile declares none.
  def normalize_image_limits(defaults)
    @mcp_images = ConfigScalar.normalize_mcp_images(@mcp_images, defaults) if @mcp_images
  end

  def to_h
    {
      id:,
      name:,
      model:,
      url:,
      api:,
      token:,
      vision:,
      streaming:,
      mcp_images:
    }.merge(@sampling)
  end
end
