# ahcifix.386
VxD to allow Windows 3.1 Enhanced Mode to be used with Intel AHCI (SATA) controllers

This is a small and simple [Virtual Device Driver ("VxD")](https://en.wikipedia.org/wiki/VxD) for Windows 3.1 in 386 Enhanced Mode (and probably also Windows 95/98, though I haven't tested it with those!). Its purpose is to work around two bugs in the firmware for Intel [AHCI](https://wiki.osdev.org/AHCI) controllers, which normally cause Windows 3.1 Enhanced Mode to crash on disk access.

## The Bugs

The AHCI firmware contains code needed to service [`int 13h`](https://fd.lod.bz/rbil/zint/index_13.html) calls from Real/Virtual 8086 Mode, which works pretty well for the most part. In Virtual 8086 Mode, it uses the [Virtual DMA Specification](https://fd.lod.bz/rbil/interrup/io_disk/4b8102dx0000.html) to cooperate with the running Virtual Machine Manager (e.g. EMM386, or Windows 3.1) and ensure that data gets read into / written from the correct physical addresses. Unfortunately, there are two mistakes in its use of the Spec:

1. When it [locks a contiguous](https://fd.lod.bz/rbil/interrup/io_disk/4b8103.html#6310) or [scatter / gather](https://fd.lod.bz/rbil/interrup/io_disk/4b8105.html#6312) region, it sets the `ES` register to the [Extended BIOS Data Area (EBDA)](https://fd.lod.bz/rbil/memory/bios/m0040000e.html), but when doing the corresponding [unlock](https://fd.lod.bz/rbil/interrup/io_disk/4b8104.html#6311)[(s)](https://fd.lod.bz/rbil/interrup/io_disk/4b8106.html#6313), it instead uses `DS`! This is wrong, and causes Windows 3.1 to crash because it's trying to read a DMA Descriptor Structure from arbitrary memory that wasn't used to set one up in the first place (but EMM386 is more resilient…).
2. This one's a bit more subtle, and it may be particular to my motherboard / system: the firmware sets up an Extended DMA Descriptor Structure at the *beginning* of the EBDA, instead of somewhere deep inside it. This means that, depending on how large the scatter / gather regions are, it can overwrite varying amounts of data that are supposed to be at the beginning of the EBDA. For example, I found that when I worked around Bug 1, Windows would boot, but the mouse didn't work anymore because the "pointing device" info was getting overwritten in the EBDA! The offset within the EBDA is supposed to be specified at a certain location in the firmware ROM, but for some reason it's set to zero (again, this may just be on my motherboard…).

## Building

To build the VxD, you need the [Win16 Driver Development Kit](http://www.win3x.org/win3board/viewtopic.php?t=2776). Once you install it, you can place the sources in a subfolder of the `386` directory (e.g. `386\AHCIFIX`) and run `nmake`. This should create the file `AHCIFIX.386` which can be loaded by Windows.

By the way, here's a tip for using the DDK on a modern system: to make the debugger `WDEB386` work, you need to change some bytes:

* At position `63D8`, you need to change `0F 24 F0` to `66 33 C0`
* At position `63DF`, you need to change `0F 24 F8` to `66 33 C0`

This removes references to the [`TR6` and `TR7` registers](https://en.wikipedia.org/wiki/Test_register), which crash the system since they only existed on the 386, 486 and a few other less-well-known chips!

## Usage

Simply add `device=ahcifix.386` to the `[386Enh]` section of `C:\WINDOWS\SYSTEM.INI`. You should specify the full path, or else copy the file `AHCIFIX.386` to `C:\WINDOWS\SYSTEM`. You can get the file by building it as described above, or by downloading a [release](https://github.com/PluMGMK/ahcifix.386/releases).

**NOTE: This driver works for me, on the one motherboard I have tested it on ([this motherboard](https://us.msi.com/Motherboard/Z97-GAMING-3))! Please proceed with caution if trying it on a different motherboard!**
