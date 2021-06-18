#!/bin/sh

DST="$HOME/.opam-grep"
PACKAGES="$DST/packages"

sync() {
  mkdir -p "$DST"
  opam show -f package $(opam list -A -s --color=never) > "$PACKAGES"
}

check() {
  if [ ! -e "$DST/$1" ]; then
    opam source --dir "$DST/$1" "$1" > /dev/null
  fi
}

update() {
  sync

  MSG='Downloading packages: '
  for pkg in $(cat "$PACKAGES"); do
    spin
    check "$pkg"
  done

  echo -e '\033[2K\rUpdate complete.'
}

SPIN='/'
MSG='Searching'

spin() {
  echo -n -e "\033[2K\r$MSG: $SPIN"
  case "$SPIN" in
    '|') SPIN='/';;
    '/') SPIN='-';;
    '-') SPIN='\';;
    '\') SPIN='|';;
  esac
}

search() {
  test -e "$PACKAGES" || sync

  for pkg in $(cat "$PACKAGES"); do
    spin
    check "$pkg"
    if grep -qr "$1" "$DST/$pkg"; then
      pkg=$(echo "$pkg" | cut -d. -f1)
      echo -e "\033[2K\r$pkg matches your regexp."
    fi
  done
  echo -e '\033[2K\rUpdate complete.'
}

case "$1" in
update)
  if test "$#" -gt 2; then
    echo "Too many arguments."
    exit 1
  fi
  update
  ;;
prune)
  if test "$#" -gt 2; then
    echo "Too many arguments."
    exit 1
  fi
  # XXX Intention is to remove directories no longer listed in $DST/packages
  echo "Not yet implemented."
  exit 1
  ;;
grep)
  if test "$#" -lt 2; then
    echo "Not enough arguments."
    exit 1
  elif test "$#" -gt 2; then
    echo "Too many arguments."
    exit 1
  fi
  search $2
  ;;
*)
  echo "Usage:"
  echo "  - $0 update"
  echo "  - $0 prune"
  echo "  - $0 grep <regexp>"
  ;;
esac
