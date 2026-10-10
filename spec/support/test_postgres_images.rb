# frozen_string_literal: true

require "time"

module TestPostgres
  # Each Dockerfile edit leaves an old image of about 660 MB. Another
  # worktree on an older Dockerfile may still be using one, and its image is
  # rebuilt if it goes, so only images older than OLD_IMAGE_AGE seconds are
  # removed. That keeps two worktrees from rebuilding each other's.
  module OldImages
    OLD_IMAGE_AGE = 7 * 24 * 3600

    # Removes the images of `repository` (the current tag's, unless a spec
    # names its own), other than the current one, that are older than
    # `older_than` seconds. `only`, a list of tags, limits it further: a spec
    # passes the tags it made, so it can never remove an image it didn't. A
    # spec also makes them under a throwaway repository, so a launch in
    # another checkout, which lists the harness's repository, never sees
    # them. Nothing else is touched. `docker rmi`
    # without force leaves an image any container uses. Cleanup is a
    # courtesy, so any failure skips that image, or all of them if the
    # listing fails, and never fails a launch.
    def self.remove(current, older_than = OLD_IMAGE_AGE, only: nil, repository: current.split(":").first)
      tags = TestPostgres.docker("image", "ls", repository, "--format", "{{.Repository}}:{{.Tag}}")
      tags = tags.lines.map(&:strip) - [current]
      (only ? tags & only : tags).each { |tag| remove_one(tag, older_than) }
    rescue RuntimeError
      nil
    end

    def self.remove_one(tag, older_than)
      created = Time.parse(TestPostgres.docker("image", "inspect", "--format", "{{.Created}}", tag))
      TestPostgres.docker("rmi", tag) if Time.now - created >= older_than
    rescue RuntimeError, ArgumentError
      nil # Still in use, already gone, or no readable age.
    end
  end
end
