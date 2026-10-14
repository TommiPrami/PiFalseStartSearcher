# PiFalseStartSearcher

A tiny tool to find the longest "false start" of Pi: a place in the decimals where the digits start again as "31415926...". It just occurred to me to wonder what the longest false start is, and going through a trillion decimals by hand seemed a bit daunting.

## What it reports

- While running, only a new longest false start is logged, so the log stays quiet. You can turn this off to log every false start of at least *N* digits as it is found.
- Optionally, in the summary: every false start of at least *N* digits (default 10) with its position, and the new longest ones in the order found. The list stops at the first 1 000, the table below has the counts of all of them.
- A table of how many false starts of each length were found, where the first one of each length is, and how many you would expect if the digits are random (digits scanned × 10^-length).
- Optionally self-locating strings: positions *P* where the digits at *P* spell *P* (for example "16470" at position 16 470).

Positions follow the usual Pi search convention: the first digit after the decimal point is at position 1. For example "314159" is first found at position 176 451.

## Input files

A plain text (ASCII) file of digits, such as `3.14159...`. The searched prefix is read from the start of the first file, so the tool works for any constant, not only Pi. Characters other than digits (the decimal point, line breaks) are skipped, so files with line breaks work too; anything other than the decimal point and white space is reported as unexpected.

If the file name ends in a number (`pi_dec_1t_01.txt`), the files that continue it (`pi_dec_1t_02.txt`, `pi_dec_1t_03.txt`, ...) are searched too, as one long run of digits, as long as they exist next to it.

## Programs

- **PiFalseStartSearch** - VCL application.
- **PiFalseStartSearchConsole** - command line version for long unattended runs. Run it without parameters to see the switches. Ctrl+C stops the search and prints the results so far.

Both are in `PiFalseStartSearch.groupproj`. Build Release, Win64 for the speed.

## How it works

At every position the first four digits are compared at once against the prefix; only on a hit (about once in 10 000 positions) the match is extended digit by digit. Every position is independent, so each buffer is split into slices that are scanned in parallel, while the next buffer is read in the background.
