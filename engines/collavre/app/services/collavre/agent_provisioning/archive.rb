# frozen_string_literal: true

require "digest"
require "json"
require "stringio"
require "zlib"

module Collavre
  module AgentProvisioning
    class Archive
      BLOCK_SIZE = 512
      MAX_FILE_SIZE = 1.megabyte
      MAX_ARCHIVE_SIZE = 10.megabytes

      class << self
        def collavre_skill
          @collavre_skill ||= build_from_directory(Rails.root.join("skills/collavre"))
        end

        def workspace_config(workspace, base_url:)
          json = JSON.pretty_generate(workspace.config_payload(base_url: base_url)) << "\n"
          build({ "config.json" => { content: json, mode: 0o600 } })
        end

        def sha256(bytes)
          Digest::SHA256.hexdigest(bytes)
        end

        private

        def build_from_directory(root)
          files = Dir.glob(root.join("**/*"), File::FNM_DOTMATCH).filter_map do |path|
            next unless File.file?(path)

            relative = Pathname(path).relative_path_from(root).to_s
            mode = File.executable?(path) ? 0o755 : 0o644
            [ relative, { content: File.binread(path), mode: mode } ]
          end.to_h
          build(files)
        end

        def build(files)
          tar = +"".b
          total_size = 0
          files.sort.each do |name, entry|
            content = entry.fetch(:content).to_s.b
            raise ArgumentError, "Provisioning file is too large: #{name}" if content.bytesize > MAX_FILE_SIZE
            raise ArgumentError, "Provisioning file is binary: #{name}" if content.include?("\0")

            total_size += content.bytesize
            raise ArgumentError, "Provisioning archive expands beyond the limit" if total_size > MAX_ARCHIVE_SIZE

            tar << tar_header(name, mode: entry.fetch(:mode), size: content.bytesize)
            tar << content
            tar << "\0" * ((BLOCK_SIZE - (content.bytesize % BLOCK_SIZE)) % BLOCK_SIZE)
          end
          tar << "\0" * (BLOCK_SIZE * 2)

          io = StringIO.new(+"".b)
          gzip = Zlib::GzipWriter.new(io, Zlib::BEST_COMPRESSION)
          gzip.mtime = 0
          gzip.write(tar)
          gzip.close
          bytes = io.string
          raise ArgumentError, "Provisioning archive is too large" if bytes.bytesize > MAX_ARCHIVE_SIZE

          bytes.freeze
        end

        def tar_header(name, mode:, size:)
          raise ArgumentError, "Provisioning path is too long: #{name}" if name.bytesize > 100

          header = +"\0" * BLOCK_SIZE
          write_field(header, 0, 100, name)
          write_octal(header, 100, 8, mode)
          write_octal(header, 108, 8, 0)
          write_octal(header, 116, 8, 0)
          write_octal(header, 124, 12, size)
          write_octal(header, 136, 12, 0)
          write_field(header, 148, 8, " " * 8)
          write_field(header, 156, 1, "0")
          write_field(header, 257, 6, "ustar\0")
          write_field(header, 263, 2, "00")
          write_field(header, 265, 32, "root")
          write_field(header, 297, 32, "root")
          checksum = header.bytes.sum
          write_field(header, 148, 8, format("%06o\0 ", checksum))
          header
        end

        def write_octal(buffer, offset, length, value)
          write_field(buffer, offset, length, format("%0#{length - 1}o\0", value))
        end

        def write_field(buffer, offset, length, value)
          value = value.to_s.b
          raise ArgumentError, "Tar field overflow" if value.bytesize > length

          buffer[offset, length] = value.ljust(length, "\0")
        end
      end
    end
  end
end
