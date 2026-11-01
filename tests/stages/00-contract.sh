# tests/stages/00-contract.sh: the stage contract holds. check.sh's helpers are
# visible to tests/stages and the daemon binary is built.
for f in free_port stop_daemon rmtmp ocurl jget wait_status_at sqlite3 pass fail; do
  declare -F "$f" >/dev/null || fail "stage contract: helper $f is not visible to tests/stages"
done
[ -x ./bin/swarmd ] || fail "stage contract: ./bin/swarmd is not built"
pass "stage contract: check.sh's helpers and ./bin/swarmd are available to tests/stages"
