#!/usr/bin/env bash
set -euo pipefail

sql="${*: -1}"
case "$sql" in
  *"select count(*)"*) printf '3\n'; exit 0 ;;
  *"insert into"*|*"update"*|*"delete from"*|*"truncate table"*|*"alter table"*|*"drop table"*|*"create table"*)
    if [ "${READ_ONLY_STUB_ALLOW:-}" = "INSERT" ] && [[ "$sql" == *"insert into"* ]]; then
      exit 0
    fi
    printf 'ERROR: permission denied\n' >&2
    exit 1
    ;;
esac
exit 0
