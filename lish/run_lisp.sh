#!/usr/bin/env sh

# This is just to find and start a Lisp, to run a Lisp based script.

fail()
{
  echo "$0: $*"
  exit 1
}

script_name="$1"
if [ ! -n "$script_name" ]; then
  fail "Script name argument is missing."
fi
if [ ! -e "$script_name" ]; then
  fail "Script file doesn't exist."
fi

if [ ! -n "$LISP" ] ; then
  LISPS="sbcl ccl lisp clisp ecl"
  for l in $LISPS ; do
    if [ x"`command -v $l`" != x ] ; then
      LISP=$l
      break;
    fi
  done
fi
if [ ! -n "$LISP" -o ! -n "`command -v $LISP`" ] ; then
  echo "I can't find a Lisp to run. Please set the environment variable LISP to"
  echo "the name of an installed Common Lisp, and re-run this script."
  echo "For example: "
  echo
  echo "LISP=/usr/bin/sbcl sh ./build.sh"
  echo
  exit 1
fi

try_to_figure_flags()
{
  case "$LISP" in
    *sbcl*)  OUR_PLAIN_LISP_FLAGS="--no-userinit" ;
	     BATCH_ARGS="--noinform --noprint --disable-debugger --no-sysinit"
	     ;;
    #*ccl*)   OUR_PLAIN_LISP_FLAGS="--no-init"     ; BATCH_ARGS="--batch" ;;
    *ccl*)   OUR_PLAIN_LISP_FLAGS="--no-init"     ; BATCH_ARGS="--quiet" ;;
    *clisp*) OUR_PLAIN_LISP_FLAGS="-norc"         ; BATCH_ARGS="" ;;
    *abcl*)  OUR_PLAIN_LISP_FLAGS="--noinit"      ; BATCH_ARGS="" ;;
    *ecl*)   OUR_PLAIN_LISP_FLAGS="--norc"        ; BATCH_ARGS="" ;;
    *)
      echo "I'm not sure how to set flags for $LISP."
      ;;
  esac
}

try_to_figure_flags
export LISH_PLAIN_FLAGS="${LISH_PLAIN_FLAGS:=$OUR_PLAIN_LISP_FLAGS}"
export LISH_FLAGS="${BATCH_ARGS}"

echo "[Using ${LISP} ${LISH_FLAGS} ${LISH_PLAIN_FLAGS}]"
echo "[Running $script_name]"

echo '(load "'"$script_name"'")' |
  $LISP $LISH_FLAGS $LISH_PLAIN_FLAGS "$@" || fail "somehow failed"

exit 0
