#!/bin/sh

set -e

PATH="$PATH:/go/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME=/root
export DEBUG=pw:*
# cd /app
exec $@
