# CAUTION: ONLY USE THIS ON BC250s THAT HAVE BEEN VERIFIED TO HAVE ALL 8 CPU CORES FUNCTIONAL VIA ANOTHER METHOD FIRST

Credit to https://github.com/rw-r-r-0644 for creating an implementation of this unlock, which I used as a reference when making this driver

- Rescue Mei

# Using the Patch

1) Ensure xdelta3 and md5sum are available
2) Place BC250_3.00_CHIPSETMENU.ROM in the Patch directory.
3) Run ApplyDeltaPatch.sh, which will generate the final BC250 bios rom file.
4) Verify the MD5 hash matches the following:

d298267029fbbe9d29b0bfa0db5fbf9e  BC250_3.00_CHIPSETMENU.ROM
6475614980a40a23c412d4deb5273876  BC250_3.00_MeiMeiDXE.ROM
18a48098f95da36f45b93b07ea72a18b  BC250_3.00_CHIPSETMENU-to-BC250_3.00_MeiMeiDXE.xdelta

5) If the hashes match, you should be set to flash it to the BC250 via whichever method you prefer.