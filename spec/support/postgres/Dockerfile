# The throwaway Postgres that the test suites run against. The official
# image doesn't include HypoPG, so this adds it from the PGDG apt repository
# that the image already has set up. spec/support/test_postgres.rb builds
# this image and tags it with a hash of this file, so editing it forces a
# rebuild.
FROM postgres:18

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-18-hypopg \
 && rm -rf /var/lib/apt/lists/*
