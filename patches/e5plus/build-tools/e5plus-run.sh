#!/bin/bash
# One entry point for building the GameMT E5 Plus image on a build host (made
# for WSL2 and for agents that drive it through wsl.exe): long jobs run in
# detached tmux sessions, so they keep going after the call or terminal that
# started them returns, and every subcommand is a plain argument, so nothing
# needs nested quoting. Logs go to the home directory.
#
#   e5plus-run.sh preflight  check this host can run the build  (~/e5plus-preflight.log)
#   e5plus-run.sh smoke      start the kernel smoke test, tmux session e5smoke
#                            (~/e5plus-kernel-smoke.log; done at 'SMOKE EXIT=<n>')
#   e5plus-run.sh build      start the full image build, tmux session darkos
#                            (BUILD_ARGS='BUILD_ARMHF=n' etc. passes make variables)
#   e5plus-run.sh status     RUNNING / SUCCEEDED: <image> / FAILED, with the evidence
#   e5plus-run.sh verify     check the finished image's contents (read-only)
#   e5plus-run.sh stop       interrupt the build and clean up its mounts
#   e5plus-run.sh retry      stop (if running), clean up, start the build again
#   e5plus-run.sh report     everything to send back when something failed
set -u
TOOLS="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO="$(cd "$TOOLS/../../.." && pwd)"
STAMP="$HOME/.e5plus-build-started"
FATAL='Exiting build with return code|Failed to resize Arkbuild|ERROR: .*did not apply|ERROR: the RTL8733BS driver did not build|ERROR: could not take'

ensure_binfmt() {
  # qemu's arm64/armhf handlers can be gone after a WSL restart
  for a in aarch64 arm; do
    if ! grep -qs '^enabled' /proc/sys/fs/binfmt_misc/qemu-$a; then
      sudo /usr/lib/systemd/systemd-binfmt /usr/lib/binfmt.d/qemu-aarch64.conf /usr/lib/binfmt.d/qemu-arm.conf
      break
    fi
  done
}

building() { pgrep -x build_e5plus.sh >/dev/null; }   # exact process name: never matches a command line that merely mentions it

start_build() {
  cd "$REPO" || exit 1
  if tmux has-session -t darkos 2>/dev/null; then
    if building; then echo "The build is already running."; exit 1; fi
    tmux kill-session -t darkos
  fi
  ensure_binfmt
  # Images and archives from an earlier run would be compressed and copied
  # along with the new one (make clean does not remove them).
  old=$(ls dArkOS_E5PLUS_*.img dArkOS_E5PLUS_*.img.7z* 2>/dev/null)
  if [ -n "$old" ]; then
    echo "Removing images from an earlier run:"; echo "$old"
    rm -f dArkOS_E5PLUS_*.img dArkOS_E5PLUS_*.img.7z*
  fi
  date '+%s' > "$STAMP"
  tmux new-session -d -s darkos -c "$REPO" \
    "make e5plus ${BUILD_ARGS:-}; echo; echo 'make e5plus exited. That does not mean it worked: run ~/e5plus-run.sh status'; exec bash"
  sleep 3
  if building; then echo "Build started in tmux session 'darkos'. Check it with: ~/e5plus-run.sh status"; else echo "The build did not start:"; tmux capture-pane -p -t darkos | tail -n 20; exit 1; fi
}

stop_build() {
  if building; then
    tmux send-keys -t darkos C-c
    for _ in $(seq 60); do building || break; sleep 2; done
    building && { sudo pkill -x build_e5plus.sh; sleep 5; }
  fi
  tmux kill-session -t darkos 2>/dev/null
  (cd "$REPO" && make clean)
}

case "${1:-}" in
  preflight)
    cd "$REPO" && bash "$TOOLS/e5plus-preflight.sh" 2>&1 | tee "$HOME/e5plus-preflight.log"
    exit "${PIPESTATUS[0]}"
    ;;
  smoke)
    if tmux has-session -t e5smoke 2>/dev/null; then echo "The smoke test is already running (tmux session e5smoke)."; exit 1; fi
    tmux new-session -d -s e5smoke \
      "bash $TOOLS/e5plus-kernel-smoke.sh $REPO $HOME/e5plus-kernel-smoke > $HOME/e5plus-kernel-smoke.log 2>&1; echo \"SMOKE EXIT=\$?\" >> $HOME/e5plus-kernel-smoke.log"
    echo "Smoke test started. Check it with: tail -n 5 ~/e5plus-kernel-smoke.log"
    echo "It is done when the log's last line is 'SMOKE EXIT=<n>' (0 = passed)."
    ;;
  build) start_build ;;
  stop)  stop_build ;;
  retry) stop_build; start_build ;;
  status)
    log="$REPO/build.log"
    if building; then
      echo "RUNNING (started $(date -d "@$(cat "$STAMP" 2>/dev/null || echo 0)" '+%F %T'))"
      echo "--- last lines of build.log ---"; tail -n 15 "$log" 2>/dev/null
      if [ -n "$(grep -nE "$FATAL" "$log" 2>/dev/null)" ]; then echo; echo "WARNING: a fatal error is already in build.log:"; grep -nE "$FATAL" "$log" | tail -n 5; fi
      exit 0
    fi
    [ -f "$STAMP" ] || { echo "NOT STARTED"; exit 0; }
    started=$(cat "$STAMP")
    archive=$(ls -t "$REPO"/dArkOS_E5PLUS_*.img.7z.001 2>/dev/null | head -1)
    img=${archive%.7z.001}
    ok=1
    [ -n "$archive" ] && [ "$(stat -c %Y "$archive")" -ge "$started" ] || { echo "no .img.7z.001 archive from this run"; ok=0; }
    [ -n "$archive" ] && [ -f "$img" ] || { echo "no .img next to the archive"; ok=0; }
    tail -n 5 "$log" 2>/dev/null | grep -q "Everything is Ok" || { echo "build.log does not end with 7-Zip's 'Everything is Ok'"; ok=0; }
    if grep -nE "$FATAL" "$log" >/dev/null 2>&1; then echo "fatal error in build.log:"; grep -nE "$FATAL" "$log" | tail -n 5; ok=0; fi
    if [ "$ok" = 1 ]; then
      echo "SUCCEEDED: $img"; ls -la "$img" "$img".7z.*
    else
      echo "FAILED (the build is no longer running)"
      echo "--- last 40 lines of build.log ---"; tail -n 40 "$log" 2>/dev/null
      exit 1
    fi
    ;;
  verify)
    img="${2:-$(ls -t "$REPO"/dArkOS_E5PLUS_*.img 2>/dev/null | head -1)}"
    [ -n "$img" ] || { echo "no dArkOS_E5PLUS_*.img in $REPO"; exit 2; }
    building && { echo "The build is still running; wait for 'status' to say SUCCEEDED."; exit 2; }
    bash "$TOOLS/e5plus-verify-image.sh" "$img"
    ;;
  report)
    echo "=== e5plus-run.sh status"; "$0" status 2>&1 | head -n 20
    echo; echo "=== first errors in build.log"; grep -nE -m8 'Exiting build with return code|ERROR|error:|FAILED|Failed' "$REPO/build.log" 2>/dev/null
    echo; echo "=== last 150 lines of build.log"; tail -n 150 "$REPO/build.log" 2>/dev/null
    echo; echo "=== last 60 lines of the smoke test log"; tail -n 60 "$HOME/e5plus-kernel-smoke.log" 2>/dev/null
    echo; echo "=== preflight log"; cat "$HOME/e5plus-preflight.log" 2>/dev/null
    echo; echo "=== host"
    git -C "$REPO" log -1 --oneline; uname -r; nproc; free -h
    df -h "$HOME" /mnt/c 2>/dev/null; echo "--- /etc/wsl.conf"; cat /etc/wsl.conf 2>/dev/null
    ;;
  *) sed -n '2,21p' "$0"; exit 2 ;;
esac
