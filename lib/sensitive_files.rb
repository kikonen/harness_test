# frozen_string_literal: true

# Central guard for files that must NEVER be added to the allowed file list,
# regardless of the method used (CLI -f / positional args, the /file command,
# or the file_add tool).
#
# To block additional sensitive files later, just append more glob patterns
# to SENSITIVE_PATTERNS (e.g. 'id_rsa', '*.pem', 'credentials.json').
module SensitiveFiles
  # Glob patterns matched against the file's basename (so e.g.
  # 'config/.env.production' is also blocked).
  SENSITIVE_PATTERNS = [
    '.env*'
  ].freeze

  def self.sensitive?(path)
    name = File.basename(path.to_s)
    SENSITIVE_PATTERNS.any? { |pat| File.fnmatch?(pat, name, File::FNM_DOTMATCH) }
  end
end
