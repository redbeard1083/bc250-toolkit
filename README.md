# bc250-toolkit
Setup script for BC250 on CachyOS

Disclaimer:  I am not responsible for any damages caused by use of this script.  Please review it to make sure the overclocking configs are compatible with your board.

This script will allow easy setup of the BC-250 on CachyOS.  It has been tested with the handheld edition, but should also work on any CachyOs version as long as the Limine bootloader is used.  Inspired by the similar script for Bazzite:  https://github.com/NexGen-3D-Printing/SteamMachine

It does the following:
1. Install CPU governor: https://github.com/bc250-collective/bc250_smu_oc/
2. Install GPU governor: https://github.com/filippor/cyan-skillfish-governor
3. Enable swap
4. Hide the RDSEED error displayed on boot.
5. Enable ZSWAP
6. Easily change CPU and GPU overclock settings on the fly
7. Displays a status window showing you your current settings.

Installation:
curl -sSLO https://raw.githubusercontent.com/redbeard1083/bc250-toolkit/main/bc250-toolkit.sh && chmod +x bc250-toolkit.sh && ./bc250-toolkit.sh
