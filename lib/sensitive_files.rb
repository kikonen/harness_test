# frozen_string_literal: true

# Central guard for files that must NEVER be added to the allowed file list,
# regardless of the method used (CLI -f / positional args, the /file command,
# or the file.add tool).
#
# To block additional sensitive files later, just append more glob patterns
# to SENSITIVE_PATTERNS (e.g. 'id_rsa', '*.pem', 'credentials.json').
module SensitiveFiles
  # Glob patterns matched against the file's basename (so e.g.
  # 'config/.env.production' is also blocked).
  SENSITIVE_PATTERNS = [
    '.env*'
  ].freeze

  # Directory names that must never be traversed into (matched against every
  # path component, so e.g. '.git/config' and 'vendor/.git/HEAD' are blocked).
  SENSITIVE_DIRS = [
    '.git',
    '.harness'
  ].freeze

  def self.sensitive?(path)
    name = File.basename(path.to_s)
    return true if SENSITIVE_PATTERNS.any? { |pat| File.fnmatch?(pat, name, File::FNM_DOTMATCH) }

    SENSITIVE_DIRS.any? { |dir| path.to_s.split(File::SEPARATOR).include?(dir) }
  end
end