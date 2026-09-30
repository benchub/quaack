# The throwaway Postgres that the test suites run against. The official
# image doesn't include HypoPG, so this adds it from the PGDG apt repository
# that the image already has set up. spec/support/test_postgres.rb builds
# this image and tags it with a hash of this file, so editing it forces a
# rebuild. PgBouncer is there too, for specs of a pooler in front of the
# run server; test_postgres.rb starts it only when a spec asks for it.
# PL/Perl is there for specs of an extension that lives in pg_catalog.
FROM postgres:18

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-18-hypopg postgresql-plperl-18 pgbouncer \
 && rm -rf /var/lib/apt/lists/*

# A German locale, so specs can check that nothing depends on English
# server messages (lc_messages).
RUN localedef -i de_DE -c -f UTF-8 de_DE.UTF-8
