# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

module Quaack
  module Driver
    class Provenance
      # How a Provenance writes its record to its path.
      module Saving
        # Writes the record whole to a temporary file beside it, mode 0600,
        # and renames it into place.
        def save
          dir = File.dirname(@path)
          FileUtils.mkdir_p(dir, mode: 0o700)
          File.chmod(0o700, dir)
          temp = File.join(dir, ".#{File.basename(@path)}.#{SecureRandom.hex(8)}.tmp")
          write(temp)
          File.rename(temp, @path)
          self
        ensure
          FileUtils.rm_f(temp) if temp && File.exist?(temp)
        end

        private

        # Writes the record to a new file at temp, mode 0600 whatever the umask.
        def write(temp)
          File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            file.chmod(0o600)
            file.write(JSON.generate(@record))
          end
        end
      end
    end
  end
end
