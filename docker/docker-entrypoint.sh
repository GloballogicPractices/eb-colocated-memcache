#!/bin/sh -x
set -e

MEMCACHE_PORT=11211

if [ "X$MCROUTER_ENABLED" == "Xyes" ]; then
  /usr/local/bin/mcrouter -p 11211 --config file://usr/local/etc/mcrouter.conf &
  MEMCACHE_PORT=11212
fi

# first arg is `-f` or `--some-option`
if [ "${1#-}" != "$1" ]; then
	set -- /usr/bin/memcached -p $MEMCACHE_PORT "$@"
fi

exec "$@"
