## Resources

Device:
    type:   Nextion-family touch-and-display TJC4827X243 - Gree Edgeless GM6721-family dual Cortex-M4 (CHIP_ID 0x6721FC11)
    access: accessible ONLY via 'rpi2' service

Device's decompiled firmware:
    type:   IDA database
    url:    http://git.local/ida/sovol-screen-fw
    note:   everything is already decompiled and decoded, no need to decode/decompile anything else

Docs:
    path:   ../doc
    type:   PDF and HTML files with Device's (and similar devices) specs and SDK notes/examples

ext:
    path:   ../ext
    type:   assorted - TFT files, git repos, SDKs, sources, binaries
    description: lots of stuff that *may be* somehow related to Device. best use is to run ripgrep with some keyword over the whole ext/
    useful stuff: find ../ext -iname "*GM6721*"
    especially useful files (already parsed by IDA):
      - ../ext/SoC/BPI-EAI80-bsp/KelisSDK/ugelis/tools/keil/Keil.GM66xx_DFP.1.4.1/Device/Include/GM6721_Generate.h
      - ../ext/SoC/BPI-EAI80-bsp/ulibs/hal/gree/include/arch/arm/soc/soc_gm6721x.h
    very useful repo: ../similar_projects/TJC-firmware-reverse-engineering

Mascot:
    path:   Nanachi.png
    type:   PNG of an anime character
    description: mascot of the project. meant to replace Sovol's default robot screen.

## Tools

screen_probe.py:
    path:   tools/screen_probe.py
    type:   cli tool
    description: main tool to communicate with Device. can connect either to local serial port (not applicable in this environment) or to [telnet mode] TCP port (see 'rpi2')

TFTTool:
    path:   ../TFTTool
    cli:    ../TFTTool/TFTTool.py
    type:   git repo, cli, python lib
    description: sibling project, may contain useful info about Device's internals and data formats

## Services

rpi2:
    type:         HTTP gateway to Device's power switch, serial port, and web camera pointed to Device's screen
    openapi spec: http://rpi2.local:9292/api
    serial port:  socket://rpi2.local:2000, telnet mode
    note:         not meant to be contacted in any other ways, like ssh, ftp, etc

