opam-grep is an opam plugin that greps through the sources of all opam packages.

To install it, simply call:
```
$ opam install opam-grep
```
Then to use it, simply call:
```
$ opam grep "your regexp"
```
*Side note: currently opam-grep will cache the sources in your cache directory (`$XDG_CACHE_HOME/opam-grep` or `$HOME/.cache/opam-grep`), so a few GB of available disk space is most likely required.*

I hope this can help core compiler and community library devs alike, to know which part of their software is used in the wild.
