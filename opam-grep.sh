#!/bin/sh

setup() {
  PKGS=$(opam list -A -s --color=never)
  DST=$(mktemp -d)

  cd "$DST"

  for pkg in $PKGS; do
    opam source "$pkg"
  done

  echo "Setup done. Call $0 grep $DST <regexp>"
}

search() {
  PKGS=$(ls "$1")

  for pkg in $PKGS; do
    if grep -qr "$2" "$1/$pkg"; then
      pkg=$(echo "$pkg" | cut -d. -f1)
      echo "$pkg matches your regexp."
    fi
  done
}

case "$1" in
setup)
  if test "$#" -gt 2; then
    echo "Too many arguments."
    exit 1
  fi
  setup
  ;;
grep)
  if test "$#" -lt 3; then
    echo "Not enough arguments."
    exit 1
  elif test "$#" -gt 3; then
    echo "Too many arguments."
    exit 1
  fi
  search $2 $3
  ;;
*)
  echo "Usage:"
  echo "  - $0 setup"
  echo "  - $0 grep <setup directory> <regexp>"
  ;;
esac
