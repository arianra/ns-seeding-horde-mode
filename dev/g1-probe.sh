#!/usr/bin/env bash
# G1: does Shine discover an extension that lives in a -game overlay rather than
# inside a workshop mod? Nothing networked in the probe, so a vanilla client is
# unaffected whichever way this lands.
set -uo pipefail
cd ~/projects/ns-seeding-horde-mode
SRV_WIN='D:\games\ns2-server'; CFG_WIN='D:\games\ns2hordetest\cfg'; OVL_WIN='D:\games\ns2hordetest\overlay'
LOG="/mnt/c/Users/aria/AppData/Roaming/Natural Selection 2/log-Server.txt"
PORT=27025

./dev/server-stop.sh >/dev/null 2>&1 || true
# suite off: we are testing mounting, not scenarios
printf '{"RunSuite" : false}\n' > /mnt/d/games/ns2hordetest/cfg/shine/plugins/HordeTest.json
sleep 2
OFFSET=$(stat -c %s "$LOG" 2>/dev/null || echo 0)

PID=$(powershell.exe -NoProfile -Command "(Start-Process -FilePath '$SRV_WIN\x64\Server.exe' -ArgumentList '-config_path','$CFG_WIN','-port','$PORT','-limit','16','-game','$OVL_WIN','+map','ns2_summit' -WorkingDirectory '$SRV_WIN' -WindowStyle Hidden -PassThru).Id" 2>/dev/null | tr -dc '0-9')
echo "[G1] pid=$PID overlay=$OVL_WIN"
echo "$PID" > dev/.server.pid

for _ in $(seq 1 30); do
  sleep 3
  NEW=$(tail -c +$((OFFSET + 1)) "$LOG" 2>/dev/null)
  if grep -q "Completed loading Shine extensions" <<<"$NEW"; then break; fi
done
sleep 4
NEW=$(tail -c +$((OFFSET + 1)) "$LOG" 2>/dev/null)

echo "=== verdict ==="
grep -acE "Mounting mod 'Shine" <<<"$NEW" | sed 's/^/shine mounted: /'
grep -aE "Extension '[a-z]+' loaded" <<<"$NEW" | sed -n 's/.*Extension .\([a-z]*\)..*/  ext: \1/p' | tr '\n' ' '; echo
grep -a "G1PROBE" <<<"$NEW" | head -2 | cut -c1-160
grep -aciE "hordehello" <<<"$NEW" | sed 's/^/hordehello mentions: /'
grep -aE "invalid mod entry|Error: Unable to|script error" <<<"$NEW" | head -3 | cut -c1-120

./dev/server-stop.sh >/dev/null 2>&1 || true
printf '{"RunSuite" : true}\n' > /mnt/d/games/ns2hordetest/cfg/shine/plugins/HordeTest.json
