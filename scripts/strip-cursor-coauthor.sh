#!/bin/sh
# Strip assistant Co-authored-by trailers from commit messages (stdin → stdout).
sed -E \
  -e '/^[Cc]o-authored-by:[[:space:]]*Cursor([[:space:]]+Agent)?[[:space:]]*<cursoragent@cursor\.com>[[:space:]]*$/d' \
  -e '/^[Cc]o-authored-by:[[:space:]]*cursoragent[[:space:]]*<cursoragent@cursor\.com>[[:space:]]*$/d'
