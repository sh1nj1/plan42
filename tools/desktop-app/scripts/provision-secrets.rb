#!/usr/bin/env ruby
# frozen_string_literal: true

# First-run secret provisioning for the Collavre desktop app.
#
# The desktop env boots in production mode, which requires a stable
# SECRET_KEY_BASE. We generate one on first run and persist it under the
# writable data dir; every later run reuses it. Because Active Record
# encryption keys are *derived* from secret_key_base (see
# lib/encryption_bootstrap.rb), keeping this value stable is what keeps
# previously-encrypted rows (LLM API keys, OAuth tokens) decryptable across
# restarts — so this file must never be regenerated once written.
#
# Usage:
#   COLLAVRE_DATA_DIR=/path ruby provision-secrets.rb        # ensure + print key
# Prints the SECRET_KEY_BASE to stdout so the launcher can export it.

require "securerandom"
require "fileutils"

data_dir = ENV["COLLAVRE_DATA_DIR"] || ARGV[0]
abort("provision-secrets: COLLAVRE_DATA_DIR (or argv[0]) is required") if data_dir.to_s.empty?

cred_dir = File.join(data_dir, "credentials")
key_file = File.join(cred_dir, "secret_key_base")

secret =
  if File.exist?(key_file)
    File.read(key_file).strip
  else
    FileUtils.mkdir_p(cred_dir)
    generated = SecureRandom.hex(64)
    # Write to a private tmp file with owner-only perms (no half-written or
    # world-readable secret), then publish via link(2). link is atomic AND
    # no-clobber: if two first launches race, only one link succeeds; the loser
    # gets EEXIST and re-reads the winner's key instead of overwriting it (a
    # plain rename would clobber, orphaning the secret the winner already booted
    # with and making that session's encrypted rows undecryptable).
    tmp = "#{key_file}.tmp.#{Process.pid}"
    File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(generated) }
    begin
      File.link(tmp, key_file)
      generated
    rescue Errno::EEXIST
      File.read(key_file).strip
    ensure
      File.delete(tmp) if File.exist?(tmp)
    end
  end

# Defensive: re-assert restrictive perms in case the file predates this code.
File.chmod(0o600, key_file)

puts secret
