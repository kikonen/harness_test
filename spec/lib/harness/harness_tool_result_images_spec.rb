# frozen_string_literal: true

require_relative 'harness_spec_support'

# issue #449: the harness half of the tool-result image path. A ToolResult (an
# MCP server that returned image blocks) must reach the chain as text + a
# stored file + (only for a vision profile, within budget) an inline payload,
# and the inline payload must never survive into the committed session.
RSpec.describe Harness, 'tool-result images (issue #449)' do
  include HarnessSpecSupport

  def build(options = {})
    file_list = FileList.new([], workdir: workdir)
    opts = { system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE,
             num_ctx: 65_536 }.merge(options)
    session_id  = opts.delete(:session_id)
    resume_data = opts.delete(:resume_data)
    Harness.new(file_list, settings: SystemSettings.from_options(opts),
                session_id: session_id, resume_data: resume_data)
  end

  def image(bytes: 'x' * 100, mime: 'image/png')
    ToolResult::Image.new(server: 'blender', tool: 'shot', mime_type: mime, bytes: bytes.b)
  end

  def tool_call(id: 'c1', name: 'blender.shot')
    { id:, function: { name: name, arguments: '{}' } }
  end

  def build_harness_vision(options = {})
    # A profile that declares vision (SessionManager#vision? reads the active one).
    # model_profiles is run-wide config (settings); active_profile_id is live per-
    # connection state (#286), so a #286 settings carries only the catalogue and
    # the Harness seeds its ModelConfig from it at build time.
    opts = { model_profiles: [{ name: 'v', vision: true }],
             active_profile_id: 'v' }.merge(options)
    build(opts)
  end

  it 'the blob dir is keyed by the session id under the content store' do
    h = build(session_id: 'sess-77')

    expect(h.image_content_dir('sess-77')).to eq('.harness/content/sess-77')
    expect(h.image_store.relative_dir).to eq('.harness/content/sess-77')
  end

  it 'honours a configured content dir' do
    h = build(mcp_images_dir: 'build/images', session_id: 's')

    expect(h.image_content_dir('s')).to eq('build/images/s')
  end

  it 'a vision profile gets an inline payload beside the text' do
    h = build_harness_vision
    msg = h.tool_result_message(tool_call, ToolResult.new(text: 'shot', images: [image]),
                                h.image_delivery)

    expect(msg[:content]).to include('shot')
    expect(msg[:content]).to include('attached to this result')
    expect(msg[:images].first[:base64]).to eq(Base64.strict_encode64('x' * 100))
  end

  it 'a text profile gets the stored path in text and NO inline payload' do
    h = build
    msg = h.tool_result_message(tool_call, ToolResult.new(text: 'shot', images: [image]),
                                h.image_delivery)

    expect(msg).not_to have_key(:images)
    expect(msg[:content]).to include("stored as .harness/content/#{h.session.session_id}/blender_shot_1.png")
    expect(msg[:content]).to include('reach it with the shell')
  end

  it 'strip_image_payloads drops the base64 but keeps the text' do
    h = build_harness_vision
    msg = h.tool_result_message(tool_call, ToolResult.new(text: 'shot', images: [image]),
                                h.image_delivery)
    messages = [msg]
    h.strip_image_payloads(messages)

    expect(messages.first).not_to have_key(:images)
    expect(messages.first[:content]).to include('shot')
  end
end
