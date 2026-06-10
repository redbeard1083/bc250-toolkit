# bc250-toolkit
Setup script for BC250 on CachyOS

Disclaimer:  I am not responsible for any damages caused by use of this script.  Please review it to make sure the overclocking configs are compatible with your board. Unlocking compute units will increase power draw and heat.  You are responsible for your own power and cooling setups.  Misuse of this script could cause physical damage to your board.

### **Must be using Limine boot loader for all functions in the script to work.**

This script will allow easy setup of the BC-250 on CachyOS.  It has been tested with the handheld edition, but should also work on any CachyOs version as long as the Limine bootloader is used.  Inspired by the similar script for Bazzite:  https://github.com/NexGen-3D-Printing/SteamMachine

It does the following:
1. Install CPU governor: https://github.com/bc250-collective/bc250_smu_oc/
2. Install GPU governor: https://github.com/filippor/cyan-skillfish-governor
3. Enable swap
4. Hide the RDSEED error displayed on boot.
5. Enable ZSWAP
6. Easily change CPU and GPU overclock settings on the fly
7. Displays a status window showing you your current settings.
8. Unlock compute units thanks to: https://github.com/WinnieLV/bc250-cu-live-manager

In desktop mode run the below in the terminal(Konsole):
<pre>
curl -sSLO https://raw.githubusercontent.com/redbeard1083/bc250-toolkit/main/bc250-toolkit.sh && chmod +x bc250-toolkit.sh && ./bc250-toolkit.sh
</pre>

```
  ╔══════════════════════════════════════════════════════════════╗
  ║                                                              ║
  ║              CachyOS BC250 Toolkit                           ║
  ║           System Setup & Configuration                       ║
  ║                                                              ║
  ╚══════════════════════════════════════════════════════════════╝

  Performance
  ──────────────────────────────────────────────────────────────
  [ 1]  Overclock Menu      CPU & GPU performance profiles

  Setup Tasks
  ──────────────────────────────────────────────────────────────
  [ 2]  CPU Governor        bc250-smu-oc CPU overclock service
  [ 3]  GPU Governor        cyan-skillfish GPU governor service
  [ 4]  Enable Swap         16G Btrfs swapfile, swappiness=180
  [ 5]  ZRAM -> ZSWAP       Disable ZRAM, enable ZSWAP w/ lz4
  [ 6]  Hide RDSEED Warning Set loglevel=0 in /boot/limine.conf
  [ 7]  Disable Mitigations Add mitigations=off to limine.conf
  [ A]  Run All (2-7)       Run all setup tasks in sequence

  Revert / Undo
  ──────────────────────────────────────────────────────────────
  [ R]  Revert Menu         Undo previously applied settings

  Additional Tools
  ──────────────────────────────────────────────────────────────
  [ E]  Additional Tools    Additional system utilities

  ⚠  Experimental/Danger Zone
  ──────────────────────────────────────────────────────────────
  [ X]  Compute Units Unlock 

  System
  ──────────────────────────────────────────────────────────────
  [ S]  Status              Current system summary
  [ 0]  Exit                

  ══════════════════════════════════════════════════════════════
...
...

