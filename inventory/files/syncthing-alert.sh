#!/bin/sh
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri
# Syncthing's daily alert. Exit 1 pages (runbook, Syncthing).
set -eu
# syncthing cli reads the GUI address and key from config.xml only when
# neither variable is set, and the image sets STGUIADDRESS.
key=$(env -u STGUIADDRESS -u STGUIAPIKEY /bin/syncthing cli config gui apikey get)
api() {  # api PATH OUT [curl args...]; the key goes on stdin
  p=${1}; o=${2}; shift 2
  printf 'header = "X-API-Key: %s"\n' "${key}" |
    curl -fsS -m 10 -K - -o "${o}" "${@}" "http://127.0.0.1:8384/rest/${p}"
}
bad=0
env -u STGUIADDRESS -u STGUIAPIKEY /bin/syncthing cli config folders list > /tmp/folders
while IFS= read -r f; do
  api db/status /tmp/status -G --data-urlencode "folder=${f}"
  state=$(sed -n 's/^  "state": "\(.*\)",$/\1/p' /tmp/status)
  errs=$(sed -n 's/^  "errors": \([0-9]*\),$/\1/p' /tmp/status)
  echo "folder ${f}: state=${state:-none} errors=${errs:-?}"
  if [[ "${state}" = error ]] || [[ "${errs:-1}" != 0 ]]; then bad=1; fi
done < /tmp/folders
api system/error /tmp/errors
e=$(cat /tmp/errors)
case ${e} in
  *'"errors": null'*|*'"errors": []'*) echo "system errors: none" ;;
  *) echo "system errors: present"; bad=1 ;;
esac
exit "${bad}"
